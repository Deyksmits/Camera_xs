import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var silentPlayer: AVAudioPlayer?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Schakel schermvergrendeling uit zodat de bewaking 24/7 doorloopt
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Setup achtergrond keepalive zodat iOS de app nooit afsluit
        setupBackgroundKeepalive()
        
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ViewController()
        self.window = window
        window.makeKeyAndVisible()
        
        print("🛡️ [HomeSentry] Opstartvolgorde gereed. Trap- en voordeurbewaking actief!")
        return true
    }

    private func setupBackgroundKeepalive() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            
            if let silentWav = createSilentWAVData() {
                silentPlayer = try AVAudioPlayer(data: silentWav)
                silentPlayer?.numberOfLoops = -1
                silentPlayer?.volume = 0.001
                silentPlayer?.prepareToPlay()
                silentPlayer?.play()
            }
        } catch {
            print("⚠️ [HomeSentry] Kon keepalive audio niet starten: \(error)")
        }
    }

    private func createSilentWAVData() -> Data? {
        let sampleRate: Int32 = 44100
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let durationSeconds: Int = 1
        let numSamples = sampleRate * Int32(durationSeconds)
        let dataSize = numSamples * Int32(channels) * Int32(bitsPerSample / 8)
        let totalSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var chunkSize = totalSize
        data.append(Data(bytes: &chunkSize, count: 4))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        var subchunk1Size: Int32 = 16
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: Int16 = 1
        data.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = channels
        data.append(Data(bytes: &numChannels, count: 2))
        var sRate = sampleRate
        data.append(Data(bytes: &sRate, count: 4))
        var byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = channels * (bitsPerSample / 8)
        data.append(Data(bytes: &blockAlign, count: 2))
        var bps = bitsPerSample
        data.append(Data(bytes: &bps, count: 2))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var sDataSize = dataSize
        data.append(Data(bytes: &sDataSize, count: 4))
        data.append(Data(count: Int(dataSize)))
        return data
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AcousticSentryEngine.shared.stop()
        EnvironmentalEngine.shared.stop()
        WebDashboardServer.shared.stop()
    }
}
