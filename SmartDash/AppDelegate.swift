import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Configureer audio sessie voor achtergrondopname en waarschuwingssignalen
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("AudioSession configuratie waarschuwing: \(error)")
        }

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = DashViewController()
        window?.makeKeyAndVisible()
        return true
    }
}
