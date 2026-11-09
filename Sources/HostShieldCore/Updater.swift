import Foundation

public struct UpdateResult: Sendable {
    public var category: BlockCategory
    public var source: String
    public var count: Int?
    public var error: String?
}

public enum Updater {
    /// Downloads and parses every source of `categories`. Failed sources keep their old cache.
    public static func update(
        _ categories: [BlockCategory],
        store: Store,
        session: URLSession = .shared,
        progress: (@Sendable (UpdateResult) -> Void)? = nil
    ) async -> [UpdateResult] {
        var results: [UpdateResult] = []
        for category in categories {
            for (i, source) in category.sources.enumerated() {
                var r = UpdateResult(category: category, source: source.name)
                do {
                    var req = URLRequest(url: source.url, timeoutInterval: 60)
                    req.setValue("Ad-Owl/1.0", forHTTPHeaderField: "User-Agent")
                    let (data, resp) = try await session.data(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                    }
                    let text = String(decoding: data, as: UTF8.self)
                    let domains = ListParser.parse(text, format: source.format)
                    guard !domains.isEmpty else {
                        throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "No usable entries"])
                    }
                    try store.writeCache(domains, category: category, sourceIndex: i)
                    r.count = domains.count
                } catch {
                    r.error = error.localizedDescription
                }
                results.append(r)
                progress?(r)
            }
        }
        return results
    }
}
