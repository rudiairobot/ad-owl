import Foundation
import Darwin

public enum ProxyError: LocalizedError {
    case bind(port: UInt16, reason: String)
    public var errorDescription: String? {
        switch self {
        case .bind(let port, let reason): "Couldn't listen for DNS on port \(port): \(reason)"
        }
    }
}

/// A local DNS resolver: names the matcher blocks get 0.0.0.0, everything else is forwarded upstream.
/// Binds the wildcard address (macOS lets unprivileged apps do that on port 53) but only answers
/// clients on this Mac, so it never acts as an open resolver on the LAN.
public final class DNSProxy: @unchecked Sendable {
    public let port: UInt16
    private let stats: QueryStats
    private let lock = NSLock()
    private var matcher: BlockMatcher
    private var upstreams: [String]
    private var udpFD: Int32 = -1
    private var tcpFD: Int32 = -1
    private var running = false
    private let work = DispatchQueue(label: "hostshield.dns.work", attributes: .concurrent)
    private let inflight = DispatchSemaphore(value: 128)
    private let loops = DispatchGroup()

    public init(port: UInt16 = 53, upstreams: [String], matcher: BlockMatcher, stats: QueryStats) {
        self.port = port
        self.upstreams = Self.sanitize(upstreams, ownPort: port)
        self.matcher = matcher
        self.stats = stats
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func update(matcher: BlockMatcher) { lock.lock(); self.matcher = matcher; lock.unlock() }
    public func update(upstreams: [String]) {
        let clean = Self.sanitize(upstreams, ownPort: port)
        guard !clean.isEmpty else { return }
        lock.lock(); self.upstreams = clean; lock.unlock()
    }

    static func sanitize(_ list: [String], ownPort: UInt16) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in list where !["127.0.0.1", "::1", "0.0.0.0", ""].contains(s) && s != "127.0.0.1#\(ownPort)" && seen.insert(s).inserted { out.append(s) }
        return out.isEmpty ? ["1.1.1.1", "9.9.9.9"] : out
    }

