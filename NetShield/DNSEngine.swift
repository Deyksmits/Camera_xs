import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Models
public enum DNSQueryStatus: String {
    case blocked = "BLOCKED"
    case forwarded = "PASSED"
    case cached = "CACHED"
    case cloaked = "CLOAKED"
}

public struct DNSQueryLogEntry {
    public let id: String
    public let timestamp: Date
    public let clientIP: String
    public let domain: String
    public let queryType: String
    public let status: DNSQueryStatus
    public let responseSummary: String

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

public struct DNSStats {
    public let totalQueries: Int
    public let blockedQueries: Int
    public let cachedQueries: Int
    public let forwardedQueries: Int
}

// MARK: - Core DNS Engine
public final class DNSEngine {
    public static let shared = DNSEngine()

    private var serverSocket: Int32 = -1
    public private(set) var isServerActive: Bool = false
    public var primaryUpstream: String = "1.1.1.1" // Cloudflare default
    public var secondaryUpstream: String = "9.9.9.9" // Quad9 default

    private let workerQueue = DispatchQueue(label: "com.netshield.dns.engine", qos: .userInteractive, attributes: .concurrent)
    private let logQueue = DispatchQueue(label: "com.netshield.dns.logs", attributes: .concurrent)
    private let cacheQueue = DispatchQueue(label: "com.netshield.dns.cache", attributes: .concurrent)

    private var totalQueries: Int = 0
    private var blockedQueries: Int = 0
    private var cachedQueries: Int = 0
    private var forwardedQueries: Int = 0

    private var logs: [DNSQueryLogEntry] = []
    private let maxLogs = 200

    // Cache: Domain -> (Data, Expiry)
    private var cache: [String: (data: Data, expiresAt: Date)] = [:]

    private init() {}

    // MARK: - Start / Stop
    public func start() {
        guard !isServerActive else { return }

        serverSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard serverSocket >= 0 else {
            print("[DNSEngine] Error creating UDP socket (errno: \(errno))")
            return
        }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = in_port_t(53).bigEndian
        serverAddr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &serverAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(serverSocket, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            print("[DNSEngine] Failed to bind UDP port 53 (errno: \(errno))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        isServerActive = true
        print("[DNSEngine] DNS Engine listening on 0.0.0.0:53 (UDP)")

        workerQueue.async { [weak self] in
            self?.listenLoop()
        }
    }

    public func stop() {
        guard isServerActive else { return }
        isServerActive = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        print("[DNSEngine] DNS Engine stopped")
    }

    // MARK: - Server Loop
    private func listenLoop() {
        while isServerActive && serverSocket >= 0 {
            var clientAddr = sockaddr_storage()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buffer = [UInt8](repeating: 0, count: 2048)

            let bytesRead = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    recvfrom(serverSocket, &buffer, buffer.count, 0, saPtr, &clientAddrLen)
                }
            }

            guard bytesRead >= 12 else {
                if !isServerActive { break }
                continue
            }

            let queryData = Data(buffer.prefix(bytesRead))
            let clientIP = formatClientIP(clientAddr)

            workerQueue.async { [weak self] in
                self?.handleQuery(data: queryData, clientIP: clientIP, clientAddr: clientAddr, clientAddrLen: clientAddrLen)
            }
        }
    }

