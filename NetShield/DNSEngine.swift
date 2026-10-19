import Foundation
import Darwin

// MARK: - DNS Query Record Model
struct DNSQueryRecord: Identifiable, Codable {
    let id: String
    let timestamp: Date
    let clientIP: String
    let domain: String
    let queryType: String
    let isBlocked: Bool
    let responseTimeMs: Double
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Upstream DNS Resolver Opties
enum UpstreamDNSProvider: String, CaseIterable, Codable {
    case cloudflare = "Cloudflare (1.1.1.1 - Snelste)"
    case quad9 = "Quad9 (9.9.9.9 - Privacy & Malware Block)"
    case google = "Google (8.8.8.8)"
    case adguard = "AdGuard DNS (94.140.14.14)"
    
    var primaryIP: String {
        switch self {
        case .cloudflare: return "1.1.1.1"
        case .quad9: return "9.9.9.9"
        case .google: return "8.8.8.8"
        case .adguard: return "94.140.14.14"
        }
    }
}

// MARK: - Core High-Performance DNS Engine (UDP Port 53 Daemon)
class DNSEngine {
    static let shared = DNSEngine()
    
    private var serverSocketFD: Int32 = -1
    private var isRunning = false
    private let workerQueue = DispatchQueue(label: "com.netshield.dns.worker", qos: .userInteractive, attributes: .concurrent)
    private var listeningSource: DispatchSourceRead?
    
    // Telemetrie & Statistieken
    private(set) var totalQueriesCount: Int = 0
    private(set) var blockedQueriesCount: Int = 0
    private(set) var forwardedQueriesCount: Int = 0
    
    private var recentQueryLog: [DNSQueryRecord] = []
    private let queryLogQueue = DispatchQueue(label: "com.netshield.querylog", attributes: .concurrent)
    private let maxLogItems = 600
    
    // DNS Cache (Domain + Type -> [UInt8] + Expiration)
    private var responseCache: [String: (data: [UInt8], expiresAt: Date)] = [:]
    private let cacheQueue = DispatchQueue(label: "com.netshield.dnscache", attributes: .concurrent)
    
    // Upstream DNS configuratie
    var selectedUpstream: UpstreamDNSProvider = .cloudflare
    
    // Callbacks voor UI Live Updates
    var onQueryLogged: ((DNSQueryRecord) -> Void)?
    var onStatsUpdated: (() -> Void)?
    
    var isServerActive: Bool {
        return isRunning && serverSocketFD >= 0
    }
    
    var blockedPercentage: Double {
        guard totalQueriesCount > 0 else { return 0.0 }
        return (Double(blockedQueriesCount) / Double(totalQueriesCount)) * 100.0
    }
    
    // MARK: - Server Starten op UDP Poort 53
    func startServer(port: UInt16 = 53) -> (success: Bool, message: String) {
        guard !isRunning else {
            return (true, "DNS Server draait al op poort \(port)")
        }
        
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return (false, "Kon UDP socket niet aanmaken (errno: \(errno))")
        }
        
        // Hergebruik poort toestaan (noodzakelijk bij snelle herstarts)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var serverAddr = sockaddr_in()
        serverAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = port.bigEndian
        serverAddr.sin_addr.s_addr = in_addr_t(0).bigEndian // 0.0.0.0 (luister op alle netwerkinterfaces)
        
        let bindResult = withUnsafePointer(to: &serverAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult == 0 else {
            close(fd)
            let errStr = String(cString: strerror(errno))
            return (false, "Poort \(port) binden mislukt: \(errStr). Zorg dat de app met TrollStore draait.")
        }
        
        serverSocketFD = fd
        isRunning = true
        
        // Dispatch Source Read voor minimale CPU belasting en instant reactivity
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: workerQueue)
        source.setEventHandler { [weak self] in
            self?.processIncomingPackets()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        listeningSource = source
        
        print("NetShield: ✅ DNS Server succesvol gestart op UDP poort \(port)")
        return (true, "DNS Server actief op 0.0.0.0:\(port)")
    }
    
