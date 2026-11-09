import Foundation
import Observation
import ServiceManagement
import HostShieldCore

enum Protection: Equatable {
    case off
    case active(count: Int)
    case outdated(installed: Int, desired: Int)   // hosts block installed but settings/lists changed since
    case removed                                  // user wants it on, but it is no longer in effect
    case switchPending(to: BlockMethod)           // a different method is in effect than the one selected
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let isError: Bool
}

struct CheckResult {
    var lookup: Engine.Lookup
    var addresses: [String]
    var inHostsFile: Bool
    var viaSinkhole: Bool
    var blockedNow: Bool { addresses.contains("0.0.0.0") || addresses.contains("::") }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store = Store()
    let installer: HostsInstaller
    let stats: QueryStats
    let dnsPort: UInt16

    var config: Config
    var meta: [BlockCategory: CacheMeta] = [:]
    var desired: [String] = []
    var installed: HostsFile.BlockInfo?
    var dnsPointed = false
    var proxyRunning = false
    var snapshot = StatsSnapshot()
    var busy: String?
    var log: [LogEntry] = []
    var launchAtLogin = false

    @ObservationIgnored private var sets: [BlockCategory: Set<String>] = [:]
    @ObservationIgnored private var proxy: DNSProxy?
    @ObservationIgnored private var timers: [Timer] = []

