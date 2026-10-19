import Foundation
import QuartzCore
import AudioToolbox

// MARK: - Sprint Resultaat
struct SprintResult {
    let timeSeconds: Double
    let isNewPR: Bool
    let previousPR: Double?
    
    var formattedTime: String {
        return String(format: "%.2f", timeSeconds)
    }
}

// MARK: - Sprint Status
enum SprintStatus {
    case ready               // Auto staat stil (< 3 km/u) - klaar voor lancering
    case running(elapsed: Double, currentSpeed: Double) // Bezig met accelereren
    case completed(SprintResult) // 100 km/u bereikt binnen 12.0 sec!
    case idle                // Normaal rijden
}

// MARK: - 0 - 100 km/u Sprint Timer Engine
class PerformanceTimer {
    static let shared = PerformanceTimer()
    
    private var launchStartTime: Double?
    private var isAccelerating = false
    private let maxSprintDurationSeconds: Double = 12.0
    private let prStorageKey = "smartdash_best_0_100_time"
    
    var onStatusChanged: ((SprintStatus) -> Void)?
    var onSprintCompleted: ((SprintResult) -> Void)?
    
    // Beste tijd ooit opgeslagen
    var personalBestTime: Double? {
        get {
            let saved = UserDefaults.standard.double(forKey: prStorageKey)
            return saved > 0 ? saved : nil
        }
        set {
            if let val = newValue {
                UserDefaults.standard.set(val, forKey: prStorageKey)
            }
        }
    }
    
    func updateSpeed(kmh: Double) {
        let now = CACurrentMediaTime()
        
        // 1. Auto staat stil of rolt heel langzaam: Arming / Gereed
        if kmh < 3.0 {
            if isAccelerating {
                // Afgebroken voor 100 km/u
                isAccelerating = false
                launchStartTime = nil
            }
            onStatusChanged?(.ready)
            return
        }
        
        // 2. Lancering gedetecteerd (versnellen vanuit stilstand)
        if !isAccelerating && launchStartTime == nil && kmh >= 3.0 && kmh <= 20.0 {
            isAccelerating = true
            launchStartTime = now
            onStatusChanged?(.running(elapsed: 0.0, currentSpeed: kmh))
            return
        }
        
        // 3. Actieve sprint naar 100 km/u
        if isAccelerating, let start = launchStartTime {
            let elapsed = now - start
            
            // Als de sprint langer dan 12.0s duurt, breek stilzwijgend af (niet interessant voor de gebruiker)
            if elapsed > maxSprintDurationSeconds {
                isAccelerating = false
                launchStartTime = nil
                onStatusChanged?(.idle)
                return
            }
            
            // Als snelheid weer daalt met meer dan 8 km/u (bijv. afremmen voor stoplicht)
            // laten we de sprint stil vallen
            
            if kmh >= 100.0 {
                // 100 KM/U BEREIKT!
                isAccelerating = false
                launchStartTime = nil
                
                let previous = self.personalBestTime
                var isNewPR = false
                if previous == nil || elapsed < previous! {
                    self.personalBestTime = elapsed
                    isNewPR = true
                }
                
                let result = SprintResult(timeSeconds: elapsed, isNewPR: isNewPR, previousPR: previous)
                
                // Vier feest! Geluidseffect & Haptiek
                AudioServicesPlaySystemSound(1025)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                
                onStatusChanged?(.completed(result))
                onSprintCompleted?(result)
            } else {
                onStatusChanged?(.running(elapsed: elapsed, currentSpeed: kmh))
            }
        } else if kmh > 100.0 {
            onStatusChanged?(.idle)
        }
    }
    
    func resetPR() {
        UserDefaults.standard.removeObject(forKey: prStorageKey)
    }
}
