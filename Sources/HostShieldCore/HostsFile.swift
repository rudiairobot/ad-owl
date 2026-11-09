import Foundation

/// Builds and edits the HostShield-managed region of a hosts file.
public enum HostsFile {
    public static let beginMarker = "# >>> HostShield begin"
    public static let endMarker = "# <<< HostShield end"

    public struct BlockInfo: Equatable, Sendable {
        public var domainCount: Int
        public var fingerprint: String
    }

    /// Stable fingerprint of a domain set (FNV-1a over the sorted list).
    public static func fingerprint(of domains: [String]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for d in domains {
            for b in d.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            h = (h ^ 0x0a) &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    public static func block(for domains: [String]) -> String {
        let sorted = domains.sorted()
        var s = "\(beginMarker) count=\(sorted.count) fp=\(fingerprint(of: sorted))\n"
        s.reserveCapacity(sorted.count * 24)
        for d in sorted { s += "0.0.0.0 \(d)\n" }
        s += "\(endMarker)\n"
        return s
    }

    /// `content` with any existing HostShield block removed.
    public static func stripping(_ content: String) -> String {
        var out: [Substring] = []
        var inside = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(beginMarker) { inside = true; continue }
            if inside {
                if line.hasPrefix(endMarker) { inside = false }
                continue
            }
            out.append(line)
        }
        var s = out.joined(separator: "\n")
        while s.hasSuffix("\n\n") { s.removeLast() }
        if !s.isEmpty, !s.hasSuffix("\n") { s += "\n" }
        return s
    }

    /// `content` with the HostShield block replaced by one for `domains`.
    public static func installing(_ domains: [String], into content: String) -> String {
        stripping(content) + block(for: domains)
    }

    public static func info(in content: String) -> BlockInfo? {
        for line in content.split(separator: "\n") where line.hasPrefix(beginMarker) {
            var count = 0
            var fp = ""
            for part in line.split(separator: " ") {
                if part.hasPrefix("count=") { count = Int(part.dropFirst(6)) ?? 0 }
                if part.hasPrefix("fp=") { fp = String(part.dropFirst(3)) }
            }
            return BlockInfo(domainCount: count, fingerprint: fp)
        }
        return nil
    }

    /// Refuse to write a hosts file that lost its loopback entry.
    public static func isSane(_ content: String) -> Bool {
        content.split(separator: "\n").contains { line in
            let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return p.count >= 2 && p[0] == "127.0.0.1" && p.dropFirst().contains("localhost")
        }
    }
}
