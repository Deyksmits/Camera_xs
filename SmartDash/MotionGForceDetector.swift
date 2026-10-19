import Foundation
import CoreMotion
import AudioToolbox

// MARK: - MotionGForceDetector Delegate
protocol MotionGForceDetectorDelegate: AnyObject {
    func motionDetector(_ detector: MotionGForceDetector, didUpdateGForce lateral: Double, longitudinal: Double, total: Double)
    func motionDetector(_ detector: MotionGForceDetector, didDetectImpact gForce: Double)
}

// MARK: - Motion & G-Force Detector
class MotionGForceDetector {
    static let shared = MotionGForceDetector()
    
    weak var delegate: MotionGForceDetectorDelegate?
    
    private let motionManager = CMMotionManager()
    private let updateFrequency: Double = 30.0 // 30 Hz
    
    // Botsingsdrempel (standaard 2.4 G)
    var impactThresholdG: Double = 2.4
    private var lastImpactTime = Date.distantPast
    private let impactCooldown: TimeInterval = 20.0
    
    // Gefilterde waarden voor soepele HUD weergave
    private(set) var lateralG: Double = 0.0
    private(set) var longitudinalG: Double = 0.0
    private(set) var totalG: Double = 0.0
    
    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            print("DeviceMotion niet beschikbaar op dit apparaat")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = 1.0 / updateFrequency
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            guard let self = self, let motion = motion, error == nil else { return }
            self.processMotion(motion)
        }
    }
    
    func stop() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }
    
    private func processMotion(_ motion: CMDeviceMotion) {
        // Gebruik userAcceleration (versnelling zonder constante zwaartekracht 1G)
        let accel = motion.userAcceleration
        
        let rawLateral = accel.x
        let rawLongitudinal = accel.y
        let rawVertical = accel.z
        
        // Laagdoorlaatfilter voor soepele visualisatie op de HUD
        let alpha = 0.25
        lateralG = (alpha * rawLateral) + ((1.0 - alpha) * lateralG)
        longitudinalG = (alpha * rawLongitudinal) + ((1.0 - alpha) * longitudinalG)
        
        let currentTotal = sqrt(pow(accel.x, 2) + pow(accel.y, 2) + pow(accel.z, 2))
        totalG = (alpha * currentTotal) + ((1.0 - alpha) * totalG)
        
        delegate?.motionDetector(self, didUpdateGForce: lateralG, longitudinal: longitudinalG, total: totalG)
        
        // Botsingsdetectie: controleer ruwe piekversnelling
        if currentTotal >= impactThresholdG {
            let now = Date()
            if now.timeIntervalSince(lastImpactTime) > impactCooldown {
                lastImpactTime = now
                // Speel luid alarmsignaal
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                AudioServicesPlaySystemSound(1005)
                delegate?.motionDetector(self, didDetectImpact: currentTotal)
            }
        }
    }
}
