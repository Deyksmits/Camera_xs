import Foundation
import CoreMotion
import UIKit

// MARK: - Omgevings- en Klimaattelemetrie Engine
public final class EnvironmentalEngine {
    public static let shared = EnvironmentalEngine()
    
    private let altimeter = CMAltimeter()
    
    // Telemetrie data
    public private(set) var pressureHPa: Double = 1013.25
    public private(set) var baselinePressureHPa: Double = 1013.25
    public private(set) var pressureTrend: String = "Stabiel" // Stijgend, Dalend, Stabiel
    public private(set) var isDoorDraftPulseDetected: Bool = false
    
    // Temperatuur (°C)
    public private(set) var estimatedRoomTemperatureC: Double = 20.5
    public private(set) var minTempToday: Double = 19.8
    public private(set) var maxTempToday: Double = 21.6
    
    // Thermische toestand van de iPhone
    public var thermalStateString: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Optimaal (Koel)"
        case .fair: return "Normaal"
        case .serious: return "Warm"
        case .critical: return "Heet (Throttling)"
        @unknown default: return "Onbekend"
        }
    }
    
    // Lichtniveau (Luma)
    public var currentAmbientLuma: Float = 0.5
    public var isNightOrDark: Bool {
        return currentAmbientLuma < 0.22
    }
    
    // Callbacks
    public var onPressurePulse: ((Double) -> Void)?
    
    private var recentPressureReadings: [(Date, Double)] = []
    
    private init() {}
    
    public func start() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("⚠️ [EnvironmentalEngine] Barometer niet beschikbaar op dit toestel")
            return
        }
        
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data, error == nil else { return }
            
            // data.pressure is in kilopascals (kPa). Omrekenen naar hectopascals (hPa):
            let currentHPa = data.pressure.doubleValue * 10.0
            self.processPressureReading(currentHPa)
        }
        
        print("🧭 [EnvironmentalEngine] Barometer & Omgevingssensor actief")
    }
    
    public func stop() {
        altimeter.stopRelativeAltitudeUpdates()
    }
    
    private func processPressureReading(_ hpa: Double) {
        pressureHPa = hpa
        let now = Date()
        recentPressureReadings.append((now, hpa))
        
        // Houd de laatste 60 seconden bij
        recentPressureReadings = recentPressureReadings.filter { now.timeIntervalSince($0.0) <= 60.0 }
        
        if recentPressureReadings.count >= 2 {
            let oldest = recentPressureReadings.first!.1
            let diff = hpa - oldest
            
            // Tocht-detectie (wanneer de voordeur beneden openslaat ontstaat een abrupte drukgolf in het trapgat)
            if abs(diff) > 0.35 {
                isDoorDraftPulseDetected = true
                onPressurePulse?(diff)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.isDoorDraftPulseDetected = false
                }
            }
            
            if diff > 0.15 {
                pressureTrend = "↗ Stijgend (Helder)"
            } else if diff < -0.15 {
                pressureTrend = "↘ Dalend (Neerslag)"
            } else {
                pressureTrend = "→ Stabiel"
            }
        }
        
        // Simuleer een stabiele geschatte kamertemperatuur gebaseerd op de thermische sensor en batterijtoestand
        updateTemperatureEstimate()
    }
    
    private func updateTemperatureEstimate() {
        let thermal = ProcessInfo.processInfo.thermalState
        let baseTemp: Double = 20.0
        let thermalOffset: Double
        switch thermal {
        case .nominal: thermalOffset = 0.5
        case .fair: thermalOffset = 1.2
        case .serious: thermalOffset = 2.4
        case .critical: thermalOffset = 3.8
        @unknown default: thermalOffset = 1.0
        }
        
        let est = baseTemp + thermalOffset
        estimatedRoomTemperatureC = (estimatedRoomTemperatureC * 0.95) + (est * 0.05)
        minTempToday = min(minTempToday, estimatedRoomTemperatureC)
        maxTempToday = max(maxTempToday, estimatedRoomTemperatureC)
    }
    
    public func updateAmbientLuma(_ luma: Float) {
        currentAmbientLuma = luma
    }
}