    init() {
        installer = HostsInstaller(store: store)
        stats = QueryStats(directory: store.directory)
        dnsPort = UInt16(ProcessInfo.processInfo.environment["HOSTSHIELD_DNS_PORT"] ?? "") ?? 53
        config = store.loadConfig()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        markLaunch()
        Task {
            await reloadLists()
            if config.method == .dns, config.protectionEnabled { await resumeProxy() }
            await refreshSystemState()
            if config.autoUpdate, shouldAutoUpdate { await updateLists() }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.pollStats() }
        })
    }

    // MARK: Derived state

    /// The method actually in effect on the system right now, if any.
    var activeMethod: BlockMethod? {
        if dnsPointed { return .dns }
        if installed != nil { return .hosts }
        return nil
    }

    var protection: Protection {
        if let active = activeMethod, active != config.method { return .switchPending(to: config.method) }
        switch config.method {
        case .hosts:
            if let installed {
                return installed.fingerprint == HostsFile.fingerprint(of: desired) && config.protectionEnabled
                    ? .active(count: installed.domainCount)
                    : .outdated(installed: installed.domainCount, desired: desired.count)
            }
            return config.protectionEnabled ? .removed : .off
        case .dns:
            if proxyRunning && dnsPointed { return .active(count: desired.count) }
            return config.protectionEnabled ? .removed : .off
        }
    }

    var isOn: Bool {
        switch config.method {
        case .hosts: installed != nil
        case .dns: proxyRunning && dnsPointed
        }
    }

    var hostsPath: String { installer.hostsPath }
    /// Something of ours is still configured on the system and would need undoing.
    var hasSystemChanges: Bool { installed != nil || dnsPointed || proxyRunning }

    private var shouldAutoUpdate: Bool {
        guard let last = config.lastUpdateAttempt else { return true }
        return Date().timeIntervalSince(last) > 24 * 3600
    }

    // MARK: Loading

    func reloadLists() async {
        let enabled = Array(config.enabled)
        let store = store
        let loaded = await Task.detached(priority: .userInitiated) {
            var cats: [BlockCategory: Set<String>] = [:]
            var meta: [BlockCategory: CacheMeta] = [:]
            for c in BlockCategory.allCases {
                if let m = store.cacheMeta(c) { meta[c] = m }
                if enabled.contains(c) { cats[c] = store.cachedDomains(c) }
            }
            return (cats, meta)
        }.value
        sets = loaded.0
        meta = loaded.1
        recompute()
    }

    func recompute() {
        desired = Engine.effectiveDomains(config: config, categories: sets)
        proxy?.update(matcher: Engine.matcher(config: config, categories: sets))
    }

    func refreshSystemState() async {
        installed = installer.currentInfo()
        proxyRunning = proxy?.isRunning ?? false
        dnsPointed = NetworkConfig.skip ? proxyRunning : await Task.detached { NetworkConfig.pointsToLoopback() }.value
    }

    func domainCount(_ c: BlockCategory) -> Int? { meta[c]?.count ?? (c.seed.isEmpty ? nil : c.seed.count) }

    private func pollStats() {
        guard proxyRunning else { return }
        snapshot = stats.snapshot()
    }

    private func tick() async {
        let before = protection
        await refreshSystemState()
        if before != .removed, protection == .removed {
            note("Protection is no longer in effect (a macOS update, a network change or another tool undid it).", error: true)
        }
        if config.method == .dns, config.protectionEnabled {
            if !(proxy?.isRunning ?? false) { await resumeProxy() }
            await refreshUpstreams()
        }
        stats.save()
        if config.autoUpdate, shouldAutoUpdate, busy == nil { await updateLists() }
    }

    // MARK: Filter and rule editing

    func setEnabled(_ category: BlockCategory, _ on: Bool) async {
        if on { config.enabled.insert(category) } else { config.enabled.remove(category) }
        store.saveConfig(config)
        if on, sets[category] == nil {
            let store = store
            sets[category] = await Task.detached { store.cachedDomains(category) }.value
        }
        recompute()
    }

    func updateLists() async {
        guard busy == nil else { return }
        busy = "Updating filter lists…"
        let results = await Updater.update(Array(config.enabled), store: store) { r in
            Task { @MainActor in
                if let err = r.error { self.note("\(r.source): \(err)", error: true) }
                else { self.note("\(r.source): \(r.count ?? 0) domains") }
            }
        }
        config.lastUpdateAttempt = Date()
        store.saveConfig(config)
        await reloadLists()
        let failed = results.filter { $0.error != nil }.count
        note(failed == 0 ? "Lists updated." : "Lists updated with \(failed) failed source(s); kept previous data for those.", error: failed > 0)
        busy = nil
    }

    func addAllow(_ text: String) { add(text, to: \.allowlist) }
    func addBlock(_ text: String) { add(text, to: \.customBlocks) }
    func remove(_ domain: String, from path: WritableKeyPath<Config, [String]>) {
        config[keyPath: path].removeAll { $0 == domain }
        store.saveConfig(config)
        recompute()
    }

    private func add(_ text: String, to path: WritableKeyPath<Config, [String]>) {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
        var added = 0
        for p in parts {
            guard let d = Domain.normalize(String(p)) else { note("Ignored invalid domain “\(p)”.", error: true); continue }
            if !config[keyPath: path].contains(d) { config[keyPath: path].append(d); added += 1 }
        }
        if added > 0 { config[keyPath: path].sort(); store.saveConfig(config); recompute() }
    }

    func setAutoUpdate(_ on: Bool) { config.autoUpdate = on; store.saveConfig(config) }
    func setFallback(_ on: Bool) { config.dnsFallback = on; store.saveConfig(config) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            note("Launch at login: \(error.localizedDescription)", error: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Turning protection on and off

    /// Selects the blocking method. Nothing changes on the system (and no password is asked)
    /// until the user applies it.
    func setMethod(_ method: BlockMethod) {
        guard method != config.method else { return }
        config.method = method
        store.saveConfig(config)
        // An idle resolver nobody points at serves no purpose in hosts mode.
        if method == .hosts, !dnsPointed { stopProxy() }
    }

    /// Makes the system match the current settings for the chosen method.
    func apply() async {
        guard busy == nil else { return }
        busy = "Waiting for administrator approval…"
        defer { busy = nil }
        do {
            switch config.method {
            case .hosts: try await applyHosts()
            case .dns: try await applyDNS()
            }
            config.protectionEnabled = true
            store.saveConfig(config)
            await refreshSystemState()
            note(config.method == .hosts
                 ? "Blocking \(desired.count.formatted()) domains through the hosts file."
                 : "DNS sinkhole is running; \(desired.count.formatted()) domains are blocked.")
        } catch InstallError.cancelled {
            note("Cancelled.")
        } catch {
            note(error.localizedDescription, error: true)
            await refreshSystemState()
            if !isOn { config.protectionEnabled = false; store.saveConfig(config) }
        }
    }

    func turnOff() async {
        guard busy == nil else { return }
        busy = "Waiting for administrator approval…"
        defer { busy = nil }
        do {
            try await removeEverything()
            config.protectionEnabled = false
            store.saveConfig(config)
            await refreshSystemState()
            note("Protection turned off. Your original settings are restored.")
        } catch InstallError.cancelled {
            note("Cancelled.")
        } catch {
            note(error.localizedDescription, error: true)
        }
    }

    /// Hosts mode: install the block; if the DNS sinkhole was active, restore DNS in the same prompt.
    private func applyHosts() async throws {
        let change = try installer.stage(domains: desired)
        defer { change.cleanup() }
        var commands = change.commands
        if dnsPointed { commands += NetworkConfig.restoreCommands(backup: config.dnsBackup) }
        try PrivilegedRunner.run(commands, prompt: "Ad-Owl needs to update your system settings.")
        stopProxy()
    }

    /// DNS mode: start the resolver, point macOS at it, and drop the hosts block (it would hide queries from the stats).
    private func applyDNS() async throws {
        let services = await Task.detached { NetworkConfig.services() }.value
        if !dnsPointed {
            config.dnsBackup = await Task.detached { NetworkConfig.currentSettings(for: services) }.value
        }
        let backup = config.dnsBackup
        config.upstream = await Task.detached { NetworkConfig.detectUpstreams(backup: backup) }.value
        let startedHere = proxy?.isRunning != true
        try startProxy()
        let hosts = try installer.stage(domains: nil)
        defer { hosts.cleanup() }
        var commands = hosts.commands
        commands += NetworkConfig.enableCommands(services: services, fallback: config.dnsFallback ? config.upstream : [])
        let output: String
        do {
            output = try PrivilegedRunner.run(commands, prompt: "Ad-Owl needs to point DNS at its local filter.")
        } catch {
            if startedHere { stopProxy() }
            throw error
        }
        // Don't trust the exit status (per-service failures are tolerated): check the result.
        let pointed = NetworkConfig.skip ? true : await Task.detached { NetworkConfig.pointsToLoopback() }.value
        guard pointed else {
            if startedHere { stopProxy() }
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.failed("macOS didn't accept the DNS change, so the DNS filter is not on." + (detail.isEmpty ? "" : " networksetup said: \(detail)"))
        }
    }

    private func removeEverything() async throws {
        var commands: [String] = []
        let hosts = try installer.stage(domains: nil)
        defer { hosts.cleanup() }
        commands += hosts.commands
        if dnsPointed { commands += NetworkConfig.restoreCommands(backup: config.dnsBackup) }
        try PrivilegedRunner.run(commands, prompt: "Ad-Owl needs to restore your system settings.")
        stopProxy()
    }

    // MARK: DNS proxy lifecycle

    private func startProxy() throws {
        if proxy?.isRunning == true { proxy?.update(upstreams: config.upstream); return }
        let p = DNSProxy(port: dnsPort, upstreams: config.upstream,
                         matcher: Engine.matcher(config: config, categories: sets), stats: stats)
        try p.start()
        proxy = p
        proxyRunning = true
    }

    private func stopProxy() {
        proxy?.stop()
        proxy = nil
        proxyRunning = false
        stats.save()
    }

    /// After launch (or a crash): bring the resolver back without touching system settings.
    private func resumeProxy() async {
        do { try startProxy(); note("DNS sinkhole resumed.") }
        catch { note(error.localizedDescription + " DNS may be unreachable; turn blocking off to restore your settings.", error: true) }
    }

    private func refreshUpstreams() async {
        let backup = config.dnsBackup
        let fresh = await Task.detached { NetworkConfig.detectUpstreams(backup: backup) }.value
        guard !fresh.isEmpty, fresh != config.upstream else { return }
        config.upstream = fresh
        store.saveConfig(config)
        proxy?.update(upstreams: fresh)
    }

    /// Restores DNS before the app quits. Returns false if the user declined the password prompt.
    func restoreForQuit() async -> Bool {
        guard hasSystemChanges, config.method == .dns, dnsPointed else { stopProxy(); return true }
        do {
            try PrivilegedRunner.run(NetworkConfig.restoreCommands(backup: config.dnsBackup),
                                     prompt: "Ad-Owl is quitting and will restore your DNS settings.")
            config.protectionEnabled = false
            store.saveConfig(config)
            stopProxy()
            return true
        } catch {
            note(error.localizedDescription, error: true)
            return false
        }
    }

    // MARK: Domain check

    func check(_ text: String) async -> CheckResult? {
        guard let lookup = Engine.lookup(text, config: config, store: store) else { return nil }
        let host = lookup.domain
        let addrs = await Task.detached { Self.resolve(host) }.value
        let inFile = installer.read().contains("0.0.0.0 \(host)\n")
        return CheckResult(lookup: lookup, addresses: addrs, inHostsFile: inFile, viaSinkhole: proxyRunning && dnsPointed)
    }

    nonisolated static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                if !out.contains(s) { out.append(s) }
            }
            p = a.pointee.ai_next
        }
        return out
    }

    func note(_ text: String, error: Bool = false) {
        log.insert(LogEntry(text: text, isError: error), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
        appendToLogFile((error ? "ERROR " : "") + text)
    }

    // MARK: Diagnostics

    private var logFile: URL { store.directory.appendingPathComponent("activity.log") }
    private var runningMarker: URL { store.directory.appendingPathComponent(".running") }

    private func appendToLogFile(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    /// Called at launch: records the start and reports whether the previous run ended without quitting.
    private func markLaunch() {
        if FileManager.default.fileExists(atPath: runningMarker.path) {
            note("The previous Ad-Owl session ended without quitting normally (crash, force quit or logout).", error: true)
        }
        try? Data().write(to: runningMarker)
        note("Ad-Owl started (method: \(config.method == .dns ? "DNS filter" : "hosts file")).")
    }

    func markCleanExit(_ reason: String) {
        appendToLogFile("Ad-Owl quit: \(reason)")
        try? FileManager.default.removeItem(at: runningMarker)
    }
}
