import Foundation

public struct QueryEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let name: String
    public let blocked: Bool
}

public struct HourBucket: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let allowed: Int
    public let blocked: Int
}

public struct StatsSnapshot: Sendable {
    public var totalToday = 0
    public var blockedToday = 0
    public var hours: [HourBucket] = []          // last 24 hours, oldest first
    public var topBlocked: [(domain: String, count: Int)] = []
    public var recent: [QueryEntry] = []         // newest first

    public init() {}
    public var blockRate: Double { totalToday == 0 ? 0 : Double(blockedToday) / Double(totalToday) }
}

/// Thread-safe query counters, persisted hourly buckets (7 days) and a recent-query ring.
public final class QueryStats: @unchecked Sendable {
    private struct Persisted: Codable {
        var hours: [Int: [Int]] = [:]       // hour index -> [total, blocked]
        var day: Int = 0
        var top: [String: Int] = [:]
    }

    private let lock = NSLock()
    private var data = Persisted()
    private var ring: [QueryEntry] = []
    private let url: URL?
    private let calendar = Calendar.current

    public init(directory: URL? = nil) {
        url = directory?.appendingPathComponent("stats.json")
        if let url, let raw = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Persisted.self, from: raw) {
            data = p
        }
        rollDayIfNeeded(now: Date())
    }

    private func dayIndex(_ d: Date) -> Int { Int(calendar.startOfDay(for: d).timeIntervalSince1970 / 86400) }

    private func rollDayIfNeeded(now: Date) {
        let today = dayIndex(now)
        if data.day != today { data.day = today; data.top = [:] }
    }

    public func record(name: String, blocked: Bool, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        rollDayIfNeeded(now: date)
        let h = Int(date.timeIntervalSince1970 / 3600)
        var b = data.hours[h] ?? [0, 0]
        b[0] += 1
        if blocked {
            b[1] += 1
            data.top[name, default: 0] += 1
            if data.top.count > 5000 { data.top = data.top.filter { $0.value > 1 } }
        }
        data.hours[h] = b
        ring.append(QueryEntry(date: date, name: name, blocked: blocked))
        if ring.count > 500 { ring.removeFirst(ring.count - 500) }
    }

    public func snapshot(now: Date = Date()) -> StatsSnapshot {
        lock.lock(); defer { lock.unlock() }
        var s = StatsSnapshot()
        let nowHour = Int(now.timeIntervalSince1970 / 3600)
        let todayStart = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        for (h, v) in data.hours where h * 3600 >= todayStart {
            s.totalToday += v[0]; s.blockedToday += v[1]
        }
        for h in (nowHour - 23)...nowHour {
            let v = data.hours[h] ?? [0, 0]
            s.hours.append(HourBucket(start: Date(timeIntervalSince1970: Double(h * 3600)), allowed: v[0] - v[1], blocked: v[1]))
        }
        s.topBlocked = data.top.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(10).map { ($0.key, $0.value) }
        s.recent = Array(ring.suffix(200).reversed())
        return s
    }

    public func save() {
        lock.lock()
        let cutoff = Int(Date().timeIntervalSince1970 / 3600) - 24 * 7
        data.hours = data.hours.filter { $0.key >= cutoff }
        let copy = data
        lock.unlock()
        guard let url, let raw = try? JSONEncoder().encode(copy) else { return }
        try? raw.write(to: url, options: .atomic)
    }
}