    // MARK: - Handle DNS Request
    private func handleQuery(data: Data, clientIP: String, clientAddr: sockaddr_storage, clientAddrLen: socklen_t) {
        guard let parsed = parseDNSHeaderAndQuestion(data: data) else { return }

        let domain = parsed.domain
        let qType = parsed.qType
        let txID = parsed.transactionID

        logQueue.async(flags: .barrier) {
            self.totalQueries += 1
        }

        // 1. Apple Private Relay / DoH Canary Check: Return NXDOMAIN
        // If iPhone/Mac queries mask.icloud.com or use-application-dns.net, an NXDOMAIN tells the OS
        // to disable Private Relay / DoH and route DNS cleanly through NetShield.
        if BlocklistManager.shared.isCanaryBypassDomain(domain) {
            logQueue.async(flags: .barrier) {
                self.blockedQueries += 1
            }
            let nxdomainResp = buildNXDomainResponse(for: data, txID: txID)
            sendResponse(nxdomainResp, to: clientAddr, len: clientAddrLen)
            appendLog(DNSQueryLogEntry(id: UUID().uuidString, timestamp: Date(), clientIP: clientIP, domain: domain, queryType: getTypeName(qType), status: .blocked, responseSummary: "NXDOMAIN (Anti-Bypass)"))
            return
        }

        // 2. Direct Blocklist & Heuristic check
        if BlocklistManager.shared.isDomainBlocked(domain) {
            logQueue.async(flags: .barrier) {
                self.blockedQueries += 1
            }
            let response = buildBlockedResponse(for: data, domain: domain, qType: qType, txID: txID)
            sendResponse(response, to: clientAddr, len: clientAddrLen)
            appendLog(DNSQueryLogEntry(id: UUID().uuidString, timestamp: Date(), clientIP: clientIP, domain: domain, queryType: getTypeName(qType), status: .blocked, responseSummary: "0.0.0.0 (AdBlock)"))
            return
        }

        // 3. Check Cache
        let cacheKey = "\(domain)_\(qType)"
        if let cached = checkCache(key: cacheKey, txID: txID) {
            logQueue.async(flags: .barrier) {
                self.cachedQueries += 1
            }
            sendResponse(cached, to: clientAddr, len: clientAddrLen)
            appendLog(DNSQueryLogEntry(id: UUID().uuidString, timestamp: Date(), clientIP: clientIP, domain: domain, queryType: getTypeName(qType), status: .cached, responseSummary: "Cache Hit"))
            return
        }

        // 4. Forward to Upstream
        if let upstreamResponse = forwardToUpstream(data: data, upstreamIP: primaryUpstream) {
            // 5. CNAME Cloaking Deep Inspection
            // If the upstream answer reveals that this domain is a CNAME pointing to a blocked tracker,
            // neutralize it immediately!
            if let cloakedTarget = detectCloakedTracker(in: upstreamResponse), BlocklistManager.shared.isDomainBlocked(cloakedTarget) {
                logQueue.async(flags: .barrier) {
                    self.blockedQueries += 1
                }
                let blockedResp = buildBlockedResponse(for: data, domain: domain, qType: qType, txID: txID)
                sendResponse(blockedResp, to: clientAddr, len: clientAddrLen)
                appendLog(DNSQueryLogEntry(id: UUID().uuidString, timestamp: Date(), clientIP: clientIP, domain: domain, queryType: getTypeName(qType), status: .cloaked, responseSummary: "Cloaked (\(cloakedTarget))"))
                return
            }

            logQueue.async(flags: .barrier) {
                self.forwardedQueries += 1
            }
            saveCache(key: cacheKey, data: upstreamResponse, ttl: 60)
            sendResponse(upstreamResponse, to: clientAddr, len: clientAddrLen)
            appendLog(DNSQueryLogEntry(id: UUID().uuidString, timestamp: Date(), clientIP: clientIP, domain: domain, queryType: getTypeName(qType), status: .forwarded, responseSummary: "Passed (Upstream)"))
        }
    }

    private func sendResponse(_ response: Data, to clientAddr: sockaddr_storage, len: socklen_t) {
        var mutableAddr = clientAddr
        response.withUnsafeBytes { ptr in
            _ = withUnsafePointer(to: &mutableAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(serverSocket, ptr.baseAddress, response.count, 0, saPtr, len)
                }
            }
        }
    }