    // MARK: Lifecycle

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)   // belt and braces for any socket that misses SO_NOSIGPIPE
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        let u = try Self.makeSocket(type: SOCK_DGRAM, port: port)
        let t: Int32
        do { t = try Self.makeSocket(type: SOCK_STREAM, port: port) } catch { close(u); throw error }
        udpFD = u; tcpFD = t; running = true
        loops.enter(); loops.enter()
        Thread.detachNewThread { [self] in udpLoop(u); loops.leave() }
        Thread.detachNewThread { [self] in tcpLoop(t); loops.leave() }
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let (u, t) = (udpFD, tcpFD)
        udpFD = -1; tcpFD = -1
        lock.unlock()
        // Loops notice `running == false` within one poll interval; wait for them before closing.
        _ = loops.wait(timeout: .now() + 2)
        close(u); close(t)
    }

    private static func makeSocket(type: Int32, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw ProxyError.bind(port: port, reason: String(cString: strerror(errno))) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let reason = errno == EADDRINUSE ? "another program is already using it" : String(cString: strerror(errno))
            close(fd)
            throw ProxyError.bind(port: port, reason: reason)
        }
        if type == SOCK_STREAM { listen(fd, 32) }
        return fd
    }

    private func snapshot() -> (BlockMatcher, [String]) {
        lock.lock(); defer { lock.unlock() }
        return (matcher, upstreams)
    }

    private static func isLoopback(_ a: sockaddr_in) -> Bool { UInt32(bigEndian: a.sin_addr.s_addr) >> 24 == 127 }

    private func waitReadable(_ fd: Int32) -> Bool? {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let n = poll(&p, 1, 500)
        if n < 0 { return errno == EINTR ? false : nil }
        return n > 0
    }

    // MARK: UDP

    private func udpLoop(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while isRunning {
            guard let ready = waitReadable(fd) else { break }
            guard ready else { continue }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0, Self.isLoopback(from) else { continue }
            guard inflight.wait(timeout: .now()) == .success else { continue }   // shed load
            let query = Array(buf[0..<n])
            let src = from
            work.async { [self] in
                defer { inflight.signal() }
                guard let reply = handle(query, tcp: false) else { return }
                var dst = src
                _ = reply.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dst) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, reply.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    // MARK: TCP

    private func tcpLoop(_ fd: Int32) {
        while isRunning {
            guard let ready = waitReadable(fd) else { break }
            guard ready else { continue }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            guard client >= 0 else { continue }
            guard Self.isLoopback(from), inflight.wait(timeout: .now()) == .success else { close(client); continue }
            work.async { [self] in
                defer { inflight.signal(); close(client) }
                Self.noSigPipe(client)
                Self.setTimeout(client, seconds: 5)
                while isRunning {
                    guard let lenBytes = Self.readExactly(client, 2) else { return }
                    let size = Int(lenBytes[0]) << 8 | Int(lenBytes[1])
                    guard size > 0, let query = Self.readExactly(client, size) else { return }
                    guard let reply = handle(query, tcp: true), reply.count <= 65535 else { return }
                    let framed = [UInt8(reply.count >> 8), UInt8(reply.count & 0xFF)] + reply
                    guard Self.writeAll(client, framed) else { return }
                }
            }
        }
    }

    // MARK: Query handling

    func handle(_ query: [UInt8], tcp: Bool) -> [UInt8]? {
        let (matcher, upstreams) = snapshot()
        if let q = DNSPacket.parseQuestion(query), q.cls == 1 {
            let decision = matcher.decide(q.name)
            if case .blocked = decision {
                stats.record(name: q.name, blocked: true)
                return DNSPacket.sinkholeReply(query: query, question: q)
            }
            stats.record(name: q.name, blocked: false)
        }
        return forward(query, tcp: tcp, upstreams: upstreams) ?? DNSPacket.servfail(query: query)
    }

    private func forward(_ query: [UInt8], tcp: Bool, upstreams: [String]) -> [UInt8]? {
        for host in upstreams {
            if let r = tcp ? Self.queryTCP(host, query) : Self.queryUDP(host, query) { return r }
        }
        return nil
    }

    // MARK: Socket helpers

    /// Upstream as `ip` or `ip#port`.
    private static func address(_ spec: String) -> (storage: sockaddr_storage, length: socklen_t, family: Int32)? {
        let parts = spec.split(separator: "#", maxSplits: 1).map(String.init)
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard let host = parts.first, getaddrinfo(host, parts.count > 1 ? parts[1] : "53", &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var ss = sockaddr_storage()
        memcpy(&ss, r.pointee.ai_addr, Int(r.pointee.ai_addrlen))
        return (ss, r.pointee.ai_addrlen, r.pointee.ai_family)
    }

    /// Writing to a connection the peer has reset raises SIGPIPE, which by default kills the
    /// whole app without a crash report. Every TCP socket opts out; writes then just fail with EPIPE.
    static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func connected(_ host: String, type: Int32, timeout: Int) -> Int32? {
        guard var a = address(host) else { return nil }
        let fd = socket(a.family, type, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        setTimeout(fd, seconds: timeout)
        let rc = withUnsafePointer(to: &a.storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, a.length) }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    private static func queryUDP(_ host: String, _ query: [UInt8]) -> [UInt8]? {
        guard let fd = connected(host, type: SOCK_DGRAM, timeout: 2) else { return nil }
        defer { close(fd) }
        guard send(fd, query, query.count, 0) == query.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 65535)
        let n = recv(fd, &buf, buf.count, 0)
        guard n >= 12, buf[0] == query[0], buf[1] == query[1] else { return nil }
        return Array(buf[0..<n])
    }

    private static func queryTCP(_ host: String, _ query: [UInt8]) -> [UInt8]? {
        guard let fd = connected(host, type: SOCK_STREAM, timeout: 3) else { return nil }
        defer { close(fd) }
        guard writeAll(fd, [UInt8(query.count >> 8), UInt8(query.count & 0xFF)] + query),
              let lenBytes = readExactly(fd, 2) else { return nil }
        return readExactly(fd, Int(lenBytes[0]) << 8 | Int(lenBytes[1]))
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n <= 0 { return nil }
            got += n
        }
        return out
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
