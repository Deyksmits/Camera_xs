import Foundation
import QuartzCore
import AudioToolbox

// MARK: - Sprint & Acceleratie Resultaat
struct AccelerationResult: Codable {
    let targetSpeed: Int       // bv. 70 km/u
    let peakSpeed: Double      // bv. 78.4 km/u
    let timeSeconds: Double    // bv. 4.32 s
    let isNewPR: Bool
    let date: Date
    
    var formattedTime: String {
        return String(format: "%.2f", timeSeconds)
    }
    
    var title: String {
        return "0 → \(targetSpeed) KM/U"
    }
}

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
    case ready                                           // Auto staat stil (< 3 km/u) - klaar voor lancering
    case running(elapsed: Double, currentSpeed: Double)  // Bezig met accelereren
    case completed(SprintResult)                         // 100 km/u sprint voltooid
    case completedAcceleration(AccelerationResult)       // Snelle acceleratie voltooid (bv 0-70 bij 78 piek)
    case idle                                            // Normaal rijden
}

// MARK: - Intelligente Acceleratie & 0-100 Sprint Timer Engine
class PerformanceTimer {
    static let shared = PerformanceTimer()
    
    private var launchStartTime: Double?
    private var isAccelerating = false
    private var peakSpeed: Double = 0.0
    private var peakSpeedTime: Double = 0.0
    private var speedMilestones: [Int: Double] = [:] // Snelheid target (bv 50, 60, 70) -> Tijd vanaf start
    private var hasTriggeredForCurrentPull = false
    
    private let maxSprintDurationSeconds: Double = 16.0
    private let prStorageKey = "smartdash_best_0_100_time"
    private let recentRunsKey = "smartdash_recent_accelerations"
    
    var onStatusChanged: ((SprintStatus) -> Void)?
    var onSprintCompleted: ((SprintResult) -> Void)?
    var onAccelerationCompleted: ((AccelerationResult) -> Void)?
    
    // Beste 0-100 tijd ooit opgeslagen
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
    
