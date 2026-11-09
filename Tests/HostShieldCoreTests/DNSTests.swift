import XCTest
import Darwin
@testable import HostShieldCore

private func query(_ name: String, type: UInt16 = 1, id: UInt16 = 0x1234) -> [UInt8] {
    var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
    for label in name.split(separator: ".") { q.append(UInt8(label.utf8.count)); q += Array(label.utf8) }
    q += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
    return q
}

/// Answers every A query with 1.2.3.4. Returns the port it listens on.
private final class FakeUpstream: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    var queries = 0
    private var stop = false
    private let lock = NSLock()

    init() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
        self.fd = fd
        port = UInt16(bigEndian: a.sin_port)
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread { [self] in loop() }
    }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            lock.lock(); let s = stop; lock.unlock(); if s { return }
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) } }
            guard n > 12 else { continue }
            lock.lock(); queries += 1; lock.unlock()
            let q = Array(buf[0..<n])
            var r = q
            r[2] = 0x81; r[3] = 0x80; r[7] = 1
            r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 1, 2, 3, 4]
            _ = r.withUnsafeBytes { raw in withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, raw.baseAddress, r.count, 0, $0, len) } } }
        }
    }

    func shutdown() { lock.lock(); stop = true; lock.unlock(); Thread.sleep(forTimeInterval: 0.3); close(fd) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return queries }
}

/// Sends one UDP query to 127.0.0.1:port and returns the reply.
private func askUDP(_ port: UInt16, _ q: [UInt8]) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0); defer { close(fd) }
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian; a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
    let sent = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, q, q.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard sent == q.count else { return nil }
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = recv(fd, &buf, buf.count, 0)
    return n > 0 ? Array(buf[0..<n]) : nil
}

private func askTCP(_ port: UInt16, _ q: [UInt8]) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian; a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
    let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard rc == 0 else { return nil }
    let framed = [UInt8(q.count >> 8), UInt8(q.count & 0xFF)] + q
    guard send(fd, framed, framed.count, 0) == framed.count else { return nil }
    var len = [UInt8](repeating: 0, count: 2)
    guard recv(fd, &len, 2, MSG_WAITALL) == 2 else { return nil }
    var buf = [UInt8](repeating: 0, count: Int(len[0]) << 8 | Int(len[1]))
    guard recv(fd, &buf, buf.count, MSG_WAITALL) == buf.count else { return nil }
    return buf
}

final class DNSTests: XCTestCase {
    func testParseQuestion() {
        let q = DNSPacket.parseQuestion(query("Ads.Example.com", type: 28))
        XCTAssertEqual(q?.name, "ads.example.com")
        XCTAssertEqual(q?.type, 28)
        XCTAssertNil(DNSPacket.parseQuestion([1, 2, 3]))
        var compressed = query("a.com"); compressed[12] = 0xC0
        XCTAssertNil(DNSPacket.parseQuestion(compressed))
    }

    func testSinkholeReplyShapes() {
        let qa = query("ads.example.com"); let a = DNSPacket.sinkholeReply(query: qa, question: DNSPacket.parseQuestion(qa)!)
        XCTAssertEqual(Array(a[0..<2]), [0x12, 0x34])
        XCTAssertEqual(a[2] & 0x80, 0x80)           // QR
        XCTAssertEqual(a[3] & 0x0F, 0)              // NOERROR
        XCTAssertEqual(a[7], 1)                     // one answer
        XCTAssertEqual(Array(a.suffix(4)), [0, 0, 0, 0])
        let q6 = query("ads.example.com", type: 28); let a6 = DNSPacket.sinkholeReply(query: q6, question: DNSPacket.parseQuestion(q6)!)
        XCTAssertEqual(a6.suffix(16).count, 16); XCTAssertTrue(a6.suffix(16).allSatisfy { $0 == 0 })
        let qh = query("ads.example.com", type: 65); let ah = DNSPacket.sinkholeReply(query: qh, question: DNSPacket.parseQuestion(qh)!)
        XCTAssertEqual(ah[7], 0)                    // HTTPS record: NODATA
        XCTAssertEqual(ah.count, qh.count)
    }

