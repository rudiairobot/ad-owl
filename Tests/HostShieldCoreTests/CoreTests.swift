import XCTest
@testable import HostShieldCore

final class CoreTests: XCTestCase {
    func testDomainNormalize() {
        XCTAssertEqual(Domain.normalize("https://Ads.Example.com/path?x=1"), "ads.example.com")
        XCTAssertEqual(Domain.normalize("tracker.example.com."), "tracker.example.com")
        XCTAssertNil(Domain.normalize("localhost"))
        XCTAssertNil(Domain.normalize("127.0.0.1"))
        XCTAssertNil(Domain.normalize("bad host.com"))
        XCTAssertNil(Domain.normalize("evil.com\n127.0.0.1 apple.com"))
        XCTAssertNil(Domain.normalize("-bad.example.com"))
        XCTAssertNil(Domain.normalize("nodot"))
    }

    func testParseHosts() {
        let text = """
        # comment
        127.0.0.1 localhost
        0.0.0.0 ads.example.com
        0.0.0.0 a.example.com b.example.com # trailing
        192.168.1.1 router.lan
        0.0.0.0 0.0.0.0
        """
        XCTAssertEqual(ListParser.parseHosts(text), ["ads.example.com", "a.example.com", "b.example.com"])
    }

    func testParseABPKeepsOnlyPlainDomainRules() {
        let text = """
        [Adblock Plus 2.0]
        ! comment
        ||plain.example.com^
        ||third.example.net^$third-party
        ||path.example.org/ads^
        ||wild*.example.org^
        ||img.example.org^$image
        @@||allow.example.com^
        ##.banner
        example.com##.ad
        """
        XCTAssertEqual(ListParser.parseABP(text), ["plain.example.com", "third.example.net"])
    }

    func testHostsBlockRoundTrip() {
        let original = "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1 localhost\n"
        let once = HostsFile.installing(["b.example.com", "a.example.com"], into: original)
        XCTAssertTrue(once.hasPrefix(original))
        XCTAssertEqual(HostsFile.info(in: once)?.domainCount, 2)
        // Reinstalling replaces, never duplicates.
        let twice = HostsFile.installing(["c.example.com"], into: once)
        XCTAssertEqual(twice.components(separatedBy: HostsFile.beginMarker).count, 2)
        XCTAssertFalse(twice.contains("a.example.com"))
        XCTAssertTrue(twice.contains("0.0.0.0 c.example.com"))
        // Removal restores the user's original content.
        XCTAssertEqual(HostsFile.stripping(twice), original)
        XCTAssertTrue(HostsFile.isSane(twice))
        XCTAssertFalse(HostsFile.isSane("0.0.0.0 ads.example.com\n"))
    }

    func testFingerprintDependsOnContent() {
        XCTAssertEqual(HostsFile.fingerprint(of: ["a.com", "b.com"]), HostsFile.fingerprint(of: ["a.com", "b.com"]))
        XCTAssertNotEqual(HostsFile.fingerprint(of: ["a.com", "b.com"]), HostsFile.fingerprint(of: ["a.com", "c.com"]))
    }

    func testEffectiveDomainsAllowlistAndProtection() {
        var cfg = Config()
        cfg.enabled = [.ads, .trackers]
        cfg.allowlist = ["Keep.example.com"]
        cfg.customBlocks = ["https://custom.example.com/x", "not a domain"]
        let cats: [BlockCategory: Set<String>] = [
            .ads: ["ad.example.com", "keep.example.com", "raw.githubusercontent.com"],
            .trackers: ["t.example.com"],
            .malware: ["never.example.com"],
        ]
        XCTAssertEqual(Engine.effectiveDomains(config: cfg, categories: cats),
                       ["ad.example.com", "custom.example.com", "t.example.com"])
    }

    func testStoreCacheAndConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        var cfg = store.loadConfig()
        XCTAssertEqual(cfg.enabled, [.ads, .trackers, .malware])
        cfg.allowlist = ["x.example.com"]
        store.saveConfig(cfg)
        XCTAssertEqual(store.loadConfig().allowlist, ["x.example.com"])

        try store.writeCache(["a.example.com", "b.example.com"], category: .trackers, sourceIndex: 0)
        XCTAssertEqual(store.cachedDomains(.trackers), ["a.example.com", "b.example.com"])
        XCTAssertEqual(store.cacheMeta(.trackers)?.count, 2)
        // Seed domains are available before any download.
        XCTAssertTrue(store.cachedDomains(.cookieConsent).contains("cdn.cookielaw.org"))
        XCTAssertNil(store.cacheMeta(.ads))
    }

    func testInstallerWritesAndRemovesOnCustomPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = dir.appendingPathComponent("hosts")
        try "127.0.0.1 localhost\n".write(to: hosts, atomically: true, encoding: .utf8)
        setenv("HOSTSHIELD_HOSTS", hosts.path, 1)
        defer { unsetenv("HOSTSHIELD_HOSTS") }

        let installer = HostsInstaller(store: Store(directory: dir))
        try await installer.write(domains: ["ad.example.com"])
        XCTAssertEqual(installer.currentInfo()?.domainCount, 1)
        try await installer.write(domains: nil)
        XCTAssertNil(installer.currentInfo())
        XCTAssertEqual(installer.read(), "127.0.0.1 localhost\n")
    }
}

/// Hits the real list providers. Run with: HOSTSHIELD_LIVE=1 swift test --filter LiveTests
final class LiveTests: XCTestCase {
    func testAllSourcesDownloadAndParse() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOSTSHIELD_LIVE"] == "1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hs-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        let results = await Updater.update(BlockCategory.allCases, store: store)
        for r in results { print("LIVE \(r.category.rawValue) | \(r.source): \(r.count.map(String.init) ?? "ERROR \(r.error ?? "")")") }
        XCTAssertTrue(results.allSatisfy { $0.error == nil }, "some sources failed")
        var cfg = Config(); cfg.enabled = Set(BlockCategory.allCases)
        let domains = Engine.effectiveDomains(config: cfg, store: store)
        print("LIVE total effective domains: \(domains.count)")
        XCTAssertGreaterThan(domains.count, 100_000)
        XCTAssertFalse(domains.contains("raw.githubusercontent.com"))
        XCTAssertTrue(domains.contains("cdn.cookielaw.org"))
    }
}