    // MARK: - Forwarding
    private func forwardToUpstream(data: Data, upstreamIP: String) -> Data? {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var timeout = timeval(tv_sec: 1, tv_usec: 500000) // 1.5s
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(53).bigEndian
        inet_pton(AF_INET, upstreamIP, &remote.sin_addr)

        let sent = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &remote) { rPtr in
                rPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(sock, ptr.baseAddress, data.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 2048)
        let recvd = recv(sock, &buffer, buffer.count, 0)
        guard recvd > 0 else { return nil }
        return Data(buffer.prefix(recvd))
    }

    // MARK: - DNS Parsing & Response Building
    private func parseDNSHeaderAndQuestion(data: Data) -> (transactionID: UInt16, domain: String, qType: UInt16)? {
        guard data.count >= 12 else { return nil }
        let txID = (UInt16(data[0]) << 8) | UInt16(data[1])

        var offset = 12
        var labels: [String] = []

        while offset < data.count {
            let len = Int(data[offset])
            if len == 0 {
                offset += 1
                break
            }
            if (len & 0xC0) == 0xC0 {
                offset += 2
                break
            }
            offset += 1
            if offset + len > data.count { return nil }
            let labelData = data[offset..<(offset + len)]
            if let label = String(data: labelData, encoding: .utf8) {
                labels.append(label)
            }
            offset += len
        }

        guard offset + 4 <= data.count else { return nil }
        let qType = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        let domain = labels.joined(separator: ".").lowercased()
        return (txID, domain, qType)
    }

    /// Builds a RFC 1035 NXDOMAIN response (used to defeat Apple Private Relay / DoH canaries)
    private func buildNXDomainResponse(for query: Data, txID: UInt16) -> Data {
        var resp = Data()
        resp.append(UInt8(txID >> 8))
        resp.append(UInt8(txID & 0xFF))
        // Flags: 0x8183 -> Response, Recursion Desired, Recursion Available, RCODE: NXDOMAIN (3)
        resp.append(contentsOf: [0x81, 0x83])
        // QDCOUNT: 1, ANCOUNT: 0, NSCOUNT: 0, ARCOUNT: 0
        resp.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Append Question Section
        if query.count > 12 {
            var qEnd = 12
            while qEnd < query.count && query[qEnd] != 0 {
                qEnd += Int(query[qEnd]) + 1
            }
            qEnd += 5
            if qEnd <= query.count {
                resp.append(query[12..<qEnd])
            }
        }
        return resp
    }

    private func buildBlockedResponse(for query: Data, domain: String, qType: UInt16, txID: UInt16) -> Data {
        var resp = Data()
        resp.append(UInt8(txID >> 8))
        resp.append(UInt8(txID & 0xFF))
        // Flags: Standard response, No error, Authoritative
        resp.append(0x81)
        resp.append(0x80)
        // QDCOUNT: 1, ANCOUNT: 1
        resp.append(0x00)
        resp.append(0x01)
        resp.append(0x00)
        resp.append(0x01)
        // NSCOUNT & ARCOUNT: 0
        resp.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Question section from original query
        if query.count > 12 {
            var qEnd = 12
            while qEnd < query.count && query[qEnd] != 0 {
                qEnd += Int(query[qEnd]) + 1
            }
            qEnd += 5
            if qEnd <= query.count {
                resp.append(query[12..<qEnd])
            }
        }

        // Answer Section
        resp.append(contentsOf: [0xC0, 0x0C]) // Pointer to question name
        if qType == 28 { // AAAA
            resp.append(contentsOf: [0x00, 0x1C])
            resp.append(contentsOf: [0x00, 0x01])
            resp.append(contentsOf: [0x00, 0x00, 0x01, 0x2C]) // TTL: 300s
            resp.append(contentsOf: [0x00, 0x10])
            resp.append(Data(repeating: 0, count: 16)) // ::
        } else { // A
            resp.append(contentsOf: [0x00, 0x01])
            resp.append(contentsOf: [0x00, 0x01])
            resp.append(contentsOf: [0x00, 0x00, 0x01, 0x2C]) // TTL: 300s
            resp.append(contentsOf: [0x00, 0x04])
            resp.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // 0.0.0.0
        }

        return resp
    }

