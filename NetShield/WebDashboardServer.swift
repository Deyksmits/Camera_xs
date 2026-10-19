import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Lightweight embedded HTTP Web Server running on port 8080.
/// Allows accessing a full Pi-hole style dark-mode dashboard from any browser on the local network (PC, Mac, tablet, phone).
public final class WebDashboardServer {
    public static let shared = WebDashboardServer()
    
    private var serverSocket: Int32 = -1
    private var isRunning: Bool = false
    private let queue = DispatchQueue(label: "com.netshield.webserver", qos: .userInitiated, attributes: .concurrent)
    public var port: UInt16 = 8080

    private init() {}

    public func start() {
        guard !isRunning else { return }
        
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("[WebDashboard] Failed to create socket")
            return
        }
        
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = port.bigEndian
        serverAddr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindResult = withUnsafePointer(to: &serverAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult == 0 else {
            print("[WebDashboard] Failed to bind to port \(port)")
            close(serverSocket)
            serverSocket = -1
            return
        }
        
        guard listen(serverSocket, 15) == 0 else {
            print("[WebDashboard] Failed to listen on socket")
            close(serverSocket)
            serverSocket = -1
            return
        }
        
        isRunning = true
        print("[WebDashboard] HTTP Server running at http://0.0.0.0:\(port)/")
        
        queue.async { [weak self] in
            self?.acceptConnections()
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        print("[WebDashboard] HTTP Server stopped")
    }

    private func acceptConnections() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }
            
            guard clientSocket >= 0 else {
                if !isRunning { break }
                continue
            }
            