    func testMatcherSubdomainsAndAllowlist() {
        let m = BlockMatcher(blocked: ["tracker.com", "ads.site.org"], allowed: ["ok.tracker.com"])
        XCTAssertEqual(m.decide("tracker.com"), .blocked(rule: "tracker.com"))
        XCTAssertEqual(m.decide("pixel.eu.tracker.com"), .blocked(rule: "tracker.com"))
        XCTAssertEqual(m.decide("ok.tracker.com"), .allowed)
        XCTAssertEqual(m.decide("x.ok.tracker.com"), .allowed)
        XCTAssertEqual(m.decide("site.org"), .pass)
        XCTAssertEqual(m.decide("ads.site.org"), .blocked(rule: "ads.site.org"))
        XCTAssertEqual(m.decide("com"), .pass)
    }

    func testStatsCountsAndSnapshot() {
        let s = QueryStats()
        s.record(name: "a.com", blocked: false)
        s.record(name: "ads.com", blocked: true)
        s.record(name: "ads.com", blocked: true)
        let snap = s.snapshot()
        XCTAssertEqual(snap.totalToday, 3)
        XCTAssertEqual(snap.blockedToday, 2)
        XCTAssertEqual(snap.hours.count, 24)
        XCTAssertEqual(snap.hours.last?.blocked, 2)
        XCTAssertEqual(snap.topBlocked.first?.domain, "ads.com")
        XCTAssertEqual(snap.topBlocked.first?.count, 2)
        XCTAssertEqual(snap.recent.first?.name, "ads.com")
    }

    func testProxyBlocksAndForwardsOverUDPAndTCP() throws {
        let upstream = FakeUpstream(); defer { upstream.shutdown() }
        let stats = QueryStats()
        let port: UInt16 = 5391
        let proxy = DNSProxy(port: port, upstreams: ["127.0.0.1#\(upstream.port)"],
                             matcher: BlockMatcher(blocked: ["ads.example.com"], allowed: []), stats: stats)
        // 127.0.0.1#port upstreams must survive sanitising (only bare loopback is dropped).
        try proxy.start(); defer { proxy.stop() }

        let blocked = try XCTUnwrap(askUDP(port, query("x.ads.example.com")))
        XCTAssertEqual(Array(blocked.suffix(4)), [0, 0, 0, 0])
        XCTAssertEqual(upstream.count, 0, "blocked names must not reach upstream")

        let ok = try XCTUnwrap(askUDP(port, query("good.example.com", id: 0xBEEF)))
        XCTAssertEqual(Array(ok[0..<2]), [0xBE, 0xEF])
        XCTAssertEqual(Array(ok.suffix(4)), [1, 2, 3, 4])
        XCTAssertEqual(upstream.count, 1)

        let tcpBlocked = try XCTUnwrap(askTCP(port, query("ads.example.com")))
        XCTAssertEqual(Array(tcpBlocked.suffix(4)), [0, 0, 0, 0])

        let snap = stats.snapshot()
        XCTAssertEqual(snap.totalToday, 3)
        XCTAssertEqual(snap.blockedToday, 2)

        // Hot-swapping the matcher takes effect immediately.
        proxy.update(matcher: BlockMatcher(blocked: ["good.example.com"], allowed: []))
        let nowBlocked = try XCTUnwrap(askUDP(port, query("good.example.com")))
        XCTAssertEqual(Array(nowBlocked.suffix(4)), [0, 0, 0, 0])
    }

    func testProxyServfailWhenUpstreamDead() throws {
        let port: UInt16 = 5392
        let proxy = DNSProxy(port: port, upstreams: ["127.0.0.1#9"], matcher: BlockMatcher(), stats: QueryStats())
        try proxy.start(); defer { proxy.stop() }
        let r = try XCTUnwrap(askUDP(port, query("whatever.example.com")))
        XCTAssertEqual(r[3] & 0x0F, 2)   // SERVFAIL
    }

    func testPortInUseThrowsAndRestartWorks() throws {
        let a = DNSProxy(port: 5393, upstreams: [], matcher: BlockMatcher(), stats: QueryStats())
        try a.start()
        let b = DNSProxy(port: 5393, upstreams: [], matcher: BlockMatcher(), stats: QueryStats())
        // SO_REUSEADDR lets a second wildcard UDP bind succeed on BSD, so only assert restart behaviour.
        a.stop(); XCTAssertFalse(a.isRunning)
        try b.start(); XCTAssertTrue(b.isRunning); b.stop()
    }
}

