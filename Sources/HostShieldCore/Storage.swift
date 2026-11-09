import Foundation

public enum BlockMethod: String, Codable, CaseIterable, Sendable {
    /// Edit /etc/hosts. Simple, no background process, but no statistics.
    case hosts
    /// Run a local DNS resolver. Live statistics and subdomain blocking.
    case dns
}

public struct Config: Codable, Equatable, Sendable {
    public var enabled: Set<BlockCategory> = Set(BlockCategory.allCases.filter(\.defaultEnabled))
    public var allowlist: [String] = []
    public var customBlocks: [String] = []
    public var autoUpdate: Bool = true
    public var lastUpdateAttempt: Date?
    /// The user wants blocking on; lets the app notice when something removes it.
    public var protectionEnabled: Bool = false
    public var method: BlockMethod = .hosts
    /// DNS mode: keep the original DNS servers as a backup entry so DNS still works if HostShield dies.
    public var dnsFallback: Bool = true
    /// DNS mode: servers queries are forwarded to.
    public var upstream: [String] = []
    /// DNS mode: network service name -> DNS servers it had before HostShield (empty = automatic).
    public var dnsBackup: [String: [String]] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Set<BlockCategory>.self, forKey: .enabled) ?? d.enabled
        allowlist = try c.decodeIfPresent([String].self, forKey: .allowlist) ?? []
        customBlocks = try c.decodeIfPresent([String].self, forKey: .customBlocks) ?? []
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        lastUpdateAttempt = try c.decodeIfPresent(Date.self, forKey: .lastUpdateAttempt)
        protectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .protectionEnabled) ?? false
        method = try c.decodeIfPresent(BlockMethod.self, forKey: .method) ?? .hosts
        dnsFallback = try c.decodeIfPresent(Bool.self, forKey: .dnsFallback) ?? true
        upstream = try c.decodeIfPresent([String].self, forKey: .upstream) ?? []
        dnsBackup = try c.decodeIfPresent([String: [String]].self, forKey: .dnsBackup) ?? [:]
    }
}

public struct CacheMeta: Codable, Equatable, Sendable {
    public var count: Int
    public var updated: Date
}

/// On-disk state under ~/Library/Application Support/HostShield (or `HOSTSHIELD_HOME`).
public final class Store: @unchecked Sendable {
    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let env = ProcessInfo.processInfo.environment["HOSTSHIELD_HOME"] {
            self.directory = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            self.directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HostShield", isDirectory: true)
        }
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    var configURL: URL { directory.appendingPathComponent("config.json") }
    var cacheDirectory: URL { directory.appendingPathComponent("cache", isDirectory: true) }
    public var stagingDirectory: URL { directory.appendingPathComponent("staging", isDirectory: true) }

    public func loadConfig() -> Config {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? dec.decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    public func saveConfig(_ config: Config) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(config) { try? data.write(to: configURL, options: .atomic) }
    }

    // MARK: List cache (one file per source)

    private func cacheURL(_ category: BlockCategory, _ index: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(category.rawValue)-\(index).txt")
    }

    public func writeCache(_ domains: Set<String>, category: BlockCategory, sourceIndex: Int) throws {
        let text = domains.sorted().joined(separator: "\n")
        try text.write(to: cacheURL(category, sourceIndex), atomically: true, encoding: .utf8)
    }

    public func cachedDomains(_ category: BlockCategory) -> Set<String> {
        var out = Set(category.seed.compactMap(Domain.normalize))
        for i in category.sources.indices {
            guard let text = try? String(contentsOf: cacheURL(category, i), encoding: .utf8) else { continue }
            text.enumerateLines { line, _ in if Domain.isValid(line) { out.insert(line) } }
        }
        return out
    }

    public func cacheMeta(_ category: BlockCategory) -> CacheMeta? {
        var newest: Date?
        for i in category.sources.indices {
            let url = cacheURL(category, i)
            if let d = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                newest = max(newest ?? d, d)
            }
        }
        guard let newest else { return nil }
        return CacheMeta(count: cachedDomains(category).count, updated: newest)
    }
}

/// Computes what should be blocked.
public enum Engine {
    /// Hosts that must stay reachable: the list providers themselves, so updates keep working.
    public static var protectedHosts: Set<String> {
        var s = Set<String>()
        for c in BlockCategory.allCases {
            for src in c.sources { if let h = src.url.host { s.insert(h.lowercased()) } }
        }
        return s
    }

    public static func effectiveDomains(config: Config, categories: [BlockCategory: Set<String>]) -> [String] {
        var all = Set<String>()
        for c in config.enabled { all.formUnion(categories[c] ?? []) }
        all.formUnion(config.customBlocks.compactMap(Domain.normalize))
        all.subtract(config.allowlist.compactMap(Domain.normalize))
        all.subtract(protectedHosts)
        return all.sorted()
    }

    public static func effectiveDomains(config: Config, store: Store) -> [String] {
        var cats: [BlockCategory: Set<String>] = [:]
        for c in config.enabled { cats[c] = store.cachedDomains(c) }
        return effectiveDomains(config: config, categories: cats)
    }

    public struct Lookup: Sendable {
        public var domain: String
        public var categories: [BlockCategory]
        public var custom: Bool
        public var allowlisted: Bool
        public var isProtected: Bool
    }

    /// Why a domain is (or isn't) blocked. Matches the exact host and each parent
    /// is NOT checked: hosts files only block exact names.
    public static func lookup(_ raw: String, config: Config, store: Store) -> Lookup? {
        guard let d = Domain.normalize(raw) else { return nil }
        let cats = BlockCategory.allCases.filter { store.cachedDomains($0).contains(d) }
        return Lookup(
            domain: d,
            categories: cats,
            custom: config.customBlocks.compactMap(Domain.normalize).contains(d),
            allowlisted: config.allowlist.compactMap(Domain.normalize).contains(d),
            isProtected: protectedHosts.contains(d)
        )
    }
}
