import Foundation

/// Reads and builds changes to macOS DNS settings. Reads need no privileges; changes are returned
/// as shell commands for `PrivilegedRunner`.
public enum NetworkConfig {
    /// Dev/test switch: leave real network settings alone.
    public static var skip: Bool { ProcessInfo.processInfo.environment["HOSTSHIELD_SKIP_NETWORK"] == "1" }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    struct HardwarePort { var name: String; var device: String }

    static func hardwarePorts() -> [HardwarePort] {
        var out: [HardwarePort] = []
        var name: String?
        for line in run("/usr/sbin/networksetup", ["-listallhardwareports"]).split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { name = String(line.dropFirst(15)) }
            else if line.hasPrefix("Device: "), let n = name { out.append(HardwarePort(name: n, device: String(line.dropFirst(8)))); name = nil }
        }
        return out
    }

    /// Enabled network services that sit on real hardware (Wi-Fi, Ethernet, USB LAN…); VPN entries are left alone.
    public static func services() -> [String] {
        if skip { return [] }
        let hardware = Set(hardwarePorts().map(\.name))
        return run("/usr/sbin/networksetup", ["-listallnetworkservices"])
            .split(separator: "\n").dropFirst()
            .map(String.init)
            .filter { !$0.hasPrefix("*") && hardware.contains($0) }
    }

    /// Manually configured DNS servers (empty = automatic / DHCP).
    public static func dnsServers(_ service: String) -> [String] {
        run("/usr/sbin/networksetup", ["-getdnsservers", service])
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.contains(" ") && !$0.isEmpty }
    }

    public static func isLoopback(_ s: String) -> Bool { s == "127.0.0.1" || s == "::1" }

    /// Addresses `networksetup -setdnsservers` accepts: IPv4, or global IPv6 without a `%scope`.
    /// One bad entry makes it reject the whole list, so link-local servers (common on iPhone
    /// hotspots, e.g. `fe80::1%en0`) must never be passed.
    public static func isSettable(_ s: String) -> Bool {
        if s.contains("%") || s.lowercased().hasPrefix("fe80:") || isLoopback(s) { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// True when any hardware service sends DNS to this Mac.
    public static func pointsToLoopback() -> Bool {
        if skip { return true }
        return services().contains { dnsServers($0).contains(where: isLoopback) }
    }

    /// DNS servers currently in effect, excluding loopback: what we should forward to.
    public static func detectUpstreams(backup: [String: [String]] = [:]) -> [String] {
        var found: [String] = []
        func add(_ s: String) { if !isLoopback(s), !s.isEmpty, !found.contains(s) { found.append(s) } }
        // 1. The system's primary resolver (only meaningful while we are not already in the path).
        var inFirst = false
        for line in run("/usr/sbin/scutil", ["--dns"]).split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("resolver #2") { break }
            if l.hasPrefix("resolver #1") { inFirst = true }
            if inFirst, l.hasPrefix("nameserver["), let ip = l.split(separator: ":", maxSplits: 1).last { add(ip.trimmingCharacters(in: .whitespaces)) }
        }
        // 2. DHCP-provided servers per interface (visible even when a manual entry overrides them).
        for port in hardwarePorts() {
            let out = run("/usr/sbin/ipconfig", ["getoption", port.device, "domain_name_server"])
            for ip in out.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) { add(String(ip)) }
        }
        // 3. What the user had configured manually before HostShield.
        for list in backup.values { list.forEach(add) }
        // IPv4 first: simplest to reach and the only kind every network setting accepts.
        let v4 = found.filter { !$0.contains(":") }
        return Array((v4 + found.filter { $0.contains(":") }).prefix(4))
    }

    /// Snapshot of manual DNS settings, ignoring any loopback entry left by an earlier run.
    public static func currentSettings(for services: [String]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: services.map { ($0, dnsServers($0).filter { !isLoopback($0) }) })
    }

    // MARK: Commands (run as administrator)

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func enableCommands(services: [String], fallback: [String]) -> [String] {
        if skip { return [] }
        let servers = (["127.0.0.1"] + fallback.filter(isSettable).prefix(2)).map(q).joined(separator: " ")
        // `2>&1 || true`: one service failing must not block the others; its message is returned
        // to the app, which then verifies the result instead of trusting the exit code.
        return services.map { "/usr/sbin/networksetup -setdnsservers \(q($0)) \(servers) 2>&1 || true" }
            + ["/usr/bin/dscacheutil -flushcache || true", "/usr/bin/killall -HUP mDNSResponder || true"]
    }

    public static func restoreCommands(backup: [String: [String]]) -> [String] {
        if skip { return [] }
        let live = Set(services())
        return backup.keys.sorted().filter(live.contains).map { svc in
            let servers = (backup[svc] ?? []).filter(isSettable)
            let arg = servers.isEmpty ? "Empty" : servers.map(q).joined(separator: " ")
            return "/usr/sbin/networksetup -setdnsservers \(q(svc)) \(arg) 2>&1 || true"
        } + ["/usr/bin/dscacheutil -flushcache || true", "/usr/bin/killall -HUP mDNSResponder || true"]
    }
}

/// Runs shell commands as root through the standard macOS administrator prompt.
public enum PrivilegedRunner {
    /// Returns what the commands printed.
    @MainActor
    @discardableResult
    public static func run(_ commands: [String], prompt: String) throws -> String {
        guard !commands.isEmpty else { return "" }
        let shell = commands.joined(separator: " && ")
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = "do shell script \"\(esc(shell))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) == -128 { throw InstallError.cancelled }
            throw InstallError.failed(err[NSAppleScript.errorMessage] as? String ?? "Unknown error")
        }
        return result?.stringValue ?? ""
    }
}
