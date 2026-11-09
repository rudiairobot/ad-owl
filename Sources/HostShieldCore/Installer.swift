import Foundation

public enum InstallError: LocalizedError {
    case unsafe(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsafe(let m): "Refused to write hosts file: \(m)"
        case .cancelled: "Administrator authorization was cancelled."
        case .failed(let m): m
        }
    }
}

/// Shell commands to run as root plus cleanup for the files they read.
public struct PreparedChange: Sendable {
    public var commands: [String] = []
    public var cleanup: @Sendable () -> Void = {}
    public init(commands: [String] = [], cleanup: @escaping @Sendable () -> Void = {}) {
        self.commands = commands; self.cleanup = cleanup
    }
}

/// Reads and writes the system hosts file, asking macOS for administrator rights when needed.
public struct HostsInstaller: Sendable {
    public let hostsPath: String
    public let stagingDirectory: URL

    public init(store: Store) {
        hostsPath = ProcessInfo.processInfo.environment["HOSTSHIELD_HOSTS"] ?? "/etc/hosts"
        stagingDirectory = store.stagingDirectory
    }

    public func read() -> String {
        (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
    }

    public func currentInfo() -> HostsFile.BlockInfo? { HostsFile.info(in: read()) }

    /// Installs a block for `domains`, or removes ours when `domains` is nil.
    public func write(domains: [String]?) async throws {
        let change = try stage(domains: domains)
        defer { change.cleanup() }
        _ = try await PrivilegedRunner.run(change.commands, prompt: "Ad-Owl needs to update the system hosts file.")
    }

    /// Prepares the root commands for a hosts change without running them, so several system
    /// changes can share one password prompt. Writes directly (no commands) for non-system paths.
    public func stage(domains: [String]?) throws -> PreparedChange {
        let current = read()
        let updated = domains.map { HostsFile.installing($0, into: current) } ?? HostsFile.stripping(current)
        guard HostsFile.isSane(updated) else {
            throw InstallError.unsafe("the result has no 127.0.0.1 localhost entry")
        }
        if updated == current { return PreparedChange() }

        if hostsPath != "/etc/hosts" {
            try updated.write(toFile: hostsPath, atomically: true, encoding: .utf8)
            return PreparedChange()
        }

        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let staged = stagingDirectory.appendingPathComponent("hosts.new")
        try updated.write(to: staged, atomically: true, encoding: .utf8)

        // install(1) would replace a symlink, so target the real file.
        let target = URL(fileURLWithPath: hostsPath).resolvingSymlinksInPath().path
        let backup = target + ".hostshield-backup"
        return PreparedChange(commands: [
            "([ -e \(q(backup)) ] || /bin/cp \(q(target)) \(q(backup)))",
            "/usr/bin/install -m 644 -o root -g wheel \(q(staged.path)) \(q(target))",
            "/usr/bin/dscacheutil -flushcache || true",
            "/usr/bin/killall -HUP mDNSResponder || true",
        ], cleanup: { try? FileManager.default.removeItem(at: staged) })
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
