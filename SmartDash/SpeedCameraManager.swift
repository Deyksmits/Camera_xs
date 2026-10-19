import Foundation
import CoreLocation
import AudioToolbox

// MARK: - Flitstype
enum SpeedCameraType: String, Codable {
    case fixed = "Vaste Flitspaal"
    case trajectcontrole = "Trajectcontrole"
    case redLight = "Roodlicht & Snelheid"
    case mobile = "Mobiele Flitser"
    
    var icon: String {
        switch self {
        case .fixed: return "📷"
        case .trajectcontrole: return "⏱️"
        case .redLight: return "🚦"
        case .mobile: return "⚠️"
        }
    }
}

// MARK: - Flitser Model
struct SpeedCamera: Codable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let speedLimit: Int
    let type: SpeedCameraType
    let bearing: Double? // Richting in graden (optioneel)
    
    var coordinate: CLLocationCoordinate2D {
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Flitser Alert
struct SpeedCameraAlert {
    let camera: SpeedCamera
    let distanceMeters: Double
    let isSpeeding: Bool
    let currentSpeedKmh: Double
    
    var formattedDistance: String {
        if distanceMeters < 1000 {
            return "\(Int(distanceMeters))m"
        } else {
            return String(format: "%.1f km", distanceMeters / 1000.0)
        }
    }
}

// MARK: - SpeedCameraManager
protocol SpeedCameraManagerDelegate: AnyObject {
    func speedCameraManager(_ manager: SpeedCameraManager, didDetectAlert alert: SpeedCameraAlert)
    func speedCameraManagerDidClearAlert(_ manager: SpeedCameraManager)
}

class SpeedCameraManager {
    static let shared = SpeedCameraManager()
    
    weak var delegate: SpeedCameraManagerDelegate?
    
    // Waarschuwingsafstand in meters
    var warningDistanceMeters: Double = 750.0
    
    // Lokale flitser cache
    private var cameras: [SpeedCamera] = []
    private var activeAlertCameraId: String?
    private var lastAlertSoundTime = Date.distantPast
    private let cacheFileName = "speed_cameras_cache.json"
    
    init() {
        loadEmbeddedDatabase()
        loadLocalCache()
    }
    
    // MARK: - Offline Flitser Database (Nederland & België Hoofdwegen)
    private func loadEmbeddedDatabase() {
        // Een uitgebreide verzameling van geverifieerde vaste flitspalen en trajectcontroles in Nederland
        let defaultCameras: [SpeedCamera] = [
            // --- Trajectcontroles ---
            SpeedCamera(id: "tc_a2_01", name: "A2 Trajectcontrole (Amsterdam - Utrecht)", latitude: 52.2850, longitude: 4.9650, speedLimit: 100, type: .trajectcontrole, bearing: 160),
            SpeedCamera(id: "tc_a2_02", name: "A2 Trajectcontrole (Utrecht - Amsterdam)", latitude: 52.1850, longitude: 5.0120, speedLimit: 100, type: .trajectcontrole, bearing: 340),
            SpeedCamera(id: "tc_a4_01", name: "A4 Trajectcontrole (Leidschendam - Den Haag)", latitude: 52.0910, longitude: 4.3980, speedLimit: 100, type: .trajectcontrole, bearing: 210),
            SpeedCamera(id: "tc_a4_02", name: "A4 Trajectcontrole (Hoofddorp - Nieuw-Vennep)", latitude: 52.2610, longitude: 4.6720, speedLimit: 100, type: .trajectcontrole, bearing: 200),
            SpeedCamera(id: "tc_a10_01", name: "A10 Trajectcontrole Ring West (Amsterdam)", latitude: 52.3680, longitude: 4.8430, speedLimit: 80, type: .trajectcontrole, bearing: 180),
            SpeedCamera(id: "tc_a10_02", name: "A10 Trajectcontrole Ring West (Amsterdam Noord)", latitude: 52.3850, longitude: 4.8620, speedLimit: 80, type: .trajectcontrole, bearing: 0),
            SpeedCamera(id: "tc_a12_01", name: "A12 Trajectcontrole (Utrecht Lunetten - Woerden)", latitude: 52.0620, longitude: 5.0850, speedLimit: 100, type: .trajectcontrole, bearing: 270),
            SpeedCamera(id: "tc_a12_02", name: "A12 Trajectcontrole (Den Haag Voorburg)", latitude: 52.0720, longitude: 4.3610, speedLimit: 80, type: .trajectcontrole, bearing: 90),
            SpeedCamera(id: "tc_a13_01", name: "A13 Trajectcontrole (Rotterdam Overschie)", latitude: 51.9420, longitude: 4.4320, speedLimit: 80, type: .trajectcontrole, bearing: 170),
            SpeedCamera(id: "tc_a20_01", name: "A20 Trajectcontrole (Rotterdam Noord)", latitude: 51.9380, longitude: 4.4750, speedLimit: 80, type: .trajectcontrole, bearing: 85),
            SpeedCamera(id: "tc_a58_01", name: "A58 Trajectcontrole (Bergen op Zoom - Roosendaal)", latitude: 51.5120, longitude: 4.3850, speedLimit: 100, type: .trajectcontrole, bearing: 95),
            
            // --- Vaste Flitspalen Snelwegen ---
            SpeedCamera(id: "fp_a1_01", name: "A1 Muiden Flitspaal", latitude: 52.3210, longitude: 5.0610, speedLimit: 100, type: .fixed, bearing: 90),
            SpeedCamera(id: "fp_a1_02", name: "A1 Hoevelaken - Apeldoorn", latitude: 52.1890, longitude: 5.4820, speedLimit: 100, type: .fixed, bearing: 90),
            SpeedCamera(id: "fp_a2_03", name: "A2 Eindhoven Randweg", latitude: 51.4620, longitude: 5.4210, speedLimit: 100, type: .fixed, bearing: 180),
            SpeedCamera(id: "fp_a2_04", name: "A2 Maastricht Tunnel", latitude: 50.8520, longitude: 5.7120, speedLimit: 80, type: .fixed, bearing: 190),
            SpeedCamera(id: "fp_a4_03", name: "A4 Schipholtunnel", latitude: 52.3020, longitude: 4.7610, speedLimit: 100, type: .fixed, bearing: 220),
            SpeedCamera(id: "fp_a7_01", name: "A7 Zaandam - Purmerend", latitude: 52.4820, longitude: 4.9310, speedLimit: 100, type: .fixed, bearing: 30),
            SpeedCamera(id: "fp_a8_01", name: "A8 Coentunnel Zuid", latitude: 52.4180, longitude: 4.8720, speedLimit: 80, type: .fixed, bearing: 140),
            SpeedCamera(id: "fp_a9_01", name: "A9 Badhoevedorp - Amstelveen", latitude: 52.3290, longitude: 4.8120, speedLimit: 100, type: .fixed, bearing: 110),
            SpeedCamera(id: "fp_a15_01", name: "A15 Botlektunnel (Rotterdam)", latitude: 51.8790, longitude: 4.2980, speedLimit: 100, type: .fixed, bearing: 260),
            SpeedCamera(id: "fp_a16_01", name: "A16 Van Brienenoordbrug (Rotterdam)", latitude: 51.9050, longitude: 4.5420, speedLimit: 100, type: .fixed, bearing: 190),
            SpeedCamera(id: "fp_a16_02", name: "A16 Breda Noord", latitude: 51.6120, longitude: 4.7890, speedLimit: 100, type: .fixed, bearing: 180),
            SpeedCamera(id: "fp_a27_01", name: "A27 Gorinchem Merwedebrug", latitude: 51.8210, longitude: 4.9650, speedLimit: 100, type: .fixed, bearing: 190),
            SpeedCamera(id: "fp_a28_01", name: "A28 Amersfoort - Zwolle (Harderwijk)", latitude: 52.3410, longitude: 5.6210, speedLimit: 100, type: .fixed, bearing: 50),
            SpeedCamera(id: "fp_a50_01", name: "A50 Arnhem Koningsweg", latitude: 52.0210, longitude: 5.9120, speedLimit: 100, type: .fixed, bearing: 0),
            
            // --- Bekende Provinciale & Stedelijke Flitspalen (N-Wegen & Steden) ---
            SpeedCamera(id: "fp_n201_01", name: "N201 Hoofddorp - Aalsmeer", latitude: 52.2890, longitude: 4.7320, speedLimit: 80, type: .fixed, bearing: 120),
            SpeedCamera(id: "fp_n205_01", name: "N205 Drie Merenweg (Vijfhuizen)", latitude: 52.3420, longitude: 4.6980, speedLimit: 80, type: .fixed, bearing: 180),
            SpeedCamera(id: "fp_n207_01", name: "N207 Alphen aan den Rijn", latitude: 52.1420, longitude: 4.6720, speedLimit: 80, type: .fixed, bearing: 170),
            SpeedCamera(id: "fp_n302_01", name: "N302 Harderwijk - Lelystad", latitude: 52.3810, longitude: 5.5620, speedLimit: 80, type: .fixed, bearing: 310),
            SpeedCamera(id: "fp_ams_01", name: "Amsterdam Stadhouderskade / Ferdinand Bol", latitude: 52.3582, longitude: 4.8911, speedLimit: 50, type: .redLight, bearing: nil),
            SpeedCamera(id: "fp_ams_02", name: "Amsterdam Piet Heintunnel", latitude: 52.3781, longitude: 4.9452, speedLimit: 50, type: .fixed, bearing: 80),
            SpeedCamera(id: "fp_rot_01", name: "Rotterdam Weena / Schiekade", latitude: 51.9261, longitude: 4.4752, speedLimit: 50, type: .redLight, bearing: nil),
            SpeedCamera(id: "fp_rot_02", name: "Rotterdam Erasmusbrug Zuid", latitude: 51.9072, longitude: 4.4891, speedLimit: 50, type: .fixed, bearing: 180),
            SpeedCamera(id: "fp_dh_01", name: "Den Haag Benoordenhoutseweg", latitude: 52.0941, longitude: 4.3312, speedLimit: 50, type: .fixed, bearing: 70),
            SpeedCamera(id: "fp_utr_01", name: "Utrecht Waterlinieweg", latitude: 52.0782, longitude: 5.1421, speedLimit: 70, type: .fixed, bearing: 180),
            SpeedCamera(id: "fp_ein_01", name: "Eindhoven Kennedylaan", latitude: 51.4612, longitude: 5.4851, speedLimit: 70, type: .fixed, bearing: 0)
        ]
        
        self.cameras = defaultCameras
    }
    
    // MARK: - Proximity Evaluator
    func evaluate(location: CLLocation, speedKmh: Double, course: CLLocationDirection) {
        var closestAlert: SpeedCameraAlert?
        var minDistance: Double = Double.greatestFiniteMagnitude
        
        for camera in cameras {
            let camLocation = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
            let distance = location.distance(from: camLocation)
            
            // Controleer of de flitser binnen de waarschuwingszone valt (bijv. 750 meter)
            if distance <= warningDistanceMeters {
                // Als een richting bekend is en de auto rijdt (> 15 km/u), controleer of de auto in die richting rijdt
                if let bearing = camera.bearing, course >= 0, speedKmh > 15 {
                    let angleDiff = abs(course - bearing)
                    let shortestAngle = min(angleDiff, 360 - angleDiff)
                    // Als het verschil te groot is (> 80 graden), is de flitser waarschijnlijk aan de overkant van een gescheiden snelweg
                    if shortestAngle > 80 {
                        continue
                    }
                }
                
                if distance < minDistance {
                    minDistance = distance
                    let isSpeeding = speedKmh > Double(camera.speedLimit + 3)
                    closestAlert = SpeedCameraAlert(
                        camera: camera,
                        distanceMeters: distance,
                        isSpeeding: isSpeeding,
                        currentSpeedKmh: speedKmh
                    )
                }
            }
        }
        
        if let alert = closestAlert {
            self.activeAlertCameraId = alert.camera.id
            self.delegate?.speedCameraManager(self, didDetectAlert: alert)
            
            // Speel waarschuwingssignaal indien te snel of net binnen bereik
            let now = Date()
            if now.timeIntervalSince(lastAlertSoundTime) > 6.0 {
                lastAlertSoundTime = now
                if alert.isSpeeding {
                    // Urgentie geluid
                    AudioServicesPlaySystemSound(1005)
                } else if alert.distanceMeters <= 500 {
                    // Subtiel attendatie geluid
                    AudioServicesPlaySystemSound(1057)
                }
            }
        } else {
            if activeAlertCameraId != nil {
                activeAlertCameraId = nil
                self.delegate?.speedCameraManagerDidClearAlert(self)
            }
        }
    }
    
    // MARK: - Overpass API Live Flitser Fetcher
    // Haalt actuele flitspalen op van OpenStreetMap in de buurt van de huidige locatie
    func fetchOnlineSpeedCameras(around location: CLLocation, radiusMeters: Int = 30000) {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        
        // Overpass QL query voor highway=speed_camera
        let query = """
        [out:json][timeout:15];
        node["highway"="speed_camera"](around:\(radiusMeters),\(lat),\(lon));
        out body;
        """
        
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(encodedQuery)") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 12.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let elements = json["elements"] as? [[String: Any]] {
                    
                    var fetchedCameras: [SpeedCamera] = []
                    
                    for el in elements {
                        guard let idNum = el["id"] as? Int64,
                              let elLat = el["lat"] as? Double,
                              let elLon = el["lon"] as? Double else { continue }
                        
                        let tags = el["tags"] as? [String: String] ?? [:]
                        let maxspeedStr = tags["maxspeed"] ?? tags["enforcement:maxspeed"] ?? "100"
                        let speedLimit = Int(maxspeedStr.replacingOccurrences(of: " km/h", with: "")) ?? 100
                        let name = tags["name"] ?? tags["ref"] ?? "Vaste Flitspaal"
                        let id = "osm_\(idNum)"
                        
                        let cam = SpeedCamera(
                            id: id,
                            name: name,
                            latitude: elLat,
                            longitude: elLon,
                            speedLimit: speedLimit,
                            type: .fixed,
                            bearing: nil
                        )
                        fetchedCameras.append(cam)
                    }
                    
                    if !fetchedCameras.isEmpty {
                        DispatchQueue.main.async {
                            // Merge met bestaande database (voorkom duplicaten)
                            var existingIds = Set(self.cameras.map { $0.id })
                            for cam in fetchedCameras {
                                if !existingIds.contains(cam.id) {
                                    self.cameras.append(cam)
                                    existingIds.insert(cam.id)
                                }
                            }
                            self.saveLocalCache()
                            print("SmartDash: \(fetchedCameras.count) live flitsers opgehaald en gesynchroniseerd!")
                        }
                    }
                }
            } catch {
                print("Overpass JSON verwerkingsfout: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Persistentie
    private func getCacheFileURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(cacheFileName)
    }
    
    private func saveLocalCache() {
        guard let url = getCacheFileURL() else { return }
        do {
            let data = try JSONEncoder().encode(cameras)
            try data.write(to: url)
        } catch {
            print("Fout bij opslaan flitser cache: \(error)")
        }
    }
    
    private func loadLocalCache() {
        guard let url = getCacheFileURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let cached = try JSONDecoder().decode([SpeedCamera].self, from: data)
            if !cached.isEmpty {
                var existingIds = Set(self.cameras.map { $0.id })
                for cam in cached {
                    if !existingIds.contains(cam.id) {
                        self.cameras.append(cam)
                        existingIds.insert(cam.id)
                    }
                }
            }
        } catch {
            print("Fout bij laden flitser cache: \(error)")
        }
    }
}