    // MARK: - CNAME Cloaking Detector
    private func detectCloakedTracker(in response: Data) -> String? {
        guard response.count > 12 else { return nil }
        let anCount = (Int(response[6]) << 8) | Int(response[7])
        guard anCount > 0 else { return nil }

        // Skip Header & Question Section
        var offset = 12
        while offset < response.count && response[offset] != 0 {
            offset += Int(response[offset]) + 1
        }
        offset += 5 // Null byte + QTYPE + QCLASS
        guard offset < response.count else { return nil }

        // Inspect Answer Records
        for _ in 0..<anCount {
            guard offset + 10 < response.count else { break }
            // Skip NAME
            if (response[offset] & 0xC0) == 0xC0 {
                offset += 2
            } else {
                while offset < response.count && response[offset] != 0 {
                    offset += Int(response[offset]) + 1
                }
                offset += 1
            }
            guard offset + 10 <= response.count else { break }
            let type = (UInt16(response[offset]) << 8) | UInt16(response[offset + 1])
            let rdLength = (Int(response[offset + 8]) << 8) | Int(response[offset + 9])
            offset += 10

            // If Type is CNAME (5)
            if type == 5 && offset + rdLength <= response.count {
                var cnameLabels: [String] = []
                var cOffset = offset
                while cOffset < offset + rdLength {
                    let len = Int(response[cOffset])
                    if len == 0 || (len & 0xC0) == 0xC0 { break }
                    cOffset += 1
                    if cOffset + len <= response.count {
                        if let str = String(data: response[cOffset..<(cOffset + len)], encoding: .utf8) {
                            cnameLabels.append(str)
                        }
                    }
                    cOffset += len
                }
                if !cnameLabels.isEmpty {
                    return cnameLabels.joined(separator: ".").lowercased()
                }
            }
            offset += rdLength
        }
        return nil
    }

    // MARK: - Cache
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }

    private func checkCache(key: String, txID: UInt16) -> Data? {
        return cacheQueue.sync {
            guard let entry = cache[key], entry.expiresAt > Date() else { return nil }
            var response = entry.data
            guard response.count >= 2 else { return nil }
            response[0] = UInt8(txID >> 8)
            response[1] = UInt8(txID & 0xFF)
            return response
        }
    }

    private func saveCache(key: String, data: Data, ttl: TimeInterval) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = (data, Date().addingTimeInterval(ttl))
        }
    }

    // MARK: - Telemetry & Logs
    public func getStats() -> DNSStats {
        return logQueue.sync {
            return DNSStats(
                totalQueries: totalQueries,
                blockedQueries: blockedQueries,
                cachedQueries: cachedQueries,
                forwardedQueries: forwardedQueries
            )
        }
    }

    public func getRecentLogs(limit: Int = 100) -> [DNSQueryLogEntry] {
        return logQueue.sync {
            return Array(logs.prefix(limit))
        }
    }

    private func appendLog(_ entry: DNSQueryLogEntry) {
        logQueue.async(flags: .barrier) {
            self.logs.insert(entry, at: 0)
            if self.logs.count > self.maxLogs {
                self.logs.removeLast()
            }
        }
    }

    // MARK: - Helpers
    public func getWifiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }

    private func formatClientIP(_ addr: sockaddr_storage) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var mutableAddr = addr
        let len = socklen_t(addr.ss_len > 0 ? addr.ss_len : UInt8(MemoryLayout<sockaddr_storage>.size))

        let res = withUnsafePointer(to: &mutableAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getnameinfo(saPtr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return res == 0 ? String(cString: host) : "192.168.1.x"
    }

    private func getTypeName(_ type: UInt16) -> String {
        switch type {
        case 1: return "A"
        case 28: return "AAAA"
        case 5: return "CNAME"
        case 12: return "PTR"
        case 15: return "MX"
        case 16: return "TXT"
        case 65: return "HTTPS"
        default: return "T_\(type)"
        }
    }
}