    // Recente acceleraties opslaan en ophalen voor het compacte scorebord
    var recentAccelerations: [AccelerationResult] {
        get {
            guard let data = UserDefaults.standard.data(forKey: recentRunsKey),
                  let runs = try? JSONDecoder().decode([AccelerationResult].self, data: data) else {
                return []
            }
            return runs
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: recentRunsKey)
            }
        }
    }
    
    func updateSpeed(kmh: Double) {
        let now = CACurrentMediaTime()
        
        // 1. Auto staat stil of rolt heel langzaam (< 3 km/u): Gereed voor sprint
        if kmh < 3.0 {
            if isAccelerating && !hasTriggeredForCurrentPull {
                finalizeAccelerationPull(now: now)
            }
            isAccelerating = false
            launchStartTime = nil
            peakSpeed = 0.0
            speedMilestones.removeAll()
            hasTriggeredForCurrentPull = false
            onStatusChanged?(.ready)
            return
        }
        
        // 2. Lancering gedetecteerd (versnellen vanuit stilstand)
        if !isAccelerating && launchStartTime == nil && kmh >= 3.0 && kmh <= 25.0 {
            isAccelerating = true
            launchStartTime = now
            peakSpeed = kmh
            peakSpeedTime = now
            speedMilestones.removeAll()
            hasTriggeredForCurrentPull = false
            onStatusChanged?(.running(elapsed: 0.0, currentSpeed: kmh))
            return
        }
        
        // 3. Actieve acceleratie pull
        if isAccelerating, let start = launchStartTime {
            let elapsed = now - start
            
            // Houd pieksnelheid bij
            if kmh > peakSpeed {
                peakSpeed = kmh
                peakSpeedTime = now
            }
            
            // Sla mijlpalen op per 10 km/u (10, 20, 30, 40, 50, 60, 70, 80, 90, 100...)
            let maxStep = Int(kmh / 10.0) * 10
            if maxStep >= 10 {
                for step in stride(from: 10, through: maxStep, by: 10) {
                    if speedMilestones[step] == nil {
                        speedMilestones[step] = elapsed
                    }
                }
            }
            
            // Check of sprint te lang duurt
            if elapsed > maxSprintDurationSeconds {
                if !hasTriggeredForCurrentPull {
                    finalizeAccelerationPull(now: now)
                }
                isAccelerating = false
                launchStartTime = nil
                onStatusChanged?(.idle)
                return
            }
            
            // Voltooiing conditie A: 100 km/u bereikt
            if kmh >= 100.0 && !hasTriggeredForCurrentPull {
                hasTriggeredForCurrentPull = true
                isAccelerating = false
                launchStartTime = nil
                
                let sprintTime = speedMilestones[100] ?? elapsed
                let previous = self.personalBestTime
                var isNewPR = false
                if previous == nil || sprintTime < previous! {
                    self.personalBestTime = sprintTime
                    isNewPR = true
                }
                
                let sprintRes = SprintResult(timeSeconds: sprintTime, isNewPR: isNewPR, previousPR: previous)
                let accelRes = AccelerationResult(targetSpeed: 100,
                                                  peakSpeed: peakSpeed,
                                                  timeSeconds: sprintTime,
                                                  isNewPR: isNewPR,
                                                  date: Date())
                saveRecentAcceleration(accelRes)
                
                AudioServicesPlaySystemSound(1025)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                
                onStatusChanged?(.completed(sprintRes))
                onSprintCompleted?(sprintRes)
                onAccelerationCompleted?(accelRes)
                return
            }
            
            // Voltooiing conditie B: Bestuurder laat gas los of remt af na een snelle acceleratie
            // (bv. trok op naar 78 km/u en zakt nu onder 74 km/u, of bleef 1.5s stabiel rond piek)
            let droppedFromPeak = (peakSpeed - kmh) >= 4.0
            let leveledOff = (now - peakSpeedTime) >= 1.5 && elapsed >= 2.5
            
            if (droppedFromPeak || leveledOff) && !hasTriggeredForCurrentPull {
                finalizeAccelerationPull(now: now)
                isAccelerating = false
                launchStartTime = nil
                return
            }
            
            onStatusChanged?(.running(elapsed: elapsed, currentSpeed: kmh))
        } else if kmh > 100.0 {
            onStatusChanged?(.idle)
        }
    }
    
    private func finalizeAccelerationPull(now: Double) {
        guard !hasTriggeredForCurrentPull else { return }
        hasTriggeredForCurrentPull = true
        
        // Rond af naar beneden op tientallen (bv. 78 -> 70, 53 -> 50, 92 -> 90)
        let rounded = Int(peakSpeed / 10.0) * 10
        guard rounded >= 30, let timeForTarget = speedMilestones[rounded] else {
            onStatusChanged?(.idle)
            return
        }
        
        var isNewPR = false
        if rounded == 100 {
            let prev = personalBestTime
            if prev == nil || timeForTarget < prev! {
                personalBestTime = timeForTarget
                isNewPR = true
            }
        }
        
        let result = AccelerationResult(targetSpeed: rounded,
                                        peakSpeed: peakSpeed,
                                        timeSeconds: timeForTarget,
                                        isNewPR: isNewPR,
                                        date: Date())
        saveRecentAcceleration(result)
        
        AudioServicesPlaySystemSound(1025)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        
        onStatusChanged?(.completedAcceleration(result))
        onAccelerationCompleted?(result)
    }
    
    private func saveRecentAcceleration(_ result: AccelerationResult) {
        var runs = recentAccelerations
        runs.insert(result, at: 0)
        if runs.count > 10 {
            runs = Array(runs.prefix(10))
        }
        recentAccelerations = runs
    }
    
    func resetPR() {
        UserDefaults.standard.removeObject(forKey: prStorageKey)
        UserDefaults.standard.removeObject(forKey: recentRunsKey)
    }
}
