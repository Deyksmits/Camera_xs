import Foundation
import Network
import UIKit

// MARK: - Embedded HomeSentry Web Dashboard Server (Poort 8082)
public final class WebDashboardServer {
    public static let shared = WebDashboardServer()
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.homesentry.webserver.queue")
    public var port: UInt16 = 8082
    
    public var accessKey: String = "1234"
    public var onGetSnapshot: (() -> Data?)?
    public var onGetStatus: (() -> [String: Any])?
    public var onSaveBox: (([[CGFloat]]) -> [CGPoint])?
    public var onToggleArm: (() -> Bool)?
    public var onToggleScreen: (() -> Bool)?
    public var onGetClips: (() -> [[String: Any]])?
    public var onGetVideoData: ((String) -> Data?)?
    
    private init() {}
    
    public func start() {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.prohibitedInterfaceTypes = []
            if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .any
            }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            listener = try NWListener(using: parameters, on: nwPort)
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("🌐 [HomeSentryWeb] Dashboard actief op http://0.0.0.0:\(self.port)")
                case .failed(let error):
                    print("❌ [HomeSentryWeb] Web server fout: \(error)")
                default:
                    break
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: queue)
        } catch {
            print("❌ [HomeSentryWeb] Kon NWListener niet starten: \(error)")
        }
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNextChunk(connection: connection, accumulated: Data())
    }
    
    private func receiveNextChunk(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var currentData = accumulated
            if let d = data { currentData.append(d) }
            
            if currentData.count > 4 {
                if let range = currentData.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = currentData.subdata(in: 0..<range.lowerBound)
                    let bodyData = currentData.subdata(in: range.upperBound..<currentData.count)
                    
                    var contentLength = 0
                    if let headerStr = String(data: headerData, encoding: .utf8) {
                        for line in headerStr.components(separatedBy: "\r\n") {
                            if line.lowercased().hasPrefix("content-length:") {
                                let parts = line.components(separatedBy: ":")
                                if parts.count > 1 {
                                    contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                                }
                            }
                        }
                    }
                    
                    if bodyData.count >= contentLength {
                        self.processRequest(connection: connection, headerData: headerData, body: bodyData)
                        return
                    }
                }
            }
            
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveNextChunk(connection: connection, accumulated: currentData)
            }
        }
    }
    
    private func processRequest(connection: NWConnection, headerData: Data, body: Data) {
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            connection.cancel()
            return
        }
        
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        
        let method = parts[0]
        let fullPath = parts[1]
        let pathParts = fullPath.components(separatedBy: "?")
        let path = pathParts[0]
        let queryString = pathParts.count > 1 ? pathParts[1] : ""
        
        var queryParams: [String: String] = [:]
        for pair in queryString.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                queryParams[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        
        var cookiePIN: String? = nil
        var headerKey: String? = nil
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("cookie:") {
                for c in line.dropFirst(7).components(separatedBy: ";") {
                    let cparts = c.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
                    if cparts.count == 2 && cparts[0] == "homesentry_pin" {
                        cookiePIN = cparts[1]
                    }
                }
            } else if lower.hasPrefix("x-access-key:") || lower.hasPrefix("x-access-pin:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    headerKey = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        let providedKey = queryParams["key"] ?? queryParams["pin"] ?? headerKey ?? cookiePIN ?? ""
        let isAuthorized = accessKey.isEmpty || (providedKey == accessKey)
        let setAuthCookie = (queryParams["key"] == accessKey || queryParams["pin"] == accessKey) && !accessKey.isEmpty
        
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "text/plain", data: Data())
            return
        }
        
        if method == "GET" && path == "/" {
            let html = WebDashboardServer.htmlUI
            var extraHeaders = ""
            if isAuthorized && setAuthCookie {
                extraHeaders = "Set-Cookie: homesentry_pin=\(accessKey); Path=/; Max-Age=2592000; SameSite=Lax\r\n"
            }
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "text/html; charset=utf-8", data: Data(html.utf8), extraHeaders: extraHeaders)
            return
        }
        
        guard isAuthorized else {
            let resp = Data("{\"error\":\"Unauthorized\",\"message\":\"Voer geldige PIN in\"}".utf8)
            sendResponse(connection: connection, status: 401, statusText: "Unauthorized", type: "application/json", data: resp, cacheable: false)
            return
        }
        
        if method == "GET" && path == "/snapshot" {
            if let jpeg = onGetSnapshot?() {
                sendResponse(connection: connection, status: 200, statusText: "OK", type: "image/jpeg", data: jpeg, cacheable: false)
            } else {
                sendResponse(connection: connection, status: 503, statusText: "Service Unavailable", type: "text/plain", data: Data("Camera starting".utf8), cacheable: false)
            }
            return
        }
        
        if method == "GET" && path == "/api/status" {
            var dict = onGetStatus?() ?? [:]
            dict["authorized"] = true
            let json = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: json, cacheable: false)
            return
        }
        
        if method == "POST" && path == "/api/box" {
            var newPoints: [CGPoint] = []
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let ptsArr = json["points"] as? [[CGFloat]] {
                newPoints = onSaveBox?(ptsArr) ?? []
            }
            let resp: [String: Any] = ["success": true, "points": newPoints.map { [$0.x, $0.y] }]
            let json = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data("{}".utf8)
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: json, cacheable: false)
            return
        }
        
        if method == "POST" && path == "/api/togglearm" {
            let isNowArmed = onToggleArm?() ?? false
            var dict = onGetStatus?() ?? [:]
            dict["isArmed"] = isNowArmed
            let json = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: json, cacheable: false)
            return
        }
        
        if method == "POST" && path == "/api/togglescreen" {
            let isScreenBlack = onToggleScreen?() ?? false
            var dict = onGetStatus?() ?? [:]
            dict["isScreenBlack"] = isScreenBlack
            let json = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: json, cacheable: false)
            return
        }
        
        if method == "GET" && path == "/api/clips" {
            let clips = onGetClips?() ?? []
            let resp: [String: Any] = ["clips": clips]
            let json = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data("{}".utf8)
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: json, cacheable: false)
            return
        }
        
        if method == "GET" && path == "/video" {
            let name = queryParams["name"] ?? ""
            if let data = onGetVideoData?(name) {
                sendResponse(connection: connection, status: 200, statusText: "OK", type: "video/mp4", data: data, cacheable: true)
                return
            }
        }
        
        sendResponse(connection: connection, status: 404, statusText: "Not Found", type: "text/plain", data: Data("Not found".utf8))
    }
    
    private func sendResponse(connection: NWConnection, status: Int, statusText: String, type: String, data: Data, cacheable: Bool = true, extraHeaders: String = "") {
        let cacheHeader = cacheable ? "Cache-Control: max-age=3600\r\n" : "Cache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\n"
        let header = "HTTP/1.1 \(status) \(statusText)\r\n" +
                     "Content-Type: \(type)\r\n" +
                     "Content-Length: \(data.count)\r\n" +
                     cacheHeader +
                     "Access-Control-Allow-Origin: *\r\n" +
                     "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                     "Access-Control-Allow-Headers: Content-Type, X-Access-Key, X-Access-PIN\r\n" +
                     extraHeaders +
                     "Connection: close\r\n\r\n"
        var full = Data(header.utf8)
        full.append(data)
        connection.send(content: full, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    // MARK: - Responsive Dark-Mode Cyber UI
    static let htmlUI = #"""
<!DOCTYPE html>
<html lang="nl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<title>HomeSentry • Trap & Voordeur Bewaking</title>
<style>
  :root {
    --bg: #090c10;
    --card: rgba(18, 24, 38, 0.85);
    --border: rgba(255, 255, 255, 0.08);
    --accent: #00e5ff;
    --accent-red: #ff3d71;
    --accent-green: #00e676;
    --text: #f0f6fc;
    --muted: #8b949e;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  body { background: var(--bg); color: var(--text); padding: 16px; display: flex; justify-content: center; }
  .container { width: 100%; max-width: 900px; display: flex; flex-direction: column; gap: 14px; }
  
  .header { display: flex; justify-content: space-between; align-items: center; padding: 6px 0; }
  .title { font-size: 20px; font-weight: 800; display: flex; align-items: center; gap: 8px; letter-spacing: -0.3px; }
  .badge { padding: 6px 12px; border-radius: 20px; font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.8px; }
  .badge-armed { background: rgba(0, 230, 118, 0.2); color: var(--accent-green); border: 1px solid var(--accent-green); }
  .badge-standby { background: rgba(255, 170, 0, 0.2); color: #ffaa00; border: 1px solid #ffaa00; }
  
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 10px; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 12px 14px; backdrop-filter: blur(16px); }
  .card-label { font-size: 10.5px; color: var(--muted); text-transform: uppercase; font-weight: 700; letter-spacing: 0.5px; margin-bottom: 4px; }
  .card-val { font-size: 19px; font-weight: 800; }
  .card-sub { font-size: 10.5px; color: var(--muted); margin-top: 2px; }
  
  .stream-card { position: relative; border-radius: 16px; overflow: hidden; background: #000; border: 1px solid var(--border); line-height: 0; }
  #streamImg { width: 100%; height: auto; display: block; }
  #overlayCanvas { position: absolute; top: 0; left: 0; width: 100%; height: 100%; touch-action: none; cursor: crosshair; }
  .stream-tag { position: absolute; top: 10px; left: 10px; background: rgba(0,0,0,0.65); padding: 4px 10px; border-radius: 8px; font-size: 11px; font-weight: 700; border: 1px solid rgba(255,255,255,0.1); }
  
  .sound-box { display: flex; flex-direction: column; gap: 8px; }
  .sound-row { display: flex; justify-content: space-between; align-items: center; padding: 8px 12px; background: rgba(255,255,255,0.03); border-radius: 8px; font-size: 12.5px; }
  .sound-danger { border-left: 3px solid var(--accent-red); background: rgba(255,61,113,0.08); }
  .sound-alert { border-left: 3px solid #ffaa00; }
  
  .btn-row { display: flex; gap: 10px; flex-wrap: wrap; }
  button { flex: 1; padding: 12px; border-radius: 12px; font-size: 13.5px; font-weight: 700; cursor: pointer; border: none; transition: 0.2s; min-width: 130px; }
  .btn-arm { background: var(--accent-green); color: #000; }
  .btn-disarm { background: var(--accent-red); color: #fff; }
  .btn-sec { background: rgba(255,255,255,0.08); color: var(--text); border: 1px solid var(--border); }
  button:hover { filter: brightness(1.15); transform: translateY(-1px); }
  
  .clips-list { display: flex; flex-direction: column; gap: 8px; max-height: 220px; overflow-y: auto; }
  .clip-item { display: flex; justify-content: space-between; align-items: center; padding: 10px 14px; background: rgba(255,255,255,0.03); border-radius: 10px; font-size: 12px; }
  .clip-item a { color: var(--accent); text-decoration: none; font-weight: 700; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="title">🛡️ HomeSentry <span>• Trap & Hal</span></div>
    <div id="statusBadge" class="badge badge-armed">ACTIEF</div>
  </div>

  <div class="grid">
    <div class="card">
      <div class="card-label">🌡️ Temperatuur</div>
      <div class="card-val" id="valTemp">--.- °C</div>
      <div class="card-sub" id="subTemp">Min -- | Max --</div>
    </div>
    <div class="card">
      <div class="card-label">🧭 Barometer</div>
      <div class="card-val" id="valPress">---- hPa</div>
      <div class="card-sub" id="subPress">Druk trend</div>
    </div>
    <div class="card">
      <div class="card-label">🎤 Geluidsniveau</div>
      <div class="card-val" id="valDb">-- dB</div>
      <div class="card-sub" id="subDb">Piek -- dB</div>
    </div>
    <div class="card">
      <div class="card-label">🔋 iPhone XS</div>
      <div class="card-val" id="valBat">--%</div>
      <div class="card-sub" id="subBat">Opslag --</div>
    </div>
  </div>

  <div class="stream-card">
    <img id="streamImg" alt="Live beeld vanaf trap" />
    <canvas id="overlayCanvas"></canvas>
    <div class="stream-tag">📹 10 FPS • Trap naar Voordeur</div>
  </div>

  <div class="btn-row">
    <button id="armBtn" class="btn-disarm" onclick="toggleArm()">⏹ Stop Bewaking</button>
    <button class="btn-sec" onclick="saveBox()">💾 Zone Opslaan</button>
    <button class="btn-sec" onclick="resetBox()">🔄 Reset Voordeur</button>
    <button class="btn-sec" onclick="toggleScreen()">🕶️ OLED Scherm</button>
  </div>

  <div class="card">
    <div class="card-label" style="margin-bottom: 8px;">🔊 Akoestische AI Sensor Monitor (Glas / Rook / Water)</div>
    <div class="sound-box" id="soundBox">
      <div class="sound-row"><span>Wachten op akoestische metingen...</span></div>
    </div>
  </div>

  <div class="card">
    <div class="card-label" style="margin-bottom: 8px;">🎬 Recente Incident Opnames</div>
    <div class="clips-list" id="clipsList">
      <div style="font-size:12px; color:var(--muted);">Laden...</div>
    </div>
  </div>
</div>

<script>
let isArmed = true;
let points = [[0.2, 0.4], [0.8, 0.4], [0.8, 0.9], [0.2, 0.9]];
let draggingIdx = -1;
const canvas = document.getElementById('overlayCanvas');
const ctx = canvas.getContext('2d');
const img = document.getElementById('streamImg');

function resizeCanvas() {
  const w = img.clientWidth;
  const h = img.clientHeight;
  if (w > 0 && h > 0) {
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    draw();
  }
}
window.addEventListener('resize', resizeCanvas);

function draw() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  if (points.length < 4) return;
  
  ctx.beginPath();
  const screenPts = points.map(p => ({ x: p[0] * canvas.width, y: p[1] * canvas.height }));
  ctx.moveTo(screenPts[0].x, screenPts[0].y);
  for (let i = 1; i < screenPts.length; i++) ctx.addLineTo(screenPts[i].x, screenPts[i].y);
  ctx.closePath();
  ctx.fillStyle = 'rgba(0, 229, 255, 0.12)';
  ctx.fill();
  ctx.lineWidth = 2;
  ctx.strokeStyle = '#00e5ff';
  ctx.stroke();

  screenPts.forEach((p, idx) => {
    ctx.beginPath();
    ctx.arc(p.x, p.y, 8, 0, Math.PI * 2);
    ctx.fillStyle = idx === draggingIdx ? '#ffaa00' : '#00e5ff';
    ctx.fill();
    ctx.strokeStyle = '#fff';
    ctx.lineWidth = 2;
    ctx.stroke();
  });
}

function getPos(e) {
  const rect = canvas.getBoundingClientRect();
  const clientX = e.touches ? e.touches[0].clientX : e.clientX;
  const clientY = e.touches ? e.touches[0].clientY : e.clientY;
  return { x: clientX - rect.left, y: clientY - rect.top };
}

function onDown(e) {
  const pos = getPos(e);
  draggingIdx = -1;
  points.forEach((p, idx) => {
    const px = p[0] * canvas.width;
    const py = p[1] * canvas.height;
    if (Math.hypot(pos.x - px, pos.y - py) < 24) draggingIdx = idx;
  });
  if (draggingIdx !== -1) e.preventDefault();
}

function onMove(e) {
  if (draggingIdx === -1) return;
  const pos = getPos(e);
  points[draggingIdx] = [
    Math.max(0.02, Math.min(0.98, pos.x / canvas.width)),
    Math.max(0.02, Math.min(0.98, pos.y / canvas.height))
  ];
  draw();
}

function onUp() { draggingIdx = -1; draw(); }

canvas.addEventListener('mousedown', onDown);
window.addEventListener('mousemove', onMove);
window.addEventListener('mouseup', onUp);
canvas.addEventListener('touchstart', onDown, { passive: false });
window.addEventListener('touchmove', onMove, { passive: false });
window.addEventListener('touchend', onUp);

async function refreshSnapshot() {
  try {
    const res = await fetch('/snapshot?t=' + Date.now());
    if (res.ok) {
      const blob = await res.blob();
      img.src = URL.createObjectURL(blob);
      img.onload = () => { resizeCanvas(); };
    }
  } catch (e) {}
}

async function fetchStatus() {
  try {
    const res = await fetch('/api/status');
    if (!res.ok) return;
    const d = await res.json();
    
    document.getElementById('valTemp').innerText = `${d.temperature ? d.temperature.toFixed(1) : '20.5'} °C`;
    document.getElementById('subTemp').innerText = `Min ${d.minTemp ? d.minTemp.toFixed(1) : '19.8'}° | Max ${d.maxTemp ? d.maxTemp.toFixed(1) : '21.6'}°`;
    document.getElementById('valPress').innerText = `${d.pressure ? d.pressure.toFixed(1) : '1013'} hPa`;
    document.getElementById('subPress').innerText = d.pressureTrend || 'Stabiel';
    document.getElementById('valDb').innerText = `${d.decibels ? Math.round(d.decibels) : 40} dB`;
    document.getElementById('subDb').innerText = `Piek ${d.peakDecibels ? Math.round(d.peakDecibels) : 45} dB`;
    document.getElementById('valBat').innerText = `${d.battery || 100}% ${d.isCharging ? '⚡' : ''}`;
    document.getElementById('subBat').innerText = `${d.disk || ''} • ${d.thermalState || 'Koel'}`;

    const badge = document.getElementById('statusBadge');
    const armBtn = document.getElementById('armBtn');
    isArmed = d.isArmed;
    if (isArmed) {
      badge.className = 'badge badge-armed';
      badge.innerText = 'ACTIEF';
      armBtn.className = 'btn-disarm';
      armBtn.innerText = '⏹ Stop Bewaking';
    } else {
      badge.className = 'badge badge-standby';
      badge.innerText = 'STANDBY';
      armBtn.className = 'btn-arm';
      armBtn.innerText = '▶ Start Bewaking';
    }

    if (d.points && d.points.length === 4 && draggingIdx === -1) {
      points = d.points;
      draw();
    }

    // Geluiden
    const soundBox = document.getElementById('soundBox');
    if (d.recentSounds && d.recentSounds.length > 0) {
      soundBox.innerHTML = d.recentSounds.slice(0, 5).map(s => {
        const cls = s.isEmergency ? 'sound-row sound-danger' : 'sound-row';
        return `<div class="${cls}">
          <span><strong>${s.emoji || '🔊'} ${s.name || s.type}</strong> (${Math.round(s.confidence * 100)}%)</span>
          <span style="color:var(--muted)">${s.time} • ${Math.round(s.decibels)} dB</span>
        </div>`;
      }).join('');
    } else {
      soundBox.innerHTML = '<div class="sound-row"><span>Geen recente alarmeringen. Omgeving rustig.</span></div>';
    }
  } catch (e) {}
}

async function toggleArm() {
  await fetch('/api/togglearm', { method: 'POST' });
  fetchStatus();
}

async function saveBox() {
  await fetch('/api/box', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ points })
  });
  alert('Voordeur zone opgeslagen!');
}

function resetBox() {
  points = [[0.2, 0.4], [0.8, 0.4], [0.8, 0.9], [0.2, 0.9]];
  draw();
  saveBox();
}

async function toggleScreen() {
  await fetch('/api/togglescreen', { method: 'POST' });
}

async function fetchClips() {
  try {
    const res = await fetch('/api/clips');
    if (!res.ok) return;
    const d = await res.json();
    const list = document.getElementById('clipsList');
    if (d.clips && d.clips.length > 0) {
      list.innerHTML = d.clips.slice(0, 8).map(c => `
        <div class="clip-item">
          <span>📹 <strong>${c.category}</strong> • ${c.date} (${c.duration}s)</span>
          <a href="/video?name=${encodeURIComponent(c.filename)}" target="_blank">Bekijk Video &darr;</a>
        </div>
      `).join('');
    } else {
      list.innerHTML = '<div style="font-size:12px; color:var(--muted);">Nog geen opnames bewaard.</div>';
    }
  } catch (e) {}
}

setInterval(refreshSnapshot, 600);
setInterval(fetchStatus, 2000);
setInterval(fetchClips, 10000);
fetchStatus();
fetchClips();
refreshSnapshot();
setTimeout(resizeCanvas, 300);
</script>
</body>
</html>
"""#
}
