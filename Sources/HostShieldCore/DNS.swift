import Foundation

public struct DNSQuestion: Sendable, Equatable {
    public var name: String
    public var type: UInt16
    public var cls: UInt16
    /// Offset just past the question section.
    var end: Int
}

/// Minimal DNS wire-format handling: just enough to read a query and answer it with a sinkhole.
public enum DNSPacket {
    public static let typeA: UInt16 = 1
    public static let typeAAAA: UInt16 = 28

    public static func parseQuestion(_ d: [UInt8]) -> DNSQuestion? {
        guard d.count >= 17 else { return nil }
        let flags = UInt16(d[2]) << 8 | UInt16(d[3])
        let qd = UInt16(d[4]) << 8 | UInt16(d[5])
        guard flags & 0x8000 == 0, (flags >> 11) & 0xF == 0, qd == 1 else { return nil }
        var i = 12
        var labels: [String] = []
        var total = 0
        while true {
            guard i < d.count else { return nil }
            let len = Int(d[i])
            if len == 0 { i += 1; break }
            guard len & 0xC0 == 0, len <= 63, i + 1 + len <= d.count else { return nil }
            total += len + 1
            guard total <= 255 else { return nil }
            labels.append(String(decoding: d[(i + 1)..<(i + 1 + len)], as: UTF8.self).lowercased())
            i += 1 + len
        }
        guard i + 4 <= d.count else { return nil }
        let type = UInt16(d[i]) << 8 | UInt16(d[i + 1])
        let cls = UInt16(d[i + 2]) << 8 | UInt16(d[i + 3])
        return DNSQuestion(name: labels.joined(separator: "."), type: type, cls: cls, end: i + 4)
    }

    /// Answers A with 0.0.0.0 and AAAA with `::`; every other type gets an empty NOERROR (NODATA).
    public static func sinkholeReply(query: [UInt8], question q: DNSQuestion) -> [UInt8] {
        let rd = query[2] & 0x01
        var r: [UInt8] = [query[0], query[1], 0x80 | rd, 0x80, 0, 1, 0, 0, 0, 0, 0, 0]
        let answers: Int
        switch q.type {
        case typeA: answers = 1
        case typeAAAA: answers = 1
        default: answers = 0
        }
        r[7] = UInt8(answers)
        r += query[12..<q.end]
        if answers == 1 {
            r += [0xC0, 0x0C, UInt8(q.type >> 8), UInt8(q.type & 0xFF), 0, 1, 0, 0, 0, 60]
            let size = q.type == typeA ? 4 : 16
            r += [0, UInt8(size)]
            r += [UInt8](repeating: 0, count: size)
        }
        return r
    }

    /// SERVFAIL for when no upstream answers.
    public static func servfail(query: [UInt8]) -> [UInt8] {
        guard query.count >= 12 else { return [] }
        var r = Array(query[0..<12])
        r[2] = 0x80 | (query[2] & 0x01)
        r[3] = 0x82
        r[6] = 0; r[7] = 0; r[8] = 0; r[9] = 0; r[10] = 0; r[11] = 0
        if let q = parseQuestion(query) { r += query[12..<q.end] } else { r[4] = 0; r[5] = 0 }
        return r
    }
}

/// Decides whether a name is blocked. A listed domain also blocks its subdomains
/// (like Adblock Plus's `||domain^`), and allowed domains cover their subdomains too.
public struct BlockMatcher: Sendable {
    public enum Decision: Equatable, Sendable {
        case pass
        case allowed
        case blocked(rule: String)
    }

    public var blocked: Set<String>
    public var allowed: Set<String>

    public init(blocked: Set<String> = [], allowed: Set<String> = []) {
        self.blocked = blocked
        self.allowed = allowed
    }

    public func decide(_ name: String) -> Decision {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return .pass }
        var candidates: [String] = []
        for start in 0...(labels.count - 2) { candidates.append(labels[start...].joined(separator: ".")) }
        if candidates.contains(where: allowed.contains) { return .allowed }
        if let hit = candidates.first(where: blocked.contains) { return .blocked(rule: hit) }
        return .pass
    }
}

extension Engine {
    public static func matcher(config: Config, categories: [BlockCategory: Set<String>]) -> BlockMatcher {
        var blocked = Set<String>()
        for c in config.enabled { blocked.formUnion(categories[c] ?? []) }
        blocked.formUnion(config.customBlocks.compactMap(Domain.normalize))
        var allowed = Set(config.allowlist.compactMap(Domain.normalize))
        allowed.formUnion(protectedHosts)
        return BlockMatcher(blocked: blocked, allowed: allowed)
    }
}
