import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Schakel schermvergrendeling uit zodat de bewaking 24/7 doorloopt aan de lader
        UIApplication.shared.isIdleTimerDisabled = true
        
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ViewController()
        self.window = window
        window.makeKeyAndVisible()
        
        print("🛡️ [HomeSentry] Opstartvolgorde gereed. Trap- en voordeurbewaking actief!")
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AcousticSentryEngine.shared.stop()
        EnvironmentalEngine.shared.stop()
        WebDashboardServer.shared.stop()
    }
}