            queue.async { [weak self] in
                self?.handleClient(clientSocket)
            }
        }
    }

    private func handleClient(_ clientSocket: Int32) {
        defer { close(clientSocket) }
        
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }
        
        let requestString = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let path = parts[1]
        
        route(method: method, path: path, requestBody: requestString, clientSocket: clientSocket)
    }

    private func route(method: String, path: String, requestBody: String, clientSocket: Int32) {
        let cleanPath = path.components(separatedBy: "?").first ?? path
        let queryString = path.contains("?") ? path.components(separatedBy: "?").last ?? "" : ""
        let queryParams = parseQueryParams(queryString)
        
        switch (method, cleanPath) {
        case ("GET", "/"):
            let html = renderDashboardHtml()
            sendResponse(clientSocket, status: "200 OK", contentType: "text/html; charset=utf-8", body: html)
            
        case ("GET", "/api/stats"):
            let stats = DNSEngine.shared.getStats()
            let total = stats.totalQueries
            let blocked = stats.blockedQueries
            let rate = total > 0 ? (Double(blocked) / Double(total) * 100.0) : 0.0
            
            let json: [String: Any] = [
                "total_queries": total,
                "blocked_queries": blocked,
                "cached_queries": stats.cachedQueries,
                "forwarded_queries": stats.forwardedQueries,
                "block_rate": String(format: "%.1f%%", rate),
                "active_rules": BlocklistManager.shared.blockCount,
                "whitelist_count": BlocklistManager.shared.whitelistCount,
                "upstream": DNSEngine.shared.primaryUpstream,
                "is_active": DNSEngine.shared.isServerActive,
                "aggressive_mode": BlocklistManager.shared.isAggressiveMode
            ]
            sendJsonResponse(clientSocket, json: json)
            
        case ("GET", "/api/queries"):
            let entries = DNSEngine.shared.getRecentLogs(limit: 100)
            let logsArray: [[String: Any]] = entries.map { entry in
                return [
                    "timestamp": entry.formattedTime,
                    "domain": entry.domain,
                    "client": entry.clientIP,
                    "type": entry.queryType,
                    "status": entry.status.rawValue,
                    "response": entry.responseSummary
                ]
            }
            sendJsonResponse(clientSocket, json: ["queries": logsArray])
            
        case ("POST", "/api/action/blacklist"):
            if let domain = queryParams["domain"], !domain.isEmpty {
                BlocklistManager.shared.addToBlacklist(domain)
                DNSEngine.shared.clearCache()
                sendJsonResponse(clientSocket, json: ["success": true, "message": "Domain '\(domain)' added to blacklist"])
            } else {
                sendJsonResponse(clientSocket, json: ["success": false, "message": "Missing domain parameter"])
            }
            
        case ("POST", "/api/action/whitelist"):
            if let domain = queryParams["domain"], !domain.isEmpty {
                BlocklistManager.shared.addToWhitelist(domain)
                DNSEngine.shared.clearCache()
                sendJsonResponse(clientSocket, json: ["success": true, "message": "Domain '\(domain)' added to whitelist"])
            } else {
                sendJsonResponse(clientSocket, json: ["success": false, "message": "Missing domain parameter"])
            }
            
        case ("POST", "/api/action/toggle-aggressive"):
            BlocklistManager.shared.isAggressiveMode.toggle()
            DNSEngine.shared.clearCache()
            sendJsonResponse(clientSocket, json: ["success": true, "aggressive_mode": BlocklistManager.shared.isAggressiveMode])

        case ("POST", "/api/action/clear-cache"):
            DNSEngine.shared.clearCache()
            sendJsonResponse(clientSocket, json: ["success": true, "message": "DNS cache cleared"])
            
        case ("POST", "/api/action/update-blocklists"):
            BlocklistManager.shared.downloadOnlineBlocklists { success, count in
                // Finished asynchronously
            }
            sendJsonResponse(clientSocket, json: ["success": true, "message": "Multi-source blocklist update initiated"])
            
        case ("POST", "/api/action/toggle-server"):
            if DNSEngine.shared.isServerActive {
                DNSEngine.shared.stop()
            } else {
                DNSEngine.shared.start()
            }
            sendJsonResponse(clientSocket, json: ["success": true, "is_active": DNSEngine.shared.isServerActive])
            
        case ("GET", "/api/blocklist"):
            let json: [String: Any] = [
                "custom_blacklist": Array(BlocklistManager.shared.customBlacklist),
                "custom_whitelist": Array(BlocklistManager.shared.customWhitelist),
                "rules_count": BlocklistManager.shared.blockCount
            ]
            sendJsonResponse(clientSocket, json: json)
            
        default:
            sendResponse(clientSocket, status: "404 Not Found", contentType: "text/plain", body: "404 Not Found")
        }
    }

    private func parseQueryParams(_ queryString: String) -> [String: String] {
        var params: [String: String] = [:]
        for pair in queryString.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let val = kv[1].removingPercentEncoding ?? kv[1]
                params[key] = val
            }
        }
        return params
    }

    private func sendJsonResponse(_ clientSocket: Int32, json: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
           let string = String(data: data, encoding: .utf8) {
            sendResponse(clientSocket, status: "200 OK", contentType: "application/json", body: string)
        } else {
            sendResponse(clientSocket, status: "500 Internal Error", contentType: "text/plain", body: "JSON error")
        }
    }

    private func sendResponse(_ clientSocket: Int32, status: String, contentType: String, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n"
        header += "Access-Control-Allow-Origin: *\r\n\r\n"
        
        let headerData = header.data(using: .utf8) ?? Data()
        headerData.withUnsafeBytes { ptr in
            _ = send(clientSocket, ptr.baseAddress, headerData.count, 0)
        }
        bodyData.withUnsafeBytes { ptr in
            _ = send(clientSocket, ptr.baseAddress, bodyData.count, 0)
        }
    }

    private func renderDashboardHtml() -> String {
        return """
        <!DOCTYPE html>
        <html lang="nl">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>NetShield Pro - Advanced DNS AdBlocker</title>
            <style>
                :root {
                    --bg-dark: #0f172a;
                    --card-bg: #1e293b;
                    --card-border: #334155;
                    --text-main: #f8fafc;
                    --text-muted: #94a3b8;
                    --accent-cyan: #06b6d4;
                    --accent-red: #ef4444;
                    --accent-green: #10b981;
                    --accent-blue: #3b82f6;
                    --accent-purple: #a855f7;
                    --font: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                }
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    background-color: var(--bg-dark);
                    color: var(--text-main);
                    font-family: var(--font);
                    line-height: 1.5;
                    padding: 24px;
                }
                .container { max-width: 1200px; margin: 0 auto; }
                header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    padding-bottom: 24px;
                    border-bottom: 1px solid var(--card-border);
                    margin-bottom: 24px;
                    flex-wrap: wrap;
                    gap: 16px;
                }
                .logo-area { display: flex; align-items: center; gap: 14px; }
                .shield-badge {
                    background: linear-gradient(135deg, #06b6d4, #3b82f6);
                    width: 44px;
                    height: 44px;
                    border-radius: 12px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-weight: 800;
                    font-size: 22px;
                    box-shadow: 0 4px 14px rgba(6, 182, 212, 0.4);
                }
                .header-title h1 { font-size: 24px; font-weight: 700; letter-spacing: -0.5px; }
                .header-title p { font-size: 13px; color: var(--text-muted); }
                .header-badges { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
                .status-badge {
                    display: inline-flex;
                    align-items: center;
                    gap: 8px;
                    background: rgba(16, 185, 129, 0.15);
                    border: 1px solid var(--accent-green);
                    color: var(--accent-green);
                    padding: 8px 16px;
                    border-radius: 999px;
                    font-size: 13px;
                    font-weight: 600;
                }
                .status-dot {
                    width: 10px;
                    height: 10px;
                    border-radius: 50%;
                    background-color: var(--accent-green);
                    animation: pulse 2s infinite;
                }
                @keyframes pulse {
                    0% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
                    70% { box-shadow: 0 0 0 10px rgba(16, 185, 129, 0); }
                    100% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
                }
                .metrics-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
                    gap: 20px;
                    margin-bottom: 28px;
                }
                .metric-card {
                    background-color: var(--card-bg);
                    border: 1px solid var(--card-border);
                    border-radius: 16px;
                    padding: 20px;
                    box-shadow: 0 4px 12px rgba(0,0,0,0.2);
                    display: flex;
                    flex-direction: column;
                    justify-content: space-between;
                }
                .metric-title { font-size: 13px; color: var(--text-muted); text-transform: uppercase; font-weight: 600; letter-spacing: 0.5px; }
                .metric-value { font-size: 32px; font-weight: 800; margin: 10px 0 4px 0; }
                .metric-value.cyan { color: var(--accent-cyan); }
                .metric-value.red { color: var(--accent-red); }
                .metric-value.green { color: var(--accent-green); }
                .metric-value.blue { color: var(--accent-blue); }
                .metric-sub { font-size: 12px; color: var(--text-muted); }

                .action-bar {
                    display: flex;
                    gap: 12px;
                    margin-bottom: 28px;
                    flex-wrap: wrap;
                    align-items: center;
                }
                button {
                    background-color: var(--card-bg);
                    border: 1px solid var(--card-border);
                    color: var(--text-main);
                    padding: 10px 18px;
                    border-radius: 10px;
                    font-size: 14px;
                    font-weight: 600;
                    cursor: pointer;
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    transition: all 0.2s;
                }
                button:hover {
                    background-color: #334155;
                    border-color: var(--accent-cyan);
                    color: #fff;
                }
                .btn-sm {
                    padding: 4px 8px;
                    font-size: 11px;
                    border-radius: 6px;
                    background: #2d3748;
                    border: 1px solid #4a5568;
                }
                .btn-sm.danger { color: #f87171; }
                .btn-sm.danger:hover { background: #ef4444; color: #fff; border-color: #ef4444; }

                .section-card {
                    background-color: var(--card-bg);
                    border: 1px solid var(--card-border);
                    border-radius: 16px;
                    padding: 24px;
                    margin-bottom: 28px;
                }
                .section-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    margin-bottom: 18px;
                }
                .section-header h2 { font-size: 18px; font-weight: 700; }
                .table-wrapper {
                    overflow-x: auto;
                    border-radius: 8px;
                }
                table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 14px;
                }
                th {
                    background-color: #162032;
                    text-align: left;
                    padding: 12px 16px;
                    color: var(--text-muted);
                    font-weight: 600;
                    border-bottom: 1px solid var(--card-border);
                }
                td {
                    padding: 12px 16px;
                    border-bottom: 1px solid #243248;
                    color: #cbd5e1;
                }
                tr:hover td { background-color: rgba(255,255,255,0.02); }
                .badge {
                    display: inline-block;
                    padding: 4px 10px;
                    border-radius: 6px;
                    font-size: 11px;
                    font-weight: 700;
                }
                .badge-blocked { background: rgba(239, 68, 68, 0.2); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.4); }
                .badge-cloaked { background: rgba(168, 85, 247, 0.2); color: #c084fc; border: 1px solid rgba(168, 85, 247, 0.4); }
                .badge-forwarded { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.4); }
                .badge-cached { background: rgba(6, 182, 212, 0.2); color: #22d3ee; border: 1px solid rgba(6, 182, 212, 0.4); }
                .code-pill {
                    font-family: monospace;
                    background: #0f172a;
                    padding: 2px 6px;
                    border-radius: 4px;
                    font-size: 12px;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <header>
                    <div class="logo-area">
                        <div class="shield-badge">🛡️</div>
                        <div class="header-title">
                            <h1>NetShield Pro DNS</h1>
                            <p>TrollStore Port 53 Daemon &bull; CNAME Cloaking & Heuristic Shield</p>
                        </div>
                    </div>
                    <div class="header-badges">
                        <div class="status-badge" id="serverStatusBadge">
                            <span class="status-dot"></span>
                            <span id="serverStatusText">ACTIEF (0.0.0.0:53)</span>
                        </div>
                    </div>
                </header>

                <div class="metrics-grid">
                    <div class="metric-card">
                        <span class="metric-title">Totaal Queries</span>
                        <div class="metric-value cyan" id="totalQueries">0</div>
                        <span class="metric-sub">Sinds opstarten server</span>
                    </div>
                    <div class="metric-card">
                        <span class="metric-title">Geblokkeerde Advertenties</span>
                        <div class="metric-value red" id="blockedQueries">0</div>
                        <span class="metric-sub">Ad/Tracker/Cloaked gestopt</span>
                    </div>
                    <div class="metric-card">
                        <span class="metric-title">Blokkeer Percentage</span>
                        <div class="metric-value green" id="blockRate">0.0%</div>
                        <span class="metric-sub">Bespaarde data & laadtijd</span>
                    </div>
                    <div class="metric-card">
                        <span class="metric-title">Actieve Regels</span>
                        <div class="metric-value blue" id="activeRules">0</div>
                        <span class="metric-sub">Domeinen in filter database</span>
                    </div>
                </div>

                <div class="action-bar">
                    <button onclick="clearCache()">🧹 DNS Cache Legen</button>
                    <button onclick="updateBlocklists()">🔄 Filterlijsten Updaten (Multi-Source)</button>
                    <button onclick="toggleAggressive()" id="btnAggressive">⚡ Agressieve Heuristiek: AAN</button>
                    <button onclick="refreshData()">⚡ Nu Verversen</button>
                </div>

                <div class="section-card">
                    <div class="section-header">
                        <h2>Live DNS Verzoeken met 1-Klik Snelle Blokkade</h2>
                        <span style="font-size: 13px; color: var(--text-muted);" id="lastUpdated">Auto-refresh elke 2s</span>
                    </div>
                    <div class="table-wrapper">
                        <table>
                            <thead>
                                <tr>
                                    <th>Tijd</th>
                                    <th>Client IP</th>
                                    <th>Opgevraagd Domein</th>
                                    <th>Type</th>
                                    <th>Status</th>
                                    <th>Antwoord</th>
                                    <th>Directe Actie</th>
                                </tr>
                            </thead>
                            <tbody id="queryTableBody">
                                <tr>
                                    <td colspan="7" style="text-align: center; padding: 24px; color: var(--text-muted);">
                                        Nog geen verzoeken ontvangen. Stel het DNS IP van deze iPhone in op je apparaat of router.
                                    </td>
                                </tr>
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>

            <script>
                async function fetchStats() {
                    try {
                        const res = await fetch('/api/stats');
                        const data = await res.json();
                        document.getElementById('totalQueries').textContent = data.total_queries.toLocaleString();
                        document.getElementById('blockedQueries').textContent = data.blocked_queries.toLocaleString();
                        document.getElementById('blockRate').textContent = data.block_rate;
                        document.getElementById('activeRules').textContent = data.active_rules.toLocaleString();
                        
                        const btnAgg = document.getElementById('btnAggressive');
                        btnAgg.textContent = data.aggressive_mode ? '⚡ Agressieve Heuristiek: AAN' : '⚡ Agressieve Heuristiek: UIT';
                        btnAgg.style.borderColor = data.aggressive_mode ? 'var(--accent-cyan)' : 'var(--card-border)';
                    } catch (e) {
                        console.error('Stats error:', e);
                    }
                }

                async function fetchQueries() {
                    try {
                        const res = await fetch('/api/queries');
                        const data = await res.json();
                        const tbody = document.getElementById('queryTableBody');
                        
                        if (data.queries && data.queries.length > 0) {
                            let rows = '';
                            data.queries.forEach(q => {
                                let badgeClass = 'badge-forwarded';
                                if (q.status === 'BLOCKED') badgeClass = 'badge-blocked';
                                else if (q.status === 'CLOAKED') badgeClass = 'badge-cloaked';
                                else if (q.status === 'CACHED') badgeClass = 'badge-cached';
                                
                                const actionBtn = q.status !== 'BLOCKED' ? 
                                    `<button class="btn-sm danger" onclick="quickBlacklist('${q.domain}')">🚫 Blokkeer</button>` : 
                                    `<span style="color:var(--text-muted);font-size:11px;">Reeds geblokkeerd</span>`;

                                rows += `<tr>
                                    <td>${q.timestamp}</td>
                                    <td><span class="code-pill">${q.client}</span></td>
                                    <td><strong>${q.domain}</strong></td>
                                    <td><span class="code-pill">${q.type}</span></td>
                                    <td><span class="badge ${badgeClass}">${q.status}</span></td>
                                    <td>${q.response}</td>
                                    <td>${actionBtn}</td>
                                </tr>`;
                            });
                            tbody.innerHTML = rows;
                        }
                        document.getElementById('lastUpdated').textContent = 'Laatst ververst: ' + new Date().toLocaleTimeString();
                    } catch (e) {
                        console.error('Queries error:', e);
                    }
                }

                async function quickBlacklist(domain) {
                    if (confirm(`Wil je '${domain}' per direct toevoegen aan de permanente blacklist?`)) {
                        await fetch('/api/action/blacklist?domain=' + encodeURIComponent(domain), { method: 'POST' });
                        alert(`'${domain}' is direct geblokkeerd!`);
                        refreshData();
                    }
                }

                async function toggleAggressive() {
                    await fetch('/api/action/toggle-aggressive', { method: 'POST' });
                    refreshData();
                }

                async function clearCache() {
                    if (confirm('Wil je het lokale DNS geheugen legen?')) {
                        await fetch('/api/action/clear-cache', { method: 'POST' });
                        alert('DNS cache succesvol geleegd!');
                        refreshData();
                    }
                }

                async function updateBlocklists() {
                    await fetch('/api/action/update-blocklists', { method: 'POST' });
                    alert('Multi-source download gestart (StevenBlack + AdGuard + OISD)!');
                }

                function refreshData() {
                    fetchStats();
                    fetchQueries();
                }

                setInterval(refreshData, 2000);
                refreshData();
            </script>
        </body>
        </html>
        """
    }
}