    // MARK: - Server Stoppen
    func stopServer() {
        guard isRunning else { return }
        isRunning = false
        listeningSource?.cancel()
        listeningSource = nil
        serverSocketFD = -1
        print("NetShield: ⏹ DNS Server gestopt.")
    }
    
    // MARK: - Inkomende DNS Datagrammen Verwerken
    private func processIncomingPackets() {
        guard isRunning, serverSocketFD >= 0 else { return }
        
        var clientAddr = sockaddr_storage()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var buffer = [UInt8](repeating: 0, count: 2048)
        
        let bytesRead = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                recvfrom(serverSocketFD, &buffer, buffer.count, 0, saPtr, &clientAddrLen)
            }
        }
        
        guard bytesRead >= 12 else { return } // Een valide DNS header is minimaal 12 bytes
        let packetData = Array(buffer[0..<bytesRead])
        
        // Bepaal IP adres van het vragende apparaat (bv. TV, laptop, iPhone)
        let clientIP = getIPString(from: clientAddr)
        
        // Verwerk de DNS query asynchroon om de socket nooit te blokkeren
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            self.handleDNSRequest(packetData: packetData,
                                  clientAddr: clientAddr,
                                  clientAddrLen: clientAddrLen,
                                  clientIP: clientIP)
        }
    }
    
    // MARK: - DNS Request Evaluatie (Adblock / Upstream Resolver)
    private func handleDNSRequest(packetData: [UInt8],
                                  clientAddr: sockaddr_storage,
                                  clientAddrLen: socklen_t,
                                  clientIP: String) {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // 1. Parseer het opgevraagde domeinnaam en query type uit het RFC-1035 pakket
        guard let parsed = parseDNSQuestion(packetData: packetData) else {
            return
        }
        
        let domain = parsed.domain
        let qType = parsed.qType
        let txID = parsed.transactionID
        
        // 2. Controleer of het domein op de Adblock Blacklist staat
        let isBlocked = BlocklistManager.shared.isDomainBlocked(domain)
        
        var responseData: [UInt8]?
        
        if isBlocked {
            // BLOKKEER DIRECT! Maak een lokale RFC-1035 '0.0.0.0' of 'NXDOMAIN' response
            responseData = createBlockedDNSResponse(queryPacket: packetData,
                                                   txID: txID,
                                                   domain: domain,
                                                   qType: qType)
            incrementBlockedCount()
        } else {
            // SCHOON DOMEIN: Controleer eerst de lokale snelle DNS cache
            let cacheKey = "\(domain)_\(qType)"
            if let cached = getCachedResponse(for: cacheKey) {
                // Pas Transaction ID aan naar de huidige query
                var modified = cached
                modified[0] = packetData[0]
                modified[1] = packetData[1]
                responseData = modified
            } else {
                // Vraag upstream DNS server (bv. Cloudflare 1.1.1.1)
                responseData = forwardToUpstreamDNS(queryPacket: packetData, upstreamIP: selectedUpstream.primaryIP)
                if let resp = responseData {
                    setCachedResponse(key: cacheKey, data: resp, ttlSeconds: 180)
                }
            }
            incrementForwardedCount()
        }
        
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        
        // 3. Stuur DNS antwoord terug naar de vragende client
        if let response = responseData {
            var mutableClient = clientAddr
            _ = withUnsafePointer(to: &mutableClient) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(serverSocketFD, response, response.count, 0, saPtr, clientAddrLen)
                }
            }
        }
        
        // 4. Logquery toevoegen voor live cockpit & webdashboard
        let record = DNSQueryRecord(id: UUID().uuidString,
                                    timestamp: Date(),
                                    clientIP: clientIP,
                                    domain: domain,
                                    queryType: getQueryTypeName(qType),
                                    isBlocked: isBlocked,
                                    responseTimeMs: elapsedMs)
        addQueryToLog(record)
    }
    
    // MARK: - RFC 1035 DNS Packet Parser
    private func parseDNSQuestion(packetData: [UInt8]) -> (domain: String, qType: UInt16, transactionID: UInt16)? {
        guard packetData.count >= 12 else { return nil }
        
        let txID = (UInt16(packetData[0]) << 8) | UInt16(packetData[1])
        let qdCount = (UInt16(packetData[4]) << 8) | UInt16(packetData[5])
        guard qdCount >= 1 else { return nil }
        
        var offset = 12
        var labels: [String] = []
        
        while offset < packetData.count {
            let len = Int(packetData[offset])
            if len == 0 {
                offset += 1
                break
            }
            // Pointer compressie controle (niet verwacht in de question section, maar veiligheid voorop)
            if (len & 0xC0) == 0xC0 {
                offset += 2
                break
            }
            offset += 1
            guard offset + len <= packetData.count else { return nil }
            let labelBytes = packetData[offset..<(offset + len)]
            if let labelStr = String(bytes: labelBytes, encoding: .utf8) {
                labels.append(labelStr)
            }
            offset += len
        }
        
        guard offset + 4 <= packetData.count else { return nil }
        let qType = (UInt16(packetData[offset]) << 8) | UInt16(packetData[offset + 1])
        let domain = labels.joined(separator: ".").lowercased()
        
        return (domain, qType, txID)
    }
    
    // MARK: - Geblokkeerde DNS Response Maken (0.0.0.0 / :: Null IP)
    private func createBlockedDNSResponse(queryPacket: [UInt8],
                                         txID: UInt16,
                                         domain: String,
                                         qType: UInt16) -> [UInt8] {
        var response = [UInt8]()
        response.reserveCapacity(512)
        
        // 1. Header (12 bytes)
        response.append(UInt8(txID >> 8))
        response.append(UInt8(txID & 0xFF))
        
        // Flags: QR=1 (Response), AA=1, RD=1, RA=1, RCODE=0 (No Error)
        response.append(0x81)
        response.append(0x80)
        
        // QDCOUNT = 1
        response.append(0x00); response.append(0x01)
        
        // ANCOUNT = 1 (1 geblokkeerd null-antwoord)
        response.append(0x00); response.append(0x01)
        
        // NSCOUNT = 0, ARCOUNT = 0
        response.append(0x00); response.append(0x00)
        response.append(0x00); response.append(0x00)
        
        // 2. Question sectie letterlijk kopiëren vanuit originele query
        // Zoek het einde van de question (nul-byte + 4 bytes voor QTYPE en QCLASS)
        var qEnd = 12
        while qEnd < queryPacket.count && queryPacket[qEnd] != 0 {
            qEnd += Int(queryPacket[qEnd]) + 1
        }
        qEnd += 1 + 4 // null-byte + QTYPE (2) + QCLASS (2)
        if qEnd <= queryPacket.count {
            response.append(contentsOf: queryPacket[12..<qEnd])
        }
        
        // 3. Answer Sectie (Pointer naar question: 0xC00C)
        response.append(0xC0); response.append(0x0C)
        
        if qType == 28 { // AAAA Record (IPv6)
            response.append(0x00); response.append(0x1C) // TYPE AAAA
            response.append(0x00); response.append(0x01) // CLASS IN
            response.append(contentsOf: [0x00, 0x00, 0x01, 0x2C]) // TTL = 300s
            response.append(0x00); response.append(0x10) // RDLENGTH = 16 bytes
            response.append(contentsOf: [UInt8](repeating: 0, count: 16)) // ::
        } else { // Standaard A Record (IPv4 0.0.0.0)
            response.append(0x00); response.append(0x01) // TYPE A
            response.append(0x00); response.append(0x01) // CLASS IN
            response.append(contentsOf: [0x00, 0x00, 0x01, 0x2C]) // TTL = 300s
            response.append(0x00); response.append(0x04) // RDLENGTH = 4 bytes
            response.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // 0.0.0.0
        }
        
        return response
    }
    
    // MARK: - Doorsturen naar Upstream DNS Resolver (Cloudflare / Quad9)
    private func forwardToUpstreamDNS(queryPacket: [UInt8], upstreamIP: String) -> [UInt8]? {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        
        var timeout = timeval(tv_sec: 1, tv_usec: 800000) // 1.8s timeout
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        var upstreamAddr = sockaddr_in()
        upstreamAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        upstreamAddr.sin_family = sa_family_t(AF_INET)
        upstreamAddr.sin_port = in_port_t(53).bigEndian
        inet_pton(AF_INET, upstreamIP, &upstreamAddr.sin_addr)
        
        let sent = withUnsafePointer(to: &upstreamAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                sendto(sock, queryPacket, queryPacket.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == queryPacket.count else { return nil }
        
        var replyBuffer = [UInt8](repeating: 0, count: 2048)
        let bytesRecv = recv(sock, &replyBuffer, replyBuffer.count, 0)
        guard bytesRecv > 12 else { return nil }
        
        return Array(replyBuffer[0..<bytesRecv])
    }
    
    // MARK: - DNS Response Cache
    private func getCachedResponse(for key: String) -> [UInt8]? {
        return cacheQueue.sync {
            guard let entry = responseCache[key] else { return nil }
            if Date() > entry.expiresAt {
                responseCache.removeValue(forKey: key)
                return nil
            }
            return entry.data
        }
    }
    
    private func setCachedResponse(key: String, data: [UInt8], ttlSeconds: TimeInterval) {
        cacheQueue.async(flags: .barrier) {
            let exp = Date().addingTimeInterval(ttlSeconds)
            self.responseCache[key] = (data: data, expiresAt: exp)
            if self.responseCache.count > 1500 {
                self.responseCache.removeAll()
            }
        }
    }
    
    func flushDNSCache() {
        cacheQueue.async(flags: .barrier) {
            self.responseCache.removeAll()
        }
    }
    
    // MARK: - Query Log & Statistieken Beheer
    private func addQueryToLog(_ record: DNSQueryRecord) {
        queryLogQueue.async(flags: .barrier) {
            self.recentQueryLog.insert(record, at: 0)
            if self.recentQueryLog.count > self.maxLogItems {
                self.recentQueryLog.removeLast()
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.onQueryLogged?(record)
            self?.onStatsUpdated?()
        }
    }
    
    func getRecentQueries(limit: Int = 100) -> [DNSQueryRecord] {
        return queryLogQueue.sync {
            Array(recentQueryLog.prefix(limit))
        }
    }
    
    func clearStats() {
        totalQueriesCount = 0
        blockedQueriesCount = 0
        forwardedQueriesCount = 0
        queryLogQueue.async(flags: .barrier) {
            self.recentQueryLog.removeAll()
        }
        onStatsUpdated?()
    }
    
    private func incrementBlockedCount() {
        totalQueriesCount += 1
        blockedQueriesCount += 1
    }
    
    private func incrementForwardedCount() {
        totalQueriesCount += 1
        forwardedQueriesCount += 1
    }
    
    private func getIPString(from addr: sockaddr_storage) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var mutableAddr = addr
        let len = socklen_t(addr.ss_len > 0 ? addr.ss_len : UInt8(MemoryLayout<sockaddr_storage>.size))
        
        let res = withUnsafePointer(to: &mutableAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getnameinfo(saPtr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return res == 0 ? String(cString: host) : "192.168.1.xxx"
    }
    
    private func getQueryTypeName(_ type: UInt16) -> String {
        switch type {
        case 1: return "A"
        case 28: return "AAAA"
        case 5: return "CNAME"
        case 12: return "PTR"
        case 15: return "MX"
        case 16: return "TXT"
        case 65: return "HTTPS"
        default: return "TYPE_\(type)"
        }
    }
}
