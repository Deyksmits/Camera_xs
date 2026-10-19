import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var silentPlayer: AVAudioPlayer?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Disable screen sleep timer when app is running in foreground on charger
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Setup background audio keepalive so the DNS engine continues servicing queries 24/7 when locked
        setupBackgroundKeepalive()
        
        // Boot the DNS engine on UDP port 53
        DNSEngine.shared.start()
        
        // Boot the embedded Web Dashboard on TCP port 8080
        WebDashboardServer.shared.start()
        
        // Setup UI Window
        let window = UIWindow(frame: UIScreen.main.bounds)
        let mainVC = ViewController()
        let navController = UINavigationController(rootViewController: mainVC)
        navController.setNavigationBarHidden(true, animated: false)
        window.rootViewController = navController
        self.window = window
        window.makeKeyAndVisible()
        
        print("[NetShield] Boot sequence complete. DNS AdBlocker is active!")
        return true
    }

    private func setupBackgroundKeepalive() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            
            // Create a 1-second silent WAV audio data in memory
            if let silentWavData = createSilentWAVData() {
                silentPlayer = try AVAudioPlayer(data: silentWavData)
                silentPlayer?.numberOfLoops = -1 // Loop infinitely
                silentPlayer?.volume = 0.01 // Inaudible
                silentPlayer?.prepareToPlay()
                silentPlayer?.play()
                print("[NetShield] 24/7 background audio keepalive activated successfully.")
            }
        } catch {
            print("[NetShield] Keepalive audio setup error: \(error.localizedDescription)")
        }
    }

    /// Generates a valid in-memory PCM 44.1kHz 16-bit Mono silent WAV file
    private func createSilentWAVData() -> Data? {
        let sampleRate: Int32 = 44100
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let durationSeconds: Int = 1
        let numSamples = sampleRate * Int32(durationSeconds)
        let dataSize = numSamples * Int32(channels) * Int32(bitsPerSample / 8)
        let totalSize = 36 + dataSize
        
        var data = Data()
        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var chunkSize = totalSize
        data.append(Data(bytes: &chunkSize, count: 4))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        
        // fmt subchunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        var subchunk1Size: Int32 = 16
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: Int16 = 1 // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var ch = channels
        data.append(Data(bytes: &ch, count: 2))
        var sr = sampleRate
        data.append(Data(bytes: &sr, count: 4))
        var byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = channels * (bitsPerSample / 8)
        data.append(Data(bytes: &blockAlign, count: 2))
        var bps = bitsPerSample
        data.append(Data(bytes: &bps, count: 2))
        
        // data subchunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var dSize = dataSize
        data.append(Data(bytes: &dSize, count: 4))
        
        // Zero audio samples
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        print("[NetShield] App entered background. DNS Engine continues running.")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        print("[NetShield] App entered foreground.")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        DNSEngine.shared.stop()
        WebDashboardServer.shared.stop()
    }
}
