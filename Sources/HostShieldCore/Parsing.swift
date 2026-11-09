import Foundation

public enum Domain {
    /// Hostnames that must never be blocked, whatever a list says.
    public static let reserved: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost",
        "ip6-localhost", "ip6-loopback", "ip6-localnet", "ip6-mcastprefix",
        "ip6-allnodes", "ip6-allrouters", "ip6-allhosts", "0.0.0.0",
    ]

    /// Strict LDH hostname with at least one dot, so a corrupted list or
    /// config can never inject anything but `0.0.0.0 <hostname>` into /etc/hosts.
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<slash]) }
        if s.hasSuffix(".") { s.removeLast() }
        guard isValid(s) else { return nil }
        return s
    }

    public static func isValid(_ s: String) -> Bool {
        guard s.utf8.count <= 253, s.contains("."), !reserved.contains(s) else { return false }
        // Reject IPv4 literals.
        if s.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.utf8.count) else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for u in label.utf8 {
                let ok = (u >= 0x61 && u <= 0x7a) || (u >= 0x30 && u <= 0x39) || u == 0x2d || u == 0x5f
                if !ok { return false }
            }
        }
        return true
    }
}

public enum ListParser {
    public static func parse(_ text: String, format: ListFormat) -> Set<String> {
        switch format {
        case .hosts: parseHosts(text)
        case .abp: parseABP(text)
        }
    }

    /// `0.0.0.0 host` / `127.0.0.1 host` lines; comments and other IPs ignored.
    public static func parseHosts(_ text: String) -> Set<String> {
        var out = Set<String>()
        text.enumerateLines { line, _ in
            var l = Substring(line)
            if let hash = l.firstIndex(of: "#") { l = l[..<hash] }
            l = l.drop(while: { $0 == "\u{FEFF}" })
            let parts = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "0.0.0.0" || parts[0] == "127.0.0.1" else { return }
            for host in parts.dropFirst() {
                if let d = Domain.normalize(String(host)) { out.insert(d) }
            }
        }
        return out
    }

    /// Keeps only whole-domain rules (`||example.com^`, optionally `$third-party`).
    /// Path rules, wildcards, exceptions, cosmetic rules and other options need a
    /// browser extension and are skipped.
    public static func parseABP(_ text: String) -> Set<String> {
        var out = Set<String>()
        text.enumerateLines { line, _ in
            guard line.hasPrefix("||") else { return }
            var rule = line.dropFirst(2)
            if let dollar = rule.firstIndex(of: "$") {
                let opts = rule[rule.index(after: dollar)...]
                guard opts == "third-party" || opts == "3p" else { return }
                rule = rule[..<dollar]
            }
            guard rule.hasSuffix("^") else { return }
            rule = rule.dropLast()
            if let d = Domain.normalize(String(rule)), !rule.contains("/"), !rule.contains("*") { out.insert(d) }
        }
        return out
    }
}