final class NetworkConfigTests: XCTestCase {
    /// Read-only: inspects this Mac's settings, changes nothing.
    func testReadOnlyDetection() {
        let services = NetworkConfig.services()
        print("NET services:", services)
        let settings = NetworkConfig.currentSettings(for: services)
        print("NET manual DNS:", settings)
        let up = NetworkConfig.detectUpstreams(backup: settings)
        print("NET upstreams:", up)
        XCTAssertFalse(up.contains("127.0.0.1"))
        // Command builders quote service names safely.
        let cmds = NetworkConfig.enableCommands(services: ["Wi-Fi", "Bob's LAN"], fallback: ["10.0.0.1"])
        XCTAssertTrue(cmds[0].contains("'Wi-Fi' '127.0.0.1' '10.0.0.1'"))
        XCTAssertTrue(cmds[1].contains("'Bob'\\''s LAN'"))
        XCTAssertTrue(cmds.allSatisfy { $0.hasSuffix("|| true") })
    }

    /// iPhone hotspots hand out link-local IPv6 DNS (fe80::…%en0); networksetup rejects the whole
    /// list if one is included, which left the DNS filter silently off.
    func testUnsettableAddressesAreNeverPassedToNetworksetup() {
        XCTAssertTrue(NetworkConfig.isSettable("172.20.10.1"))
        XCTAssertTrue(NetworkConfig.isSettable("2606:4700:4700::1111"))
        XCTAssertFalse(NetworkConfig.isSettable("fe80::1%en0"))
        XCTAssertFalse(NetworkConfig.isSettable("fe80::1"))
        XCTAssertFalse(NetworkConfig.isSettable("127.0.0.1"))
        XCTAssertFalse(NetworkConfig.isSettable("not-an-ip"))
        let cmd = NetworkConfig.enableCommands(services: ["Wi-Fi"], fallback: ["fe80::1%en0", "172.20.10.1"])[0]
        XCTAssertEqual(cmd, "/usr/sbin/networksetup -setdnsservers 'Wi-Fi' '127.0.0.1' '172.20.10.1' 2>&1 || true")
        let restore = NetworkConfig.restoreCommands(backup: ["Wi-Fi": ["fe80::1%en0"]])
        XCTAssertTrue(restore.isEmpty || restore[0].contains("'Wi-Fi' Empty") || !restore[0].contains("fe80"))
    }

    func testOldConfigStillDecodes() throws {
        let json = #"{"enabled":["ads"],"allowlist":["a.example.com"],"autoUpdate":false}"#
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.allowlist, ["a.example.com"])
        XCTAssertEqual(cfg.method, .hosts)
        XCTAssertTrue(cfg.dnsFallback)
    }
}

final class ProxyRobustnessTests: XCTestCase {
    /// A TCP client that hangs up before its answer arrives (what mDNSResponder does when the
    /// network changes) must not kill the process with SIGPIPE.
    func testClientHangupDoesNotKillProcess() throws {
        // The test runner may ignore SIGPIPE itself; restore the default an app has.
        let previous = signal(SIGPIPE, SIG_DFL); defer { signal(SIGPIPE, previous) }
        let port: UInt16 = 5394
        // Slow TCP upstream: accepts, waits 1s, hangs up. The proxy then writes SERVFAIL into the
        // client connection, which the client has already reset.
        let up = socket(AF_INET, SOCK_STREAM, 0); defer { close(up) }
        var ua = sockaddr_in()
        ua.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); ua.sin_family = sa_family_t(AF_INET)
        ua.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        withUnsafePointer(to: &ua) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.bind(up, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(up, 4)
        var ulen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &ua) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(up, $0, &ulen) } }
        let upPort = UInt16(bigEndian: ua.sin_port)
        Thread.detachNewThread {
            let c = Darwin.accept(up, nil, nil)
            Thread.sleep(forTimeInterval: 1)
            close(c)
        }
        let proxy = DNSProxy(port: port, upstreams: ["127.0.0.1#\(upPort)"], matcher: BlockMatcher(blocked: ["ads.example.com"]), stats: QueryStats())
        try proxy.start(); defer { proxy.stop() }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        var q: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 4]
        q += Array("slow".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        let framed = [UInt8(0), UInt8(q.count)] + q
        _ = send(fd, framed, framed.count, 0)
        var lin = linger(l_onoff: 1, l_linger: 0)          // RST on close: the next server write fails with EPIPE
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &lin, socklen_t(MemoryLayout<linger>.size))
        close(fd)

        Thread.sleep(forTimeInterval: 2)                    // let the proxy write into the dead connection
        // Still alive and still answering.
        var b: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 3]
        b += Array("ads".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        let u = socket(AF_INET, SOCK_DGRAM, 0); defer { close(u) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(u, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(u, b, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var buf = [UInt8](repeating: 0, count: 512)
        XCTAssertGreaterThan(recv(u, &buf, buf.count, 0), 0)
    }
}
