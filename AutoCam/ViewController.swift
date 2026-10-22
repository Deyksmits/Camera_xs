import UIKit
import AVFoundation
import Vision
import Photos
import AVKit
import Network
import Darwin

// MARK: - Detectie Categorieën
enum DetectionCategory: String, CaseIterable {
    case person = "Personen"
    case cyclist = "Fietsers"
    case car = "Autos"
    case other = "Overig"
    
    var displayName: String {
        switch self {
        case .person: return "Persoon"
        case .cyclist: return "Fietser"
        case .car: return "Auto"
        case .other: return "Ander object / Beweging"
        }
    }
    
    var emoji: String {
        switch self {
        case .person: return "👤"
        case .cyclist: return "🚲"
        case .car: return "🚗"
        case .other: return "📦"
        }
    }
    
    var folderName: String {
        switch self {
        case .person: return "Personen"
        case .cyclist: return "Fietsers"
        case .car: return "Autos"
        case .other: return "Overig"
        }
    }
}

// MARK: - Nachtmodus Instellingen (Automatische Helderheid & Shutter Boost)
enum NightModeSetting: String, CaseIterable {
    case auto = "Auto"
    case on = "Aan"
    case off = "Uit"
    
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "Altijd Aan"
        case .off: return "Uit"
        }
    }
}

// MARK: - Geavanceerde AI Bewegingsdetector (Anti-Boom, Anti-Gordijn & Anti-Reflectie)
class ZoneMotionDetector {
    private var backgroundGrid: [Float]?
    private var lastGrid: [UInt8]?
    private var signGrid: [Int8]?
    private var oscillationScore: [Float]?
    private var lastCols = 36
    private var lastRows = 64
    private var consecutiveMotionFrames = 0
    private let requiredConsecutiveFrames = 3 // Vereist ~300ms aanhoudende beweging
    var isNightMode: Bool = false
    
    // Gevoeligheidsdrempel voor individuele cellen
    private var pixelDeltaThreshold: Float {
        return isNightMode ? 15.0 : 22.0
    }
    
    func reset() {
        backgroundGrid = nil
        lastGrid = nil
        signGrid = nil
        oscillationScore = nil
        consecutiveMotionFrames = 0
    }
    
    func processFrame(pixelBuffer: CVPixelBuffer, polygon: [CGPoint]) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return false }
        
        let isPortrait = height >= width
        let cols = isPortrait ? 36 : 64
        let rows = isPortrait ? 64 : 36
        
        var currentGrid = [UInt8](repeating: 0, count: cols * rows)
        let stepX = width / cols
        let stepY = height / rows
        
        if CVPixelBufferIsPlanar(pixelBuffer) {
            guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return false }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
            
            for r in 0..<rows {
                let py = min(r * stepY, height - 1)
                let rowOffset = py * bytesPerRow
                for c in 0..<cols {
                    let px = min(c * stepX, width - 1)
                    currentGrid[r * cols + c] = ptr[rowOffset + px]
                }
            }
        } else {
            guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
            
            for r in 0..<rows {
                let py = min(r * stepY, height - 1)
                let rowOffset = py * bytesPerRow
                for c in 0..<cols {
                    let px = min(c * stepX, width - 1)
                    let pOffset = rowOffset + (px * 4)
                    let b = Int(ptr[pOffset])
                    let g = Int(ptr[pOffset + 1])
                    let rVal = Int(ptr[pOffset + 2])
                    currentGrid[r * cols + c] = UInt8((rVal * 77 + g * 150 + b * 29) >> 8)
                }
            }
        }
        
        if backgroundGrid == nil || lastGrid == nil || signGrid == nil || oscillationScore == nil || lastCols != cols || lastRows != rows {
            backgroundGrid = currentGrid.map { Float($0) }
            lastGrid = currentGrid
            signGrid = [Int8](repeating: 0, count: cols * rows)
            oscillationScore = [Float](repeating: 0.0, count: cols * rows)
            lastCols = cols
            lastRows = rows
            return false
        }
        
        guard let prevGrid = lastGrid, var bgGrid = backgroundGrid, var signs = signGrid, var osc = oscillationScore else { return false }
        
        var totalZoneCells = 0
        var changedCells = 0
        var sumDeltas: Float = 0.0
        var minCol = cols, maxCol = 0
        var minRow = rows, maxRow = 0
        
        let hasPolygon = polygon.count >= 3
        var polygonPath: UIBezierPath?
        if hasPolygon {
            let path = UIBezierPath()
            path.move(to: polygon[0])
            for pt in polygon.dropFirst() { path.addLine(to: pt) }
            path.close()
            polygonPath = path
        }
        
        for r in 0..<rows {
            let normY = (CGFloat(r) + 0.5) / CGFloat(rows)
            for c in 0..<cols {
                let normX = (CGFloat(c) + 0.5) / CGFloat(cols)
                let point = CGPoint(x: normX, y: normY)
                
                let inZone = polygonPath?.contains(point) ?? true
                if !inZone { continue }
                
                totalZoneCells += 1
                let idx = r * cols + c
                let cur = Float(currentGrid[idx])
                let prev = Float(prevGrid[idx])
                let bg = bgGrid[idx]
                
                let diffFromBg = abs(cur - bg)
                let diffFromPrev = cur - prev
                
                // 1. Detecteer snelle richting-omkeringen (flikkeren / wiegen van bladeren of wapperende gordijnen)
                let currentSign: Int8 = diffFromPrev > 3.0 ? 1 : (diffFromPrev < -3.0 ? -1 : 0)
                if currentSign != 0 && signs[idx] != 0 && currentSign != signs[idx] {
                    // Teken omgekeerd (bijv. + naar -): oscillerende beweging
                    osc[idx] = min(8.0, osc[idx] + 2.0)
                } else {
                    // Geleidelijk afbouwen
                    osc[idx] = max(0.0, osc[idx] - 0.4)
                }
                signs[idx] = currentSign
                
                let isOscillating = osc[idx] >= 2.8
                
                // 2. Adaptief achtergrondmodel updaten
                if isOscillating {
                    // Oscillerende ruis (boom, gordijn): laat het achtergrondmodel zich hier snel aan aanpassen
                    bgGrid[idx] = bg * 0.82 + cur * 0.18
                } else if diffFromBg <= pixelDeltaThreshold {
                    // Rustige cel: zachtjes meebewegen met natuurlijk daglicht
                    bgGrid[idx] = bg * 0.92 + cur * 0.08
                } else {
                    // Echte kandidaat voorgrond: bevries achtergrond zodat het object gedetecteerd blijft
                    bgGrid[idx] = bg * 0.995 + cur * 0.005
                }
                
                // 3. Alleen tellen als het GEEN oscillerende ruis is en boven de drempel ligt
                if diffFromBg > pixelDeltaThreshold && !isOscillating {
                    changedCells += 1
                    sumDeltas += diffFromBg
                    minCol = min(minCol, c)
                    maxCol = max(maxCol, c)
                    minRow = min(minRow, r)
                    maxRow = max(maxRow, r)
                }
            }
        }
        
        backgroundGrid = bgGrid
        signGrid = signs
        oscillationScore = osc
        lastGrid = currentGrid
        
        guard totalZoneCells > 0 else { return false }
        
        // 4. Anti-Reflectie & Anti-Gordijn Filter:
        // Wapperende gordijnen achter glas of zonreflecties veranderen een gigantisch diffuus oppervlak tegelijk
        let changeRatio = Double(changedCells) / Double(totalZoneCells)
        let avgDelta = changedCells > 0 ? (sumDeltas / Float(changedCells)) : 0.0
        if changeRatio > 0.42 && avgDelta < 32.0 {
            // Diffuse lichtverschuiving of gordijnreflectie over het hele glas -> NEGEREN
            consecutiveMotionFrames = 0
            return false
        }
        
        // 5. Ruimtelijke Compactheid & Massadichtheid (Echt solide object vs dwarrelende ruis)
        let spanCols = max(0, maxCol - minCol + 1)
        let spanRows = max(0, maxRow - minRow + 1)
        let spanArea = spanCols * spanRows
        let fillRatio = spanArea > 0 ? (Double(changedCells) / Double(spanArea)) : 0.0
        
        let minRequiredCells = max(18, Int(Double(totalZoneCells) * 0.035))
        let isSignificantMotion = (changedCells >= minRequiredCells) &&
                                  (spanArea >= 16) &&
                                  (spanCols >= 4 && spanRows >= 4) &&
                                  (fillRatio >= 0.20)
        
        if isSignificantMotion {
            consecutiveMotionFrames += 1
        } else {
            consecutiveMotionFrames = 0
        }
        
        return consecutiveMotionFrames >= requiredConsecutiveFrames
    }
}

// MARK: - Hoofd View Controller
class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {

    // MARK: - Camera & Vision Properties
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let cameraQueue = DispatchQueue(label: "autocam.camera.queue")
    private let visionQueue = DispatchQueue(label: "autocam.vision.queue", qos: .userInitiated)
    
    private var activeVideoOrientation: AVCaptureVideoOrientation = .portrait
    private var latestFrameCGImage: CGImage?
    private var lastStoredFrameTime = Date.distantPast
    private let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    
    // MARK: - Auto Bewakingszone (Standaard 4 hoeken die gesleept kunnen worden)
    private var polygonPoints: [CGPoint] = [] // Genormaliseerde camera coordinaten (0.0 ... 1.0)
    private var isEditingZone = false
    private var isArmed = false
    private let motionDetector = ZoneMotionDetector()
    
    // MARK: - Start Countdown Timer (5 Seconden)
    private var isCountingDown = false
    private var countdownRemaining = 5
    private var countdownTimer: Timer?
    
    // MARK: - Video Opname & 1e Frame Detectie
    private var isRecording = false
    private var recordingStartTime = Date.distantPast
    private var lastMotionTime = Date.distantPast
    private var recordingTimer: Timer?
    
    private let noMotionPostRollSeconds: TimeInterval = 3.5
    private let minRecordDuration: TimeInterval = 6.0
    private let maxRecordDuration: TimeInterval = 60.0
    
    // Bewaartermijn: 2 weken (14 dagen)
    private let retentionDurationSeconds: TimeInterval = 14 * 24 * 3600
    
    // Multi-frame incident tracking voor AI-validatie & ruisfilter (filtert bomen/gordijnen)
    private var firstIncidentFrame: CGImage?
    private var incidentKeyframes: [CGImage] = []
    private var lastKeyframeCaptureTime = Date.distantPast
    private var currentIncidentDate = Date()
    private var filteredNoiseIncidentsCount = 0

    // MARK: - Automatische Nachtmodus & Helderheid Booster
    private var nightModeSetting: NightModeSetting = .auto
    private var isNightBoostActive: Bool = false
    private var lastLumaCheckTime = Date.distantPast
    private var currentAmbientLuma: Float = 0.5

    // MARK: - Telegram & Toegangscode Instellingen
    private var botToken: String {
        get { UserDefaults.standard.string(forKey: "tg_bot_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tg_bot_token") }
    }
    private var chatId: String {
        get { UserDefaults.standard.string(forKey: "tg_chat_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tg_chat_id") }
    }
    private var webAccessPIN: String {
        get { UserDefaults.standard.string(forKey: "web_access_pin") ?? "1234" }
        set { UserDefaults.standard.set(newValue, forKey: "web_access_pin") }
    }

    // MARK: - Professionele CCTV & Beveiligingscamera UI
    private let reticleOverlayView = SurveillanceReticleView()
    private let canvasView = ZoneCanvasView()
    
    // Top CCTV OSD Bar (On-Screen Display met live timecode & status)
    private let statusPill = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let cctvTimeLabel = UILabel()
    private var cctvClockTimer: Timer?
    private let fpsBadge = UILabel()
    private let nightBadge = UILabel()
    private let batteryBadge = UILabel()
    
    // Minimalistische Floating Countdown Pill
    private let countdownPill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let countdownLabel = UILabel()
    
    // Zone Toolbar (verschijnt alleen tijdens bewerken)
    private let zoneToolbar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let autoDetectCarBtn = UIButton(type: .system)
    private let resetBoxBtn = UIButton(type: .system)
    private let doneZoneBtn = UIButton(type: .system)
    
    // Minimalistische Floating Control Dock onderin
    private let controlDock = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let armBtn = UIButton(type: .system)
    private let zoneBtn = UIButton(type: .system)
    private let nightBtn = UIButton(type: .system)
    private let clipsBtn = UIButton(type: .system)
    private let settingsBtn = UIButton(type: .system)
    private let stealthBtn = UIButton(type: .system)
    
    // 100% OLED Pitch Black Scherm (GEEN klok, GEEN tekst, 0% gloed)
    private let blackScreenOverlay = UIView()
    private var isBlackScreenActive = false
    private var savedBrightness: CGFloat = 0.5
    private var autoBlackScreenTimer: Timer?

    // MARK: - Afstandsbediening & Web Remote
    private let webServer = AutoCamWebServer()
    private let telegramListener = TelegramBotCommandListener()

    // MARK: - Batterij Duurzaamheids-Optimalisatie (voor Bewaking op Accu)
    private var isOnPower: Bool = false
    private var isUltraBatterySaverActive: Bool = false

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        UIDevice.current.isBatteryMonitoringEnabled = true
        setupStorageDirectories()
        setupCamera()
        setupCleanUI()
        loadSavedPolygon()
        setupWakeLock()
        updateClipsButtonTitle()
        
        cleanupOldTelegramMessages()
        cleanupOldLocalRecordings()
        
        setupRemoteServices()
        setupPowerStateMonitoring()
        startCCTVClock()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        reticleOverlayView.frame = view.bounds
        reticleOverlayView.setNeedsDisplay()
        canvasView.frame = view.bounds
        blackScreenOverlay.frame = view.bounds
        updateOrientations()
        canvasView.setNeedsDisplay()
    }

    private func startCCTVClock() {
        updateCCTVTimestamp()
        cctvClockTimer?.invalidate()
        cctvClockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateCCTVTimestamp()
        }
    }
    
    private func updateCCTVTimestamp() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        cctvTimeLabel.text = formatter.string(from: Date())
    }

    private func setupWakeLock() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - Opslag Directories
    private var baseRecordingsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Recordings", isDirectory: true)
    }

    private func setupStorageDirectories() {
        let fm = FileManager.default
        for cat in DetectionCategory.allCases {
            let catFolder = baseRecordingsFolder.appendingPathComponent(cat.folderName, isDirectory: true)
            if !fm.fileExists(atPath: catFolder.path) {
                try? fm.createDirectory(at: catFolder, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Camera Setup (10 FPS & Hardware Low-Light Configuratie)
    private func setupCamera() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("Kon camera niet openen")
            return
        }
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }
        
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }
        
        configure10FPSAndNightMode(device: device)
        
        captureSession.commitConfiguration()
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)
        
        canvasView.previewLayer = previewLayer
        canvasView.onPointsUpdated = { [weak self] newPoints in
            self?.polygonPoints = newPoints
            self?.savePolygon()
        }
        
        updateOrientations()
        
        cameraQueue.async {
            self.captureSession.startRunning()
        }
    }

    private func updateOrientations() {
        let orientation: AVCaptureVideoOrientation
        let statusBarOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        switch statusBarOrientation {
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        default: orientation = .portrait
        }
        
        self.activeVideoOrientation = orientation
        
        if let conn = previewLayer?.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = orientation
        }
        if let conn = videoOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = orientation
        }
        if let conn = movieOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = orientation
        }
    }

    // MARK: - 10 FPS & Nachtmodus Camera Configuratie
    private func configure10FPSAndNightMode(device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            // 1. Film op exact 10 FPS
            let tenFps = CMTime(value: 1, timescale: 10)
            var supported = false
            for range in device.activeFormat.videoSupportedFrameRateRanges {
                if range.minFrameRate <= 10.0 && range.maxFrameRate >= 10.0 {
                    device.activeVideoMinFrameDuration = tenFps
                    device.activeVideoMaxFrameDuration = tenFps
                    supported = true
                    break
                }
            }
            if !supported {
                if let minRange = device.activeFormat.videoSupportedFrameRateRanges.min(by: { $0.minFrameRate < $1.minFrameRate }) {
                    let lowest = Int32(max(minRange.minFrameRate, 1.0))
                    let duration = CMTime(value: 1, timescale: lowest)
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }
            }
            
            // 2. Hardware Low Light Boost inschakelen
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            
            // 3. Continu auto exposure & witbalans
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {
            print("Kon camera 10 FPS en nachtmodus niet configureren: \(error)")
        }
    }

    // MARK: - Automatische Donker/Licht Evaluatie & Helderheid Booster
    private func evaluateNightMode(ambientLuma: Float) {
        let shouldBoost: Bool
        switch nightModeSetting {
        case .on:
            shouldBoost = true
        case .off:
            shouldBoost = false
        case .auto:
            // Hysteresis: inschakelen onder 0.22, uitschakelen boven 0.34
            if isNightBoostActive {
                shouldBoost = (ambientLuma < Float(0.34))
            } else {
                shouldBoost = (ambientLuma < Float(0.22))
            }
        }
        
        if shouldBoost != isNightBoostActive {
            isNightBoostActive = shouldBoost
            motionDetector.isNightMode = shouldBoost
            applyNightBoost(enabled: shouldBoost)
            DispatchQueue.main.async { [weak self] in
                self?.updateNightModeBadge()
            }
        }
    }
    
    private func applyNightBoost(enabled: Bool) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            if enabled {
                // 1. Hardware Low Light Boost (Apple sensor pixel-binning & high photon sensitivity)
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = true
                }
                
                // 2. Maximale exposure bias (tot max hardware limiet van de sensor, bijv. +2.0 of +3.0 EV)
                let maxBias = device.maxExposureTargetBias
                let targetBias = max(maxBias, Float(2.0)) // Pak minstens +2.0 of het absolute hardware maximum
                device.setExposureTargetBias(targetBias, completionHandler: nil)
                
                // 3. Geoptimaliseerde witbalans voor nachtzicht:
                // Voorkomt dat de sensor jaagt op kleur in het pikdonker of blauwe ruis creëert
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } else {
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = false
                }
                device.setExposureTargetBias(0.0, completionHandler: nil)
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        } catch {
            print("applyNightBoost fout: \(error)")
        }
    }

    // MARK: - Geavanceerd Nachtzicht / B&W Image Processing Pipeline
    /// Zet donkere beelden om in haarscherp, ruisvrij zwart-wit met gelifte schaduwen en aangescherpte contouren
    static func applyNightVisionFilter(to ciImage: CIImage) -> CIImage {
        // Stap 1: Zwart-wit (0% saturatie) verwijdert 85% van alle chromatische sensorruis in het donker,
        // gecombineerd met verhoogd contrast en basishelderheid boost.
        let monochrome = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.35,
            kCIInputBrightnessKey: 0.14
        ])
        
        // Stap 2: Gamma Curve boost (power 0.65 tilt diepe schaduwen en donkere vlakken op zonder highlights op te blazen)
        let gammaBoosted = monochrome.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": 0.65
        ])
        
        // Stap 3: Luminance Sharpening: maakt randen van auto's, personen en fietsen duidelijk zichtbaar in het donker
        return gammaBoosted.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.60
        ])
    }

    @objc private func cycleNightMode() {
        switch nightModeSetting {
        case .auto: nightModeSetting = .on
        case .on: nightModeSetting = .off
        case .off: nightModeSetting = .auto
        }
        evaluateNightMode(ambientLuma: currentAmbientLuma)
        updateNightModeBadge()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func updateNightModeBadge() {
        let title: String
        switch nightModeSetting {
        case .auto:
            title = isNightBoostActive ? "🌙 IR AUTO (AAN)" : "🌙 IR AUTO (DAG)"
        case .on:
            title = "🌙 IR BOOST AAN"
        case .off:
            title = "☀️ IR UIT"
        }
        nightBadge.text = title
        nightBtn.setTitle(isNightBoostActive ? "🌙 Boost" : "🌙 Nacht", for: .normal)
        nightBtn.backgroundColor = isNightBoostActive ? UIColor.systemIndigo.withAlphaComponent(0.6) : UIColor(red: 0.10, green: 0.13, blue: 0.19, alpha: 0.95)
    }

    // MARK: - Professionele CCTV & Beveiligingscamera Surveillance UI
    private func setupCleanUI() {
        // 1. Tactische Viewfinder Reticles (Surveillance Frame)
        view.addSubview(reticleOverlayView)

        // 2. Interactief Guard Zone Canvas
        canvasView.backgroundColor = .clear
        view.addSubview(canvasView)
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        canvasView.addGestureRecognizer(tap)

        // 3. Top CCTV OSD Bar (On-Screen Display met Live Timecode & Telemetrie)
        statusPill.layer.cornerRadius = 16
        statusPill.clipsToBounds = true
        statusPill.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        statusPill.layer.borderWidth = 0.5
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusPill)

        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        statusPill.contentView.addSubview(headerStack)

        statusDot.backgroundColor = .systemYellow
        statusDot.layer.cornerRadius = 4.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 9).isActive = true

        statusLabel.text = "CAM-01 • STANDBY"
        statusLabel.textColor = .white
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)

        cctvTimeLabel.textColor = UIColor(red: 0.65, green: 0.85, blue: 1.0, alpha: 0.9)
        cctvTimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        cctvTimeLabel.text = "00:00:00"

        fpsBadge.text = "10 FPS"
        fpsBadge.textColor = UIColor(red: 0.1, green: 0.9, blue: 0.5, alpha: 1.0)
        fpsBadge.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        fpsBadge.backgroundColor = UIColor(red: 0.1, green: 0.9, blue: 0.5, alpha: 0.15)
        fpsBadge.layer.cornerRadius = 5
        fpsBadge.clipsToBounds = true
        fpsBadge.textAlignment = .center

        nightBadge.text = "🌙 IR AUTO"
        nightBadge.textColor = .white
        nightBadge.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        nightBadge.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        nightBadge.layer.cornerRadius = 5
        nightBadge.clipsToBounds = true
        nightBadge.textAlignment = .center

        headerStack.addArrangedSubview(statusDot)
        headerStack.addArrangedSubview(statusLabel)
        headerStack.addArrangedSubview(cctvTimeLabel)
        headerStack.addArrangedSubview(fpsBadge)
        headerStack.addArrangedSubview(nightBadge)

        // 4. Zone Edit Floating Toolbar
        zoneToolbar.layer.cornerRadius = 16
        zoneToolbar.clipsToBounds = true
        zoneToolbar.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.4).cgColor
        zoneToolbar.layer.borderWidth = 1
        zoneToolbar.isHidden = true
        zoneToolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoneToolbar)

        let zoneStack = UIStackView()
        zoneStack.axis = .horizontal
        zoneStack.distribution = .fillProportionally
        zoneStack.spacing = 8
        zoneStack.translatesAutoresizingMaskIntoConstraints = false
        zoneToolbar.contentView.addSubview(zoneStack)

        styleTacticalButton(autoDetectCarBtn, title: "🎯 Auto Omlijnen", color: UIColor.systemBlue.withAlphaComponent(0.7), action: #selector(autoDetectCarTapped))
        styleTacticalButton(resetBoxBtn, title: "↺ Herstel", color: UIColor.white.withAlphaComponent(0.12), action: #selector(resetBoxToCenter))
        styleTacticalButton(doneZoneBtn, title: "✓ Opslaan", color: UIColor.systemGreen.withAlphaComponent(0.7), action: #selector(finishZoneEdit))

        zoneStack.addArrangedSubview(autoDetectCarBtn)
        zoneStack.addArrangedSubview(resetBoxBtn)
        zoneStack.addArrangedSubview(doneZoneBtn)

        // 5. Countdown Pill
        countdownPill.layer.cornerRadius = 20
        countdownPill.clipsToBounds = true
        countdownPill.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.6).cgColor
        countdownPill.layer.borderWidth = 1.0
        countdownPill.isHidden = true
        countdownPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(countdownPill)

        countdownLabel.text = "⏳ SYSTEEM START IN 5s • TIK OM TE ANNULEREN"
        countdownLabel.textColor = .white
        countdownLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        countdownLabel.textAlignment = .center
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownPill.contentView.addSubview(countdownLabel)

        let cancelTap = UITapGestureRecognizer(target: self, action: #selector(cancelCountdown))
        countdownPill.addGestureRecognizer(cancelTap)

        // 6. Tactical Arming Bar (Prominente Beveiligingsschakelaar)
        armBtn.translatesAutoresizingMaskIntoConstraints = false
        armBtn.layer.cornerRadius = 15
        armBtn.layer.borderWidth = 1.0
        armBtn.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.35).cgColor
        armBtn.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 0.95)
        armBtn.setTitle("🛡️ BEWAKING STARTEN (STANDBY)", for: .normal)
        armBtn.setTitleColor(.white, for: .normal)
        armBtn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .heavy)
        armBtn.addTarget(self, action: #selector(toggleArm), for: .touchUpInside)
        view.addSubview(armBtn)

        // 7. Surveillance Control Deck (5 strakke actieknoppen onderin)
        controlDock.layer.cornerRadius = 18
        controlDock.clipsToBounds = true
        controlDock.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        controlDock.layer.borderWidth = 0.5
        controlDock.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlDock)

        let dockStack = UIStackView()
        dockStack.axis = .horizontal
        dockStack.distribution = .fillEqually
        dockStack.spacing = 6
        dockStack.translatesAutoresizingMaskIntoConstraints = false
        controlDock.contentView.addSubview(dockStack)

        styleDeckButton(zoneBtn, title: "📐 Zone", action: #selector(toggleEditZone))
        styleDeckButton(nightBtn, title: "🌙 Nacht", action: #selector(cycleNightMode))
        styleDeckButton(stealthBtn, title: "🕶️ Zwart", action: #selector(enableBlackScreen))
        styleDeckButton(clipsBtn, title: "📁 Clips", action: #selector(showClipsMenu))
        styleDeckButton(settingsBtn, title: "⚙️ Setup", action: #selector(showSettings))

        dockStack.addArrangedSubview(zoneBtn)
        dockStack.addArrangedSubview(nightBtn)
        dockStack.addArrangedSubview(stealthBtn)
        dockStack.addArrangedSubview(clipsBtn)
        dockStack.addArrangedSubview(settingsBtn)

        // 8. 100% OLED Pitch Black Scherm
        setupBlackScreenOverlay()

        // Constraints
        NSLayoutConstraint.activate([
            // Status Pill OSD
            statusPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusPill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusPill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            statusPill.heightAnchor.constraint(equalToConstant: 38),

            headerStack.leadingAnchor.constraint(equalTo: statusPill.contentView.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: statusPill.contentView.trailingAnchor, constant: -12),
            headerStack.centerYAnchor.constraint(equalTo: statusPill.contentView.centerYAnchor),

            fpsBadge.heightAnchor.constraint(equalToConstant: 22),
            fpsBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            nightBadge.heightAnchor.constraint(equalToConstant: 22),
            nightBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),

            // Zone Toolbar
            zoneToolbar.topAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: 10),
            zoneToolbar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            zoneToolbar.heightAnchor.constraint(equalToConstant: 40),

            zoneStack.topAnchor.constraint(equalTo: zoneToolbar.contentView.topAnchor, constant: 4),
            zoneStack.bottomAnchor.constraint(equalTo: zoneToolbar.contentView.bottomAnchor, constant: -4),
            zoneStack.leadingAnchor.constraint(equalTo: zoneToolbar.contentView.leadingAnchor, constant: 8),
            zoneStack.trailingAnchor.constraint(equalTo: zoneToolbar.contentView.trailingAnchor, constant: -8),

            // Countdown Pill
            countdownPill.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            countdownPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            countdownPill.heightAnchor.constraint(equalToConstant: 44),
            countdownPill.widthAnchor.constraint(equalToConstant: 300),

            countdownLabel.centerXAnchor.constraint(equalTo: countdownPill.contentView.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: countdownPill.contentView.centerYAnchor),

            // Arm Button (Prominente Bewaking Trigger)
            armBtn.bottomAnchor.constraint(equalTo: controlDock.topAnchor, constant: -8),
            armBtn.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            armBtn.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            armBtn.heightAnchor.constraint(equalToConstant: 46),

            // Control Dock (Tactische Knoppenbalk)
            controlDock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            controlDock.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            controlDock.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            controlDock.heightAnchor.constraint(equalToConstant: 46),

            dockStack.topAnchor.constraint(equalTo: controlDock.contentView.topAnchor, constant: 4),
            dockStack.bottomAnchor.constraint(equalTo: controlDock.contentView.bottomAnchor, constant: -4),
            dockStack.leadingAnchor.constraint(equalTo: controlDock.contentView.leadingAnchor, constant: 6),
            dockStack.trailingAnchor.constraint(equalTo: controlDock.contentView.trailingAnchor, constant: -6)
        ])
    }

    private func styleDeckButton(_ btn: UIButton, title: String, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = UIColor(red: 0.10, green: 0.13, blue: 0.19, alpha: 0.95)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        btn.layer.cornerRadius = 12
        btn.layer.borderWidth = 0.8
        btn.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        btn.clipsToBounds = true
        btn.addTarget(self, action: action, for: .touchUpInside)
    }

    private func styleTacticalButton(_ btn: UIButton, title: String, color: UIColor, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = color
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        btn.layer.cornerRadius = 10
        btn.clipsToBounds = true
        btn.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - 5-Seconden Countdown Timer & Arming State
    @objc private func toggleArm() {
        if isArmed {
            isArmed = false
            armBtn.setTitle("🛡️ BEWAKING STARTEN (STANDBY)", for: .normal)
            armBtn.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 0.95)
            armBtn.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.35).cgColor
            statusDot.backgroundColor = .systemYellow
            statusLabel.text = "CAM-01 • STANDBY"
            if isRecording { stopVideoRecording() }
        } else if isCountingDown {
            cancelCountdown()
        } else {
            startCountdown()
        }
    }

    private func startCountdown() {
        if isEditingZone { finishZoneEdit() }
        
        isCountingDown = true
        countdownRemaining = 5
        countdownPill.isHidden = false
        countdownLabel.text = "⏳ SYSTEEM START IN 5s • TIK OM TE ANNULEREN"
        
        armBtn.setTitle("❌ ANNULEER BEWAPENING", for: .normal)
        armBtn.backgroundColor = UIColor(red: 0.28, green: 0.14, blue: 0.05, alpha: 0.95)
        armBtn.layer.borderColor = UIColor.systemOrange.cgColor
        statusDot.backgroundColor = .systemOrange
        statusLabel.text = "CAM-01 • START OVER 5s"
        
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            self.countdownRemaining -= 1
            
            if self.countdownRemaining > 0 {
                self.countdownLabel.text = "⏳ SYSTEEM START IN \(self.countdownRemaining)s • TIK OM TE ANNULEREN"
                self.statusLabel.text = "CAM-01 • START OVER \(self.countdownRemaining)s"
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else {
                timer.invalidate()
                self.countdownTimer = nil
                self.activateArmedMode()
            }
        }
    }

    @objc private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountingDown = false
        countdownPill.isHidden = true
        
        armBtn.setTitle("🛡️ BEWAKING STARTEN (STANDBY)", for: .normal)
        armBtn.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 0.95)
        armBtn.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.35).cgColor
        statusDot.backgroundColor = .systemYellow
        statusLabel.text = "CAM-01 • STANDBY"
    }

    private func activateArmedMode() {
        isCountingDown = false
        countdownPill.isHidden = true
        
        motionDetector.reset()
        isArmed = true
        
        armBtn.setTitle("🟢 BEWAKING ACTIEF (100% BEVEILIGD) • STOP", for: .normal)
        armBtn.backgroundColor = UIColor(red: 0.05, green: 0.22, blue: 0.12, alpha: 0.95)
        armBtn.layer.borderColor = UIColor.systemGreen.cgColor
        statusDot.backgroundColor = .systemGreen
        statusLabel.text = "CAM-01 • ACTIEF"
        
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Zone Inrichting: Box met 4 Sleepbare Hoeken
    @objc private func toggleEditZone() {
        isEditingZone.toggle()
        zoneToolbar.isHidden = !isEditingZone
        canvasView.isEditing = isEditingZone
        
        if isEditingZone {
            // Als er nog geen box is, toon direct een mooie box in het midden
            if polygonPoints.count != 4 {
                resetBoxToCenter()
            }
            statusDot.backgroundColor = .systemBlue
            statusLabel.text = "Sleep de 4 hoeken of tik op je auto"
            zoneBtn.backgroundColor = .systemBlue
        } else {
            finishZoneEdit()
        }
    }

    @objc private func finishZoneEdit() {
        isEditingZone = false
        zoneToolbar.isHidden = true
        canvasView.isEditing = false
        zoneBtn.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        
        statusLabel.text = isArmed ? "BEWAKING ACTIEF" : "STANDBY"
        statusDot.backgroundColor = isArmed ? .systemGreen : .systemYellow
        savePolygon()
    }

    @objc private func resetBoxToCenter() {
        // Plaats een nette 4-hoekige box in het midden van het beeld
        polygonPoints = [
            CGPoint(x: 0.18, y: 0.32), // Linksboven
            CGPoint(x: 0.82, y: 0.32), // Rechtsboven
            CGPoint(x: 0.82, y: 0.68), // Rechtsonder
            CGPoint(x: 0.18, y: 0.68)  // Linksonder
        ]
        canvasView.points = polygonPoints
        savePolygon()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        statusLabel.text = "Box geplaatst • Sleep de 4 hoeken"
    }

    @objc private func autoDetectCarTapped() {
        statusLabel.text = "Tik op jouw auto in de rij"
        statusDot.backgroundColor = .systemBlue
    }

    @objc private func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
        guard isEditingZone else { return }
        let location = gesture.location(in: canvasView)
        let videoPoint = canvasView.layerPointToVideoPoint(location)
        
        // Pas de box direct aan naar de specifieke aangeklikte auto (in genormaliseerde videocoördinaten)
        fitBoxToTappedCar(at: videoPoint)
    }

    // MARK: - Auto Omlijning bij Aantikken (Voor Diagonale Auto's & Auto's in een Rij)
    private func fitBoxToTappedCar(at tapPoint: CGPoint) {
        // Bereken de omvang van specifiek deze auto
        // Een auto in een rij / schuin geparkeerd heeft typisch een breedte van 0.35 - 0.50 en hoogte van 0.25 - 0.40
        var detectedRect: CGRect?
        
        if let cgImg = self.latestFrameCGImage {
            let req = VNGenerateObjectnessBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
            try? handler.perform([req])
            
            if let obs = req.results?.first as? VNSaliencyImageObservation, let objs = obs.salientObjects {
                // Zoek specifiek het object dat het dichtst bij het tikpunt ligt (om niet de buurauto te pakken!)
                var bestObj: CGRect?
                var minDistance: CGFloat = .greatestFiniteMagnitude
                
                for o in objs {
                    let rect = CGRect(x: o.boundingBox.minX, y: 1.0 - o.boundingBox.maxY,
                                      width: o.boundingBox.width, height: o.boundingBox.height)
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    let dist = hypot(center.x - tapPoint.x, center.y - tapPoint.y)
                    
                    if rect.contains(tapPoint) {
                        bestObj = rect
                        break
                    } else if dist < 0.25 && dist < minDistance {
                        minDistance = dist
                        bestObj = rect
                    }
                }
                
                // Beperk breedte als het saliency-model meerdere auto's in de rij heeft samengevoegd
                if let b = bestObj {
                    var w = b.width
                    var h = b.height
                    var cx = b.midX
                    var cy = b.midY
                    
                    // Als de box verdacht breed is (> 0.60), centreer hem strakker rond het tikpunt van de gekozen auto
                    if w > 0.55 {
                        w = 0.46
                        cx = tapPoint.x
                    }
                    if h > 0.50 {
                        h = 0.36
                        cy = tapPoint.y
                    }
                    detectedRect = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
                }
            }
        }
        
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
        
        if let box = detectedRect {
            // Voeg een veiligheidsmarge van ~16% toe
            let mX = max(0.03, box.width * 0.16)
            let mY = max(0.03, box.height * 0.16)
            minX = max(0.02, box.minX - mX)
            maxX = min(0.98, box.maxX + mX)
            minY = max(0.02, box.minY - mY)
            maxY = min(0.98, box.maxY + mY)
        } else {
            // Nette auto-box gecentreerd op het tikpunt
            let defW: CGFloat = 0.48
            let defH: CGFloat = 0.34
            minX = max(0.02, tapPoint.x - defW / 2)
            maxX = min(0.98, tapPoint.x + defW / 2)
            minY = max(0.02, tapPoint.y - defH / 2)
            maxY = min(0.98, tapPoint.y + defH / 2)
        }
        
        // Stel de 4 hoeken in
        polygonPoints = [
            CGPoint(x: minX, y: minY), // Linksboven
            CGPoint(x: maxX, y: minY), // Rechtsboven
            CGPoint(x: maxX, y: maxY), // Rechtsonder
            CGPoint(x: minX, y: maxY)  // Linksonder
        ]
        
        canvasView.points = polygonPoints
        savePolygon()
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        statusLabel.text = "✓ Auto omlijnd! Sleep hoeken indien gewenst."
    }

    private func savePolygon() {
        let array = polygonPoints.map { [$0.x, $0.y] }
        UserDefaults.standard.set(array, forKey: "saved_polygon")
    }

    private func loadSavedPolygon() {
        if let array = UserDefaults.standard.array(forKey: "saved_polygon") as? [[CGFloat]], array.count == 4 {
            polygonPoints = array.map { CGPoint(x: $0[0], y: $0[1]) }
        } else {
            // Standaard gecentreerde box
            polygonPoints = [
                CGPoint(x: 0.18, y: 0.32),
                CGPoint(x: 0.82, y: 0.32),
                CGPoint(x: 0.82, y: 0.68),
                CGPoint(x: 0.18, y: 0.68)
            ]
        }
        canvasView.points = polygonPoints
    }

    // MARK: - 100% OLED Pitch Black Scherm (GEEN klok, GEEN tekst, 0% gloed)
    private func setupBlackScreenOverlay() {
        blackScreenOverlay.backgroundColor = .black
        blackScreenOverlay.isUserInteractionEnabled = true
        blackScreenOverlay.isHidden = true
        view.addSubview(blackScreenOverlay)
        
        // Eén tik om het zwarte scherm te verlaten en weer terug te gaan naar de app
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBlackScreenTap))
        tap.numberOfTapsRequired = 1
        blackScreenOverlay.addGestureRecognizer(tap)
        
        resetAutoBlackScreenTimer()
    }

    @objc func enableBlackScreen() {
        isBlackScreenActive = true
        blackScreenOverlay.isHidden = false
        view.bringSubviewToFront(blackScreenOverlay)
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0.0 // Fysiek OLED schermlicht naar 0
        autoBlackScreenTimer?.invalidate()
        autoBlackScreenTimer = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc func disableBlackScreen() {
        isBlackScreenActive = false
        blackScreenOverlay.isHidden = true
        UIScreen.main.brightness = max(0.4, savedBrightness)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        resetAutoBlackScreenTimer()
    }

    @objc private func handleBlackScreenTap() {
        disableBlackScreen()
    }

    private func resetAutoBlackScreenTimer() {
        autoBlackScreenTimer?.invalidate()
        guard !isBlackScreenActive else { return }
        // Na 25 seconden geen aanraking automatisch naar 100% OLED zwart scherm
        autoBlackScreenTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { [weak self] _ in
            self?.enableBlackScreen()
        }
    }

    // MARK: - Auto-Start & Accubesparing (Bewakingsmodus op Accu)
    private func setupPowerStateMonitoring() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleBatteryStateChanged),
                                               name: UIDevice.batteryStateDidChangeNotification,
                                               object: nil)
        evaluateCurrentPowerState()
    }

    @objc private func handleBatteryStateChanged() {
        evaluateCurrentPowerState()
    }

    private func evaluateCurrentPowerState() {
        let state = UIDevice.current.batteryState
        let isPluggedIn = (state == .charging || state == .full)
        self.isOnPower = isPluggedIn

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if isPluggedIn {
                self.isUltraBatterySaverActive = false
                self.fpsBadge.text = "10 FPS"
            } else {
                self.enableUltraBatterySavingMode()
            }
        }
    }

    private func enableUltraBatterySavingMode() {
        self.isUltraBatterySaverActive = true
        self.fpsBadge.text = "3 FPS 🔋"
        // Schakel OLED scherm direct op 100% zwart na 4 seconden inactiviteit
        if !isBlackScreenActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self, !self.isOnPower, !self.isBlackScreenActive else { return }
                self.enableBlackScreen()
            }
        }
    }

    // MARK: - Instellingen (Telegram, Tailscale/VPN, PIN & 2 Weken Opschoning)
    @objc private func showSettings() {
        resetAutoBlackScreenTimer()
        let tracked = UserDefaults.standard.array(forKey: "tg_tracked_messages") as? [[String: Any]] ?? []
        let msgCount = tracked.count
        
        let ifaces = getAllNetworkInterfaces()
        var linksDesc = ""
        for iface in ifaces {
            let label = iface.isVPN ? "🔒 VPN/Tailscale" : (iface.isWiFi ? "🏠 Wi-Fi" : "📶 Mobiel")
            linksDesc += "• \(label): http://\(iface.ip):\(webServer.port)/?key=\(webAccessPIN)\n"
        }
        if linksDesc.isEmpty {
            linksDesc = "http://\(getLocalIPAddress()):\(webServer.port)/?key=\(webAccessPIN)\n"
        }
        
        let alert = UIAlertController(title: "Instellingen & Afstandsbediening",
                                      message: "🌐 Web Remote (Beveiligd met PIN):\n\(linksDesc)\n⏱️ Opnames worden 2 weken bewaard (\(msgCount) actieve clips).",
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "Bot Token (van @BotFather)"
            tf.text = self.botToken
        }
        alert.addTextField { tf in
            tf.placeholder = "Chat ID (van @userinfobot)"
            tf.text = self.chatId
        }
        alert.addTextField { tf in
            tf.placeholder = "Web Toegangscode / PIN (bijv. 1234)"
            tf.text = self.webAccessPIN
            tf.isSecureTextEntry = false
        }
        alert.addAction(UIAlertAction(title: "Opslaan & Verbind", style: .default, handler: { _ in
            self.botToken = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.chatId = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.webAccessPIN = alert.textFields?[2].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1234"
            self.webServer.accessKey = self.webAccessPIN
            self.updateTelegramListenerConfig()
            self.telegramListener.start()
            self.sendTestMessage()
        }))
        alert.addAction(UIAlertAction(title: "🗑 Schoon Berichten Ouder Dan 2 Weken Op", style: .destructive, handler: { _ in
            self.cleanupOldTelegramMessages()
            self.cleanupOldLocalRecordings()
        }))
        alert.addAction(UIAlertAction(title: "Sluiten", style: .cancel))
        present(alert, animated: true)
    }

    private func sendTestMessage() {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": "✅ *AutoCam Gekoppeld!*\nJe iPhone Xs staat klaar. Bij beweging ontvang je direct 1 bericht met de volwaardige video.\n⏱️ _Video's worden na 2 weken automatisch gewist._",
            "parse_mode": "Markdown"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let res = json["result"] as? [String: Any],
               let msgId = res["message_id"] as? Int {
                DispatchQueue.main.async {
                    self.trackTelegramMessageForDeletion(messageId: msgId)
                }
            }
        }.resume()
    }

    // MARK: - AVCapture Video Data Output (Bewegingsdetectie in de Zone @ 10 FPS & Nachtmeting)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let now = Date()
        
        // Dynamische frame interval:
        // Aan de lader: vloeiende 10 FPS (~0.095s)
        // Op batterij zonder stroom: ultra-zuinige 3 FPS (~0.33s) voor max. accuduur!
        let targetInterval: TimeInterval = isUltraBatterySaverActive ? 0.33 : 0.095
        if now.timeIntervalSince(lastStoredFrameTime) >= targetInterval {
            lastStoredFrameTime = now
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if self.isNightBoostActive {
                ciImage = ViewController.applyNightVisionFilter(to: ciImage)
            }
            self.latestFrameCGImage = self.sharedCIContext.createCGImage(ciImage, from: ciImage.extent)
        }
        
        // Periodieke Donkerte/Licht Detectie (op batterij elke 4s ipv 1.5s om CPU te sparen)
        let lumaCheckInterval: TimeInterval = isUltraBatterySaverActive ? 4.0 : 1.5
        if now.timeIntervalSince(lastLumaCheckTime) >= lumaCheckInterval {
            lastLumaCheckTime = now
            let luma = calculateAverageLuminance(pixelBuffer: pixelBuffer)
            self.currentAmbientLuma = luma
            self.evaluateNightMode(ambientLuma: luma)
        }
        
        guard isArmed else { return }
        
        let hasMotionInZone = motionDetector.processFrame(pixelBuffer: pixelBuffer, polygon: self.polygonPoints)
        
        if hasMotionInZone {
            lastMotionTime = now
            
            if isRecording && now.timeIntervalSince(lastKeyframeCaptureTime) >= 0.6 && incidentKeyframes.count < 6 {
                lastKeyframeCaptureTime = now
                if let frame = self.latestFrameCGImage {
                    incidentKeyframes.append(frame)
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.isRecording {
                    // Pak het allereerste frame dat de beweging startte voor de AI
                    self.firstIncidentFrame = self.latestFrameCGImage
                    if let first = self.firstIncidentFrame {
                        self.incidentKeyframes = [first]
                    } else {
                        self.incidentKeyframes = []
                    }
                    self.lastKeyframeCaptureTime = Date()
                    self.currentIncidentDate = Date()
                    self.startVideoRecording()
                }
            }
        } else {
            if isRecording {
                let timeSinceLastMotion = now.timeIntervalSince(lastMotionTime)
                let totalDuration = now.timeIntervalSince(recordingStartTime)
                
                // Stop pas wanneer het object uit beeld is
                if (timeSinceLastMotion >= noMotionPostRollSeconds && totalDuration >= minRecordDuration) || totalDuration >= maxRecordDuration {
                    DispatchQueue.main.async { [weak self] in
                        self?.stopVideoRecording()
                    }
                }
            }
        }
    }

    // MARK: - Video Opname Beheer (10 FPS)
    private func startVideoRecording() {
        guard !movieOutput.isRecording else { return }
        
        let tempFolder = FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let tempURL = tempFolder.appendingPathComponent("AutoCam_Temp_\(formatter.string(from: Date())).mp4")
        
        if let connection = movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = self.activeVideoOrientation
        }
        
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        isRecording = true
        recordingStartTime = Date()
        lastMotionTime = Date()
        
        statusDot.backgroundColor = .systemRed
        statusLabel.text = "CAM-01 • INCIDENT LOGGING"
        armBtn.setTitle("🔴 OPNEMEN (0:00)", for: .normal)
        armBtn.backgroundColor = UIColor(red: 0.32, green: 0.06, blue: 0.08, alpha: 0.95)
        armBtn.layer.borderColor = UIColor.systemRed.cgColor
        
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.recordingStartTime))
            self.statusLabel.text = "CAM-01 • INCIDENT (0:\(String(format: "%02d", elapsed)))"
            self.armBtn.setTitle("🔴 OPNEMEN (0:\(String(format: "%02d", elapsed)))", for: .normal)
            
            if Date().timeIntervalSince(self.recordingStartTime) >= self.maxRecordDuration {
                self.stopVideoRecording()
                timer.invalidate()
            }
        }
    }

    private func stopVideoRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate (Opname Gereed -> Alleen 1e Frame Analyseren!)
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isRecording = false
            self.statusDot.backgroundColor = .systemOrange
            self.statusLabel.text = "CAM-01 • ANALYSEREN..."
            if self.isArmed {
                self.armBtn.setTitle("🟢 BEWAKING ACTIEF (100% BEVEILIGD) • STOP", for: .normal)
                self.armBtn.backgroundColor = UIColor(red: 0.05, green: 0.22, blue: 0.12, alpha: 0.95)
                self.armBtn.layer.borderColor = UIColor.systemGreen.cgColor
            }
        }
        
        guard error == nil else {
            print("Fout bij opname: \(String(describing: error))")
            firstIncidentFrame = nil
            return
        }
        
        // Gebruik de verzamelde incident-keyframes voor diepgaande AI validatie
        let framesToAnalyze = self.incidentKeyframes.isEmpty ? [self.firstIncidentFrame].compactMap { $0 } : self.incidentKeyframes
        self.incidentKeyframes.removeAll()
        self.firstIncidentFrame = nil
        let incidentDate = self.currentIncidentDate
        let currentPolygon = self.polygonPoints
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            self.classifyAndValidateIncident(keyframes: framesToAnalyze, polygon: currentPolygon) { category in
                self.handleClassifiedIncident(videoURL: outputFileURL,
                                             category: category,
                                             incidentDate: incidentDate)
            }
        }
    }

    // MARK: - Slimme AI Object & Ruis Validatie (Filtert Bomen, Gordijnen & Reflecties)
    private func classifyAndValidateIncident(keyframes: [CGImage],
                                             polygon: [CGPoint],
                                             completion: @escaping (DetectionCategory?) -> Void) {
        guard !keyframes.isEmpty else {
            completion(nil)
            return
        }
        
        var foundPerson = false
        var foundCyclist = false
        var foundCar = false
        var treeFoliageScore: Float = 0.0
        var curtainReflectionScore: Float = 0.0
        var maxSalientForegroundArea: CGFloat = 0.0
        var hasSalientObjectInZone = false
        
        // Bereken bounding box van de auto-zone (polygon)
        var polyMinX: CGFloat = 1.0, polyMaxX: CGFloat = 0.0
        var polyMinY: CGFloat = 1.0, polyMaxY: CGFloat = 0.0
        for pt in polygon {
            polyMinX = min(polyMinX, pt.x)
            polyMaxX = max(polyMaxX, pt.x)
            polyMinY = min(polyMinY, pt.y)
            polyMaxY = max(polyMaxY, pt.y)
        }
        let polyRect = CGRect(x: polyMinX, y: polyMinY, width: max(0.01, polyMaxX - polyMinX), height: max(0.01, polyMaxY - polyMinY))
        
        for cgImage in keyframes {
            // 1. Mensendetectie via Neural Engine (VNDetectHumanRectanglesRequest)
            let humanRequest = VNDetectHumanRectanglesRequest { req, _ in
                if let observations = req.results as? [VNHumanObservation] {
                    for obs in observations where obs.confidence > 0.35 {
                        let box = CGRect(x: obs.boundingBox.minX,
                                         y: 1.0 - obs.boundingBox.maxY,
                                         width: obs.boundingBox.width,
                                         height: obs.boundingBox.height)
                        // Controleer of de persoon de auto-zone raakt of er vlakbij is (< 0.12 afstand)
                        if box.intersects(polyRect) || polyRect.insetBy(dx: -0.12, dy: -0.12).intersects(box) {
                            foundPerson = true
                        }
                    }
                }
            }
            
            // 2. Beeldinhoud & Ruis Classificatie (VNClassifyImageRequest)
            let classifyRequest = VNClassifyImageRequest { req, _ in
                guard let observations = req.results as? [VNClassificationObservation] else { return }
                for obs in observations.prefix(20) where obs.confidence > 0.14 {
                    let id = obs.identifier.lowercased()
                    let conf = obs.confidence
                    
                    if id.contains("person") || id.contains("human") || id.contains("pedestrian") ||
                       id.contains("walker") || id.contains("man") || id.contains("woman") || id.contains("child") {
                        foundPerson = true
                    } else if id.contains("bicycle") || id.contains("cyclist") || id.contains("cycling") ||
                            id.contains("bike") || id.contains("tricycle") || id.contains("moped") ||
                            id.contains("scooter") || id.contains("motorcycle") {
                        foundCyclist = true
                    } else if id.contains("car") || id.contains("automobile") || id.contains("vehicle") ||
                            id.contains("sedan") || id.contains("suv") || id.contains("truck") ||
                            id.contains("pickup") || id.contains("van") || id.contains("minivan") ||
                            id.contains("cab") || id.contains("jeep") || id.contains("bus") {
                        foundCar = true
                    } else if id.contains("tree") || id.contains("leaf") || id.contains("branch") ||
                            id.contains("foliage") || id.contains("plant") || id.contains("vegetation") ||
                            id.contains("shrub") || id.contains("bush") || id.contains("canopy") ||
                            id.contains("woodland") || id.contains("flora") {
                        treeFoliageScore = max(treeFoliageScore, conf)
                    } else if id.contains("curtain") || id.contains("drape") || id.contains("drapery") ||
                            id.contains("window_shade") || id.contains("window_blind") || id.contains("blind") ||
                            id.contains("window") || id.contains("glass") || id.contains("reflection") ||
                            id.contains("interior_room") || id.contains("room") || id.contains("indoor") ||
                            id.contains("curtain_rod") {
                        curtainReflectionScore = max(curtainReflectionScore, conf)
                    }
                }
            }
            
            // 3. Fysiek Voorgrondobject via Saliency (VNGenerateObjectnessBasedSaliencyImageRequest)
            let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest { req, _ in
                if let obs = req.results?.first as? VNSaliencyImageObservation, let objs = obs.salientObjects {
                    for o in objs {
                        let box = CGRect(x: o.boundingBox.minX,
                                         y: 1.0 - o.boundingBox.maxY,
                                         width: o.boundingBox.width,
                                         height: o.boundingBox.height)
                        let area = box.width * box.height
                        maxSalientForegroundArea = max(maxSalientForegroundArea, area)
                        if box.intersects(polyRect) && area > 0.04 {
                            hasSalientObjectInZone = true
                        }
                    }
                }
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([humanRequest, classifyRequest, saliencyRequest])
            
            if foundPerson || foundCyclist {
                break
            }
        }
        
        if foundPerson {
            completion(.person)
        } else if foundCyclist {
            completion(.cyclist)
        } else if foundCar {
            completion(.car)
        } else {
            let isDominatedByTreeOrCurtain = (treeFoliageScore > 0.22 || curtainReflectionScore > 0.20)
            
            if isDominatedByTreeOrCurtain && !hasSalientObjectInZone {
                // RUIS: Bewegen van boom of reflectie van wapperend gordijn! Filter volledig weg.
                completion(nil)
            } else if hasSalientObjectInZone && maxSalientForegroundArea >= 0.08 && !isDominatedByTreeOrCurtain {
                completion(.other)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - Afhandeling Incident (Opslag in Mapje & Exact 1 Bericht naar Telegram)
    private func handleClassifiedIncident(videoURL: URL, category: DetectionCategory?, incidentDate: Date) {
        guard let category = category else {
            // GERAAS GEFILTERD: Boom, gordijn, reflectie of diffuse ruis
            self.filteredNoiseIncidentsCount += 1
            try? FileManager.default.removeItem(at: videoURL)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.statusDot.backgroundColor = .systemTeal
                self.statusLabel.text = "CAM-01 • GERAAS GEFILTERD (Boom/Gordijn)"
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.isArmed && !self.isRecording {
                        self.statusDot.backgroundColor = .systemGreen
                        self.statusLabel.text = "CAM-01 • BEWAKING ACTIEF"
                    }
                }
            }
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let baseName = "AutoCam_\(formatter.string(from: incidentDate))"
        
        let targetCategoryFolder = baseRecordingsFolder.appendingPathComponent(category.folderName, isDirectory: true)
        let finalVideoURL = targetCategoryFolder.appendingPathComponent("\(baseName).mp4")
        
        try? FileManager.default.removeItem(at: finalVideoURL)
        try? FileManager.default.moveItem(at: videoURL, to: finalVideoURL)
        
        saveVideoToPhotosLibrary(fileURL: finalVideoURL)
        
        // Exporteer video met 100% zuivere resolutie en web-ready streaming (geen vervorming/rekking)
        prepareVideoForTelegram(sourceURL: finalVideoURL) { [weak self] cleanURL in
            guard let self = self else { return }
            
            let asset = AVAsset(url: cleanURL)
            var vidWidth = 720
            var vidHeight = 1280
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                vidWidth = Int(abs(size.width))
                vidHeight = Int(abs(size.height))
            }
            let durationSec = max(1, Int(CMTimeGetSeconds(asset.duration)))
            
            // Verzend EXACT 1 BERICHT met de video naar Telegram
            self.sendSingleTelegramVideoMessage(videoURL: cleanURL,
                                                category: category,
                                                durationSeconds: durationSec,
                                                videoWidth: vidWidth,
                                                videoHeight: vidHeight,
                                                date: incidentDate)
            
            // Ruim eventueel tijdelijk exportbestand op
            if cleanURL != finalVideoURL {
                try? FileManager.default.removeItem(at: cleanURL)
            }
        }
        
        cleanupOldTelegramMessages()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateClipsButtonTitle()
            self.statusDot.backgroundColor = .systemGreen
            self.statusLabel.text = "💾 [\(category.folderName)] bewaard"
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if self.isArmed && !self.isRecording {
                    self.statusLabel.text = "CAM-01 • ACTIEF"
                }
            }
        }
    }

    // MARK: - Video Export zonder Vervorming & Optionele Nachtzicht Verbetering
    private func prepareVideoForTelegram(sourceURL: URL, completion: @escaping (URL) -> Void) {
        let asset = AVAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            completion(sourceURL)
            return
        }
        
        let tempExportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCam_Clean_\(UUID().uuidString).mp4")
        
        exportSession.outputURL = tempExportURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        // Als nachtmodus actief is: pas direct contrast-boost, zwart-wit en schaduwlifting toe op alle video-frames
        if self.isNightBoostActive {
            let composition = AVVideoComposition(asset: asset) { filteringRequest in
                let source = filteringRequest.sourceImage
                let filtered = ViewController.applyNightVisionFilter(to: source)
                filteringRequest.finish(with: filtered, context: nil)
            }
            exportSession.videoComposition = composition
        }
        
        exportSession.exportAsynchronously {
            if exportSession.status == .completed {
                completion(tempExportURL)
            } else {
                completion(sourceURL)
            }
        }
    }

    // MARK: - Foto's Galerij Opslag
    private func saveVideoToPhotosLibrary(fileURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }, completionHandler: nil)
        }
    }

    // MARK: - Clips Beheer per Mapje
    private func getClips(in category: DetectionCategory) -> [URL] {
        let folder = baseRecordingsFolder.appendingPathComponent(category.folderName, isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else {
            return []
        }
        return files.filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { u1, u2 in
                let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return d1 > d2
            }
    }

    private func getTotalClipsCount() -> Int {
        var total = 0
        for cat in DetectionCategory.allCases {
            total += getClips(in: cat).count
        }
        return total
    }

    private func updateClipsButtonTitle() {
        let count = getTotalClipsCount()
        clipsBtn.setTitle("📁 Clips (\(count))", for: .normal)
    }

    @objc private func showClipsMenu() {
        let alert = UIAlertController(title: "Bewakingsopnames per Categorie",
                                      message: "Selecteer een mapje om video's te bekijken:\n(Opnames worden 2 weken bewaard)",
                                      preferredStyle: .actionSheet)
        
        for cat in DetectionCategory.allCases {
            let count = getClips(in: cat).count
            let title = "\(cat.emoji) \(cat.folderName) (\(count))"
            alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
                self?.showCategoryClips(category: cat)
            }))
        }
        
        if getTotalClipsCount() > 0 {
            alert.addAction(UIAlertAction(title: "🗑 Wis Alle Opnames", style: .destructive, handler: { [weak self] _ in
                self?.clearAllClips()
            }))
        }
        
        alert.addAction(UIAlertAction(title: "Sluiten", style: .cancel))
        present(alert, animated: true)
    }

    private func showCategoryClips(category: DetectionCategory) {
        let clips = getClips(in: category)
        let alert = UIAlertController(title: "\(category.emoji) Map: \(category.folderName)",
                                      message: clips.isEmpty ? "Geen opnames in dit mapje." : "\(clips.count) opname(s) beschikbaar:",
                                      preferredStyle: .actionSheet)
        
        for clip in clips.prefix(6) {
            let name = clip.lastPathComponent
            let size = (try? clip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let mb = String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
            
            alert.addAction(UIAlertAction(title: "▶️ \(name) (\(mb))", style: .default, handler: { [weak self] _ in
                self?.playVideo(url: clip)
            }))
        }
        
        if clips.count > 6 {
            alert.addAction(UIAlertAction(title: "... en nog \(clips.count - 6) eerdere video's", style: .default, handler: nil))
        }
        
        alert.addAction(UIAlertAction(title: "Terug", style: .cancel))
        present(alert, animated: true)
    }

    private func playVideo(url: URL) {
        let player = AVPlayer(url: url)
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        present(playerVC, animated: true) {
            player.play()
        }
    }

    private func clearAllClips() {
        let fm = FileManager.default
        for cat in DetectionCategory.allCases {
            for clip in getClips(in: cat) {
                try? fm.removeItem(at: clip)
            }
        }
        updateClipsButtonTitle()
    }

    // MARK: - Auto-Verwijdering na 2 Weken (Telegram & Lokale Opslag)
    private func trackTelegramMessageForDeletion(messageId: Int) {
        var tracked = UserDefaults.standard.array(forKey: "tg_tracked_messages") as? [[String: Any]] ?? []
        let newEntry: [String: Any] = [
            "id": messageId,
            "date": Date().timeIntervalSince1970
        ]
        tracked.append(newEntry)
        UserDefaults.standard.set(tracked, forKey: "tg_tracked_messages")
    }

    private func cleanupOldTelegramMessages() {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        guard let tracked = UserDefaults.standard.array(forKey: "tg_tracked_messages") as? [[String: Any]], !tracked.isEmpty else { return }
        
        let now = Date().timeIntervalSince1970
        var remaining: [[String: Any]] = []
        
        for entry in tracked {
            guard let msgId = entry["id"] as? Int, let timestamp = entry["date"] as? TimeInterval else { continue }
            
            if (now - timestamp) >= retentionDurationSeconds {
                deleteTelegramMessage(messageId: msgId)
            } else {
                remaining.append(entry)
            }
        }
        
        UserDefaults.standard.set(remaining, forKey: "tg_tracked_messages")
    }

    private func deleteTelegramMessage(messageId: Int) {
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/deleteMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "chat_id": chatId,
            "message_id": messageId
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let str = String(data: data, encoding: .utf8) {
                print("🗑️ Bericht #\(messageId) na 2 weken verwijderd uit Telegram: \(str)")
            }
        }.resume()
    }

    private func cleanupOldLocalRecordings() {
        let fm = FileManager.default
        let now = Date()
        
        for cat in DetectionCategory.allCases {
            let clips = getClips(in: cat)
            for clip in clips {
                if let date = (try? clip.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                   now.timeIntervalSince(date) >= retentionDurationSeconds {
                    try? fm.removeItem(at: clip)
                    print("🗑️ Lokale opname na 2 weken opgeruimd: \(clip.lastPathComponent)")
                }
            }
        }
        updateClipsButtonTitle()
    }

    // MARK: - Exact 1 Bericht naar Telegram met Video (Geen Losse Foto)
    private func sendSingleTelegramVideoMessage(videoURL: URL,
                                                category: DetectionCategory,
                                                durationSeconds: Int,
                                                videoWidth: Int,
                                                videoHeight: Int,
                                                date: Date) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        guard let videoData = try? Data(contentsOf: videoURL) else { return }
        
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendVideo")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"parse_mode\"\r\n\r\n".data(using: .utf8)!)
        body.append("Markdown\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"width\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(videoWidth)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"height\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(videoHeight)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"duration\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(durationSeconds)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"supports_streaming\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)

        let caption = "\(category.emoji) *\(category.displayName)* gedetecteerd (\(durationSeconds)s)"
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"video\"; filename=\"\(category.folderName).mp4\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(videoData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let res = json["result"] as? [String: Any],
               let msgId = res["message_id"] as? Int {
                DispatchQueue.main.async {
                    self.trackTelegramMessageForDeletion(messageId: msgId)
                }
            }
        }.resume()
    }

    // MARK: - Remote Control Helpers (Web Remote & Telegram Commando's)
    private func setupRemoteServices() {
        webServer.accessKey = self.webAccessPIN
        webServer.onGetSnapshot = { [weak self] in
            return self?.getLatestFrameJPEG()
        }
        webServer.onGetStatus = { [weak self] in
            return self?.getSystemStatusDict() ?? [:]
        }
        webServer.onSaveBox = { [weak self] ptsArr in
            return self?.setPointsFromRemote(ptsArr: ptsArr) ?? []
        }
        webServer.onToggleArm = { [weak self] in
            return self?.toggleArmFromRemote() ?? false
        }
        webServer.onAutoDetect = { [weak self] in
            return self?.performAutoDetectCar() ?? []
        }
        webServer.onResetBox = { [weak self] in
            return self?.performResetBox() ?? []
        }
        webServer.onSetNightMode = { [weak self] modeStr in
            guard let self = self else { return }
            self.runOnMainThread {
                if let mode = NightModeSetting(rawValue: modeStr) {
                    self.nightModeSetting = mode
                } else if modeStr.lowercased() == "auto" {
                    self.nightModeSetting = .auto
                } else if modeStr.lowercased() == "on" || modeStr.lowercased() == "aan" {
                    self.nightModeSetting = .on
                } else if modeStr.lowercased() == "off" || modeStr.lowercased() == "uit" {
                    self.nightModeSetting = .off
                }
                self.evaluateNightMode(ambientLuma: self.currentAmbientLuma)
                self.updateNightModeBadge()
            }
        }
        webServer.onToggleScreen = { [weak self] in
            guard let self = self else { return false }
            return self.runOnMainThread {
                if self.isBlackScreenActive {
                    self.disableBlackScreen()
                    return false
                } else {
                    self.enableBlackScreen()
                    return true
                }
            }
        }
        webServer.start()
        
        updateTelegramListenerConfig()
        telegramListener.onArm = { [weak self] in
            guard let self = self else { return }
            self.runOnMainThread {
                if !self.isArmed {
                    self.activateArmedMode()
                }
            }
        }
        telegramListener.onDisarm = { [weak self] in
            guard let self = self else { return }
            self.runOnMainThread {
                if self.isArmed {
                    self.isArmed = false
                    self.armBtn.setTitle("🛡️ BEWAKING STARTEN (STANDBY)", for: .normal)
                    self.armBtn.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 0.95)
                    self.armBtn.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.35).cgColor
                    self.statusDot.backgroundColor = .systemYellow
                    self.statusLabel.text = "CAM-01 • STANDBY"
                    if self.isRecording { self.stopVideoRecording() }
                }
            }
        }
        telegramListener.onSnapshotRequested = { [weak self] completion in
            let jpeg = self?.getLatestFrameJPEG()
            completion(jpeg)
        }
        telegramListener.onBoxOverlayRequested = { [weak self] completion in
            guard let self = self, let cg = self.latestFrameCGImage else {
                completion(nil)
                return
            }
            let data = createBoxOverlaySnapshot(cgImage: cg,
                                               points: self.polygonPoints,
                                               luma: self.currentAmbientLuma,
                                               isNight: self.isNightBoostActive)
            completion(data)
        }
        telegramListener.onStatusRequested = { [weak self] in
            return self?.getSystemStatusDict() ?? [:]
        }
        telegramListener.onWebUrlRequested = { [weak self] in
            return self?.formatRemoteLinksMarkdown() ?? "http://localhost:\(AutoCamWebServer.defaultPort)"
        }
        telegramListener.onResetBox = { [weak self] in
            _ = self?.performResetBox()
        }
        telegramListener.onAutoDetectBox = { [weak self] in
            return self?.performAutoDetectCar() ?? []
        }
        telegramListener.onNightMode = { [weak self] modeStr in
            guard let self = self else { return }
            self.runOnMainThread {
                if modeStr == "auto" { self.nightModeSetting = .auto }
                else if modeStr == "on" || modeStr == "aan" { self.nightModeSetting = .on }
                else if modeStr == "off" || modeStr == "uit" { self.nightModeSetting = .off }
                self.evaluateNightMode(ambientLuma: self.currentAmbientLuma)
                self.updateNightModeBadge()
            }
        }
        telegramListener.onScreenToggle = { [weak self] enableBlack in
            guard let self = self else { return }
            self.runOnMainThread {
                if enableBlack {
                    self.enableBlackScreen()
                } else {
                    self.disableBlackScreen()
                }
            }
        }
        telegramListener.onSetPIN = { [weak self] newPin in
            guard let self = self, !newPin.isEmpty else { return }
            self.webAccessPIN = newPin
            self.webServer.accessKey = newPin
        }
        telegramListener.onAdjustBox = { [weak self] dx, dy, scale in
            return self?.adjustBox(deltaX: dx, deltaY: dy, scale: scale) ?? []
        }
        telegramListener.start()
    }
    
    func updateTelegramListenerConfig() {
        telegramListener.botToken = self.botToken
        telegramListener.chatId = self.chatId
    }
    
    func formatRemoteLinksMarkdown() -> String {
        let ifaces = getAllNetworkInterfaces()
        var str = ""
        var wifiIp: String?
        var vpnIp: String?
        for iface in ifaces {
            if iface.isVPN && vpnIp == nil {
                vpnIp = iface.ip
            } else if iface.isWiFi && wifiIp == nil {
                wifiIp = iface.ip
            }
        }
        
        if let vpn = vpnIp {
            str += "🔒 *Tailscale / VPN (Overal ter wereld bereikbaar)*:\nhttp://\(vpn):\(webServer.port)/?key=\(webAccessPIN)\n\n"
        }
        
        if let wifi = wifiIp {
            str += "🏠 *Lokaal Wi-Fi (Thuis op hetzelfde netwerk)*:\nhttp://\(wifi):\(webServer.port)/?key=\(webAccessPIN)\n\n"
        }
        
        if str.isEmpty {
            let fallback = getLocalIPAddress()
            str += "🌐 *Lokaal IP*: http://\(fallback):\(webServer.port)/?key=\(webAccessPIN)\n\n"
        }
        
        str += """
        💡 *Direct op afstand bedienen:*
        • Stuur `/box` in Telegram om met handige knoppen de zone te verplaatsen en vergroten/verkleinen (werkt altijd en overal!).
        • Wil je de webinterface overal vandaan kunnen openen? Installeer de gratis Tailscale app op beide iPhones.
        """
        
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func currentWebRemoteURL() -> String {
        let ip = getLocalIPAddress()
        return "http://\(ip):\(webServer.port)/?key=\(webAccessPIN)"
    }
    
    func getLatestFrameJPEG() -> Data? {
        guard let cg = latestFrameCGImage else { return nil }
        let img = UIImage(cgImage: cg)
        return img.jpegData(compressionQuality: 0.70)
    }
    
    func getSystemStatusDict() -> [String: Any] {
        let batteryPct = Int(UIDevice.current.batteryLevel * 100)
        let batteryState = UIDevice.current.batteryState
        let isCharging = (batteryState == .charging || batteryState == .full)
        let disk = getFreeDiskSpaceGB()
        let ip = getLocalIPAddress()
        let ifaces = getAllNetworkInterfaces().map { ["name": $0.name, "ip": $0.ip, "isVPN": $0.isVPN] }
        
        return [
            "isArmed": isArmed,
            "fps": isUltraBatterySaverActive ? 3 : 10,
            "nightMode": nightModeSetting.rawValue,
            "isNightBoostActive": isNightBoostActive,
            "luma": currentAmbientLuma,
            "isScreenBlack": isBlackScreenActive,
            "battery": batteryPct >= 0 ? batteryPct : 100,
            "isCharging": isCharging,
            "isUltraBatterySaver": isUltraBatterySaverActive,
            "disk": disk,
            "ip": ip,
            "interfaces": ifaces,
            "points": polygonPoints.map { [$0.x, $0.y] },
            "filteredNoiseCount": filteredNoiseIncidentsCount,
            "aiFilterActive": true
        ]
    }
    
    func toggleArmFromRemote() -> Bool {
        return runOnMainThread {
            if self.isArmed {
                self.isArmed = false
                self.armBtn.setTitle("🛡️ BEWAKING STARTEN (STANDBY)", for: .normal)
                self.armBtn.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 0.95)
                self.armBtn.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.35).cgColor
                self.statusDot.backgroundColor = .systemYellow
                self.statusLabel.text = "CAM-01 • STANDBY"
                if self.isRecording { self.stopVideoRecording() }
                return false
            } else {
                self.activateArmedMode()
                return true
            }
        }
    }
    
    func setPointsFromRemote(ptsArr: [[CGFloat]]) -> [CGPoint] {
        guard ptsArr.count == 4 else { return self.polygonPoints }
        let pts = ptsArr.map { CGPoint(x: max(0.01, min(0.99, $0[0])), y: max(0.01, min(0.99, $0[1]))) }
        return runOnMainThread {
            self.polygonPoints = pts
            self.canvasView.points = pts
            self.savePolygon()
            self.statusLabel.text = "Box aangepast via afstandsbediening"
            return pts
        }
    }
    
    func performAutoDetectCar(tapPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> [CGPoint] {
        return runOnMainThread {
            self.fitBoxToTappedCar(at: tapPoint)
            return self.polygonPoints
        }
    }
    
    func performResetBox() -> [CGPoint] {
        return runOnMainThread {
            self.resetBoxToCenter()
            return self.polygonPoints
        }
    }
    
    func adjustBox(deltaX: CGFloat, deltaY: CGFloat, scale: CGFloat = 1.0) -> [CGPoint] {
        return runOnMainThread {
            guard self.polygonPoints.count == 4 else { return self.polygonPoints }
            var cx: CGFloat = 0
            var cy: CGFloat = 0
            for pt in self.polygonPoints {
                cx += pt.x
                cy += pt.y
            }
            cx /= 4.0
            cy /= 4.0
            
            var newPts: [CGPoint] = []
            for pt in self.polygonPoints {
                let scaledX = cx + (pt.x - cx) * scale
                let scaledY = cy + (pt.y - cy) * scale
                let finalX = max(0.02, min(0.98, scaledX + deltaX))
                let finalY = max(0.02, min(0.98, scaledY + deltaY))
                newPts.append(CGPoint(x: finalX, y: finalY))
            }
            self.polygonPoints = newPts
            self.canvasView.points = newPts
            self.savePolygon()
            return newPts
        }
    }
    
    @discardableResult
    private func runOnMainThread<T>(_ block: () -> T) -> T {
        if Thread.isMainThread {
            return block()
        } else {
            return DispatchQueue.main.sync { block() }
        }
    }
}

// MARK: - Surveillance Reticle View (Professionele CCTV Viewfinder Hoekmarkeringen)
class SurveillanceReticleView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor(red: 0.15, green: 0.75, blue: 0.95, alpha: 0.35).cgColor)
        ctx.setLineWidth(1.5)
        
        let inset: CGFloat = 20
        let len: CGFloat = 16
        let minX = inset
        let maxX = bounds.width - inset
        let minY = safeAreaInsets.top + inset + 44
        let maxY = bounds.height - safeAreaInsets.bottom - inset - 110
        
        guard maxX > minX + 50, maxY > minY + 50 else { return }
        
        // Top-Left ┌
        ctx.move(to: CGPoint(x: minX, y: minY + len))
        ctx.addLine(to: CGPoint(x: minX, y: minY))
        ctx.addLine(to: CGPoint(x: minX + len, y: minY))
        
        // Top-Right ┐
        ctx.move(to: CGPoint(x: maxX - len, y: minY))
        ctx.addLine(to: CGPoint(x: maxX, y: minY))
        ctx.addLine(to: CGPoint(x: maxX, y: minY + len))
        
        // Bottom-Left └
        ctx.move(to: CGPoint(x: minX, y: maxY - len))
        ctx.addLine(to: CGPoint(x: minX, y: maxY))
        ctx.addLine(to: CGPoint(x: minX + len, y: maxY))
        
        // Bottom-Right ┘
        ctx.move(to: CGPoint(x: maxX - len, y: maxY))
        ctx.addLine(to: CGPoint(x: maxX, y: maxY))
        ctx.addLine(to: CGPoint(x: maxX, y: maxY - len))
        
        ctx.strokePath()
    }
}

// MARK: - Zone Canvas View met 4 Sleepbare Hoekpunten & Whole-Box Pan
class ZoneCanvasView: UIView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    var isEditing: Bool = false {
        didSet { setNeedsDisplay() }
    }
    var onPointsUpdated: (([CGPoint]) -> Void)?
    
    var points: [CGPoint] = [] {
        didSet { setNeedsDisplay() }
    }
    
    private var activeCornerIndex: Int? = nil
    private var isDraggingWholeBox = false
    private var dragStartTouch: CGPoint = .zero
    private var dragStartPoints: [CGPoint] = []
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }
    
    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    /// Berekent het exacte weergavegebied van het 16:9 / 9:16 videobeeld binnen de previewLayer (resizeAspectFill)
    func videoRect() -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let isLandscape = bounds.width >= bounds.height
        let videoAspect: CGFloat = isLandscape ? (16.0 / 9.0) : (9.0 / 16.0)
        let layerAspect: CGFloat = bounds.width / bounds.height
        
        let renderedW: CGFloat
        let renderedH: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        
        if layerAspect > videoAspect {
            renderedW = bounds.width
            renderedH = bounds.width / videoAspect
            originX = 0.0
            originY = (bounds.height - renderedH) / 2.0
        } else {
            renderedH = bounds.height
            renderedW = bounds.height * videoAspect
            originX = (bounds.width - renderedW) / 2.0
            originY = 0.0
        }
        return CGRect(x: originX, y: originY, width: renderedW, height: renderedH)
    }

    /// Zet genormaliseerde videocoördinaten (0.0 ... 1.0, identiek aan de web remote op je andere telefoon) om naar schermpunten
    func videoPointToLayerPoint(_ normPt: CGPoint) -> CGPoint {
        let r = videoRect()
        return CGPoint(x: r.origin.x + normPt.x * r.width,
                       y: r.origin.y + normPt.y * r.height)
    }

    /// Zet schermpunten (vingertik / drag op de iPhone) om naar genormaliseerde videocoördinaten (0.0 ... 1.0)
    func layerPointToVideoPoint(_ screenPt: CGPoint) -> CGPoint {
        let r = videoRect()
        guard r.width > 0, r.height > 0 else { return screenPt }
        let nx = (screenPt.x - r.origin.x) / r.width
        let ny = (screenPt.y - r.origin.y) / r.height
        return CGPoint(x: max(0.01, min(0.99, nx)),
                       y: max(0.01, min(0.99, ny)))
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEditing, points.count == 4 else { return }
        
        let touchLocation = gesture.location(in: self)
        let screenPoints = points.map { videoPointToLayerPoint($0) }
        
        switch gesture.state {
        case .began:
            activeCornerIndex = nil
            isDraggingWholeBox = false
            
            // 1. Controleer of een van de 4 hoekpunten geraakt is (ruime 48pt hitbox)
            for (idx, pt) in screenPoints.enumerated() {
                if hypot(touchLocation.x - pt.x, touchLocation.y - pt.y) < 48 {
                    activeCornerIndex = idx
                    UISelectionFeedbackGenerator().selectionChanged()
                    break
                }
            }
            
            // 2. Indien geen hoekpunt geraakt, maar wel binnen de box: sleep de hele box!
            if activeCornerIndex == nil {
                let path = UIBezierPath()
                path.move(to: screenPoints[0])
                for p in screenPoints.dropFirst() { path.addLine(to: p) }
                path.close()
                if path.contains(touchLocation) {
                    isDraggingWholeBox = true
                    dragStartTouch = touchLocation
                    dragStartPoints = points
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            
        case .changed:
            if let cornerIdx = activeCornerIndex {
                let normPt = layerPointToVideoPoint(touchLocation)
                points[cornerIdx] = normPt
                setNeedsDisplay()
            } else if isDraggingWholeBox {
                let p0 = layerPointToVideoPoint(dragStartTouch)
                let p1 = layerPointToVideoPoint(touchLocation)
                let deltaX = p1.x - p0.x
                let deltaY = p1.y - p0.y
                
                var newPts: [CGPoint] = []
                var canMove = true
                for orig in dragStartPoints {
                    let nx = orig.x + deltaX
                    let ny = orig.y + deltaY
                    if nx < 0.01 || nx > 0.99 || ny < 0.01 || ny > 0.99 {
                        canMove = false
                        break
                    }
                    newPts.append(CGPoint(x: nx, y: ny))
                }
                if canMove {
                    points = newPts
                    setNeedsDisplay()
                }
            }
            
        case .ended, .cancelled:
            activeCornerIndex = nil
            isDraggingWholeBox = false
            onPointsUpdated?(points)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            
        default:
            break
        }
    }
    
    override func draw(_ rect: CGRect) {
        guard points.count >= 2 else { return }
        
        let path = UIBezierPath()
        let screenPoints: [CGPoint] = points.map { videoPointToLayerPoint($0) }
        
        path.move(to: screenPoints[0])
        for pt in screenPoints.dropFirst() {
            path.addLine(to: pt)
        }
        if screenPoints.count >= 3 {
            path.close()
            // Tactische blueprint tint
            UIColor(red: 0.0, green: 0.75, blue: 0.95, alpha: isEditing ? 0.16 : 0.08).setFill()
            path.fill()
        }
        
        // Strakke tactische perimeterlijn
        UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.85).setStroke()
        path.lineWidth = isEditing ? 2.0 : 1.5
        path.lineJoinStyle = .miter
        path.stroke()

        // Tactische Tag bovenaan de perimeter
        if let topPt = screenPoints.min(by: { $0.y < $1.y }) {
            let tagText = isEditing ? "[ZONE CONFIG • BEWERKEN]" : "[GUARD ZONE 01 • AI FILTER ACTIEF]"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: UIColor.systemCyan
            ]
            let tagSize = (tagText as NSString).size(withAttributes: attrs)
            let tagRect = CGRect(x: max(16, min(bounds.width - tagSize.width - 24, topPt.x - 10)),
                                 y: max(74, topPt.y - tagSize.height - 8),
                                 width: tagSize.width + 12,
                                 height: tagSize.height + 4)
            let tagBg = UIBezierPath(roundedRect: tagRect, cornerRadius: 4)
            UIColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 0.85).setFill()
            tagBg.fill()
            tagBg.lineWidth = 0.5
            UIColor.systemCyan.withAlphaComponent(0.5).setStroke()
            tagBg.stroke()
            (tagText as NSString).draw(at: CGPoint(x: tagRect.minX + 6, y: tagRect.minY + 2), withAttributes: attrs)
        }

        // Als we bewerken: teken tactische crosshairs en hoekindexen [P1]...[P4]
        if isEditing {
            for (idx, pt) in screenPoints.enumerated() {
                // Buitenste cirkel
                let outer = UIBezierPath(arcCenter: pt, radius: 14, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.white.withAlphaComponent(0.25).setFill()
                outer.fill()
                
                // Middenste ring
                let mid = UIBezierPath(arcCenter: pt, radius: 8, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.systemCyan.setFill()
                mid.fill()
                
                // Binnenste kern
                let inner = UIBezierPath(arcCenter: pt, radius: 4, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.white.setFill()
                inner.fill()

                // Hoekpunt label [P1], [P2], etc.
                let pLabel = "P\(idx + 1)" as NSString
                let pAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                pLabel.draw(at: CGPoint(x: pt.x + 16, y: pt.y - 6), withAttributes: pAttrs)
            }
        } else {
            // Rustige, discrete tactische indicatiedots tijdens bewaking
            for pt in screenPoints {
                let outer = UIBezierPath(arcCenter: pt, radius: 4.5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.systemCyan.withAlphaComponent(0.6).setFill()
                outer.fill()
                let dot = UIBezierPath(arcCenter: pt, radius: 2.5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.white.setFill()
                dot.fill()
            }
        }
    }
}

// MARK: - Netwerk & Systeem Hulpfuncties
struct NetworkInterfaceInfo {
    let name: String
    let ip: String
    let isWiFi: Bool
    let isVPN: Bool
    let isCellular: Bool
}

func getAllNetworkInterfaces() -> [NetworkInterfaceInfo] {
    var interfaces: [NetworkInterfaceInfo] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return interfaces }
    
    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let curr = ptr {
        defer { ptr = curr.pointee.ifa_next }
        let iface = curr.pointee
        guard let addr = iface.ifa_addr else { continue }
        
        let addrFamily = addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
            let name = String(cString: iface.ifa_name)
            if name == "lo0" { continue }
            
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if ip.isEmpty || ip == "127.0.0.1" { continue }
            
            let isVPN = name.starts(with: "utun") || name.starts(with: "ipsec") || name.starts(with: "ppp") || ip.starts(with: "100.")
            let isWiFi = name == "en0" || name.starts(with: "en")
            let isCellular = name.starts(with: "pdp_ip")
            
            interfaces.append(NetworkInterfaceInfo(name: name, ip: ip, isWiFi: isWiFi, isVPN: isVPN, isCellular: isCellular))
        }
    }
    freeifaddrs(firstAddr)
    
    interfaces.sort { a, b in
        if a.isVPN && !b.isVPN { return true }
        if !a.isVPN && b.isVPN { return false }
        if a.isWiFi && !b.isWiFi { return true }
        if !a.isWiFi && b.isWiFi { return false }
        return a.name < b.name
    }
    return interfaces
}

func getLocalIPAddress() -> String {
    let ifaces = getAllNetworkInterfaces()
    if let vpn = ifaces.first(where: { $0.isVPN }) { return vpn.ip }
    if let wifi = ifaces.first(where: { $0.isWiFi }) { return wifi.ip }
    if let first = ifaces.first { return first.ip }
    return "127.0.0.1"
}

func getFreeDiskSpaceGB() -> String {
    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
       let freeSize = attrs[.systemFreeSize] as? Int64 {
        let gb = Double(freeSize) / (1024 * 1024 * 1024)
        return String(format: "%.1f GB", gb)
    }
    return "Onbekend"
}

func calculateAverageLuminance(pixelBuffer: CVPixelBuffer) -> Float {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0, let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return Float(0.5) }
    
    let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    
    let sampleCols = 16
    let sampleRows = 16
    var totalLuma: Float = 0.0
    var count: Float = 0.0
    
    let stepX = max(1, width / sampleCols)
    let stepY = max(1, height / sampleRows)
    let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
    
    if pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB {
        for r in 0..<sampleRows {
            let y = min(height - 1, r * stepY)
            let rowStart = y * bytesPerRow
            for c in 0..<sampleCols {
                let x = min(width - 1, c * stepX)
                let offset = rowStart + (x * 4)
                let bVal = Float(buffer[offset])
                let gVal = Float(buffer[offset + 1])
                let rVal = Float(buffer[offset + 2])
                let luma = (Float(0.2126) * rVal + Float(0.7152) * gVal + Float(0.0722) * bVal) / Float(255.0)
                totalLuma += luma
                count += 1.0
            }
        }
    } else {
        for r in 0..<sampleRows {
            let y = min(height - 1, r * stepY)
            let rowStart = y * bytesPerRow
            for c in 0..<sampleCols {
                let x = min(width - 1, c * stepX)
                let yVal = Float(buffer[rowStart + x]) / Float(255.0)
                totalLuma += yVal
                count += 1.0
            }
        }
    }
    return count > 0.0 ? (totalLuma / count) : Float(0.5)
}

func createBoxOverlaySnapshot(cgImage: CGImage, points: [CGPoint], luma: Float, isNight: Bool) -> Data? {
    var finalCGImage = cgImage
    if isNight {
        let ci = CIImage(cgImage: cgImage)
        let filtered = ViewController.applyNightVisionFilter(to: ci)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        if let outputCG = ctx.createCGImage(filtered, from: filtered.extent) {
            finalCGImage = outputCG
        }
    }
    
    let size = CGSize(width: CGFloat(finalCGImage.width), height: CGFloat(finalCGImage.height))
    guard size.width > 0, size.height > 0 else { return nil }
    
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    
    return renderer.jpegData(withCompressionQuality: 0.78) { _ in
        let baseImg = UIImage(cgImage: finalCGImage)
        baseImg.draw(in: CGRect(origin: .zero, size: size))
        
        if points.count >= 3 {
            let path = UIBezierPath()
            let firstPt = CGPoint(x: points[0].x * size.width, y: points[0].y * size.height)
            path.move(to: firstPt)
            for p in points.dropFirst() {
                path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
            }
            path.close()
            
            UIColor(red: 0.0, green: 0.9, blue: 0.45, alpha: 0.25).setFill()
            path.fill()
            
            UIColor(red: 0.0, green: 0.95, blue: 0.5, alpha: 0.95).setStroke()
            path.lineWidth = max(4.0, size.width * 0.005)
            path.lineJoinStyle = .round
            path.stroke()
            
            for p in points {
                let center = CGPoint(x: p.x * size.width, y: p.y * size.height)
                let radius = max(10.0, size.width * 0.015)
                
                let outer = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.white.withAlphaComponent(0.9).setFill()
                outer.fill()
                
                let inner = UIBezierPath(arcCenter: center, radius: radius * 0.55, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor(red: 0.0, green: 0.85, blue: 0.4, alpha: 1.0).setFill()
                inner.fill()
            }
        }
    }
}

// MARK: - Ingebouwde Web Afstandsbediening Server (Network.framework)
class AutoCamWebServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "autocam.webserver.queue")
    static let defaultPort: UInt16 = 8081
    var port: UInt16 = AutoCamWebServer.defaultPort
    
    var accessKey: String = ""
    var onGetSnapshot: (() -> Data?)?
    var onGetStatus: (() -> [String: Any])?
    var onSaveBox: (([[CGFloat]]) -> [CGPoint])?
    var onToggleArm: (() -> Bool)?
    var onAutoDetect: (() -> [CGPoint])?
    var onResetBox: (() -> [CGPoint])?
    var onSetNightMode: ((String) -> Void)?
    var onToggleScreen: (() -> Bool)?
    
    func start() {
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
                    print("🌐 AutoCam Web Remote actief op poort \(self.port)")
                case .failed(let error):
                    print("❌ AutoCam Web Server fout: \(error)")
                default:
                    break
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: queue)
        } catch {
            print("Kon NWListener niet starten: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(connection: connection, accumulated: Data())
    }
    
    private func receiveData(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] (data, _, isComplete, error) in
            guard let self = self else { return }
            var currentData = accumulated
            if let data = data, !data.isEmpty {
                currentData.append(data)
            }
            
            if let range = currentData.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = currentData.subdata(in: 0..<range.lowerBound)
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    var contentLength = 0
                    for line in headerStr.components(separatedBy: "\r\n") {
                        if line.lowercased().starts(with: "content-length:") {
                            let parts = line.components(separatedBy: ":")
                            if parts.count >= 2 {
                                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                            }
                        }
                    }
                    let bodyStart = range.upperBound
                    let bodyLength = currentData.count - bodyStart
                    if bodyLength >= contentLength {
                        let bodyData = currentData.subdata(in: bodyStart..<(bodyStart + contentLength))
                        self.processRequest(header: headerStr, body: bodyData, connection: connection)
                        return
                    }
                }
            }
            
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveData(connection: connection, accumulated: currentData)
            }
        }
    }
    
    private func processRequest(header: String, body: Data, connection: NWConnection) {
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: 400, statusText: "Bad Request", type: "text/plain", data: Data())
            return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, statusText: "Bad Request", type: "text/plain", data: Data())
            return
        }
        let method = parts[0].uppercased()
        let fullPath = parts[1]
        
        let pathComponents = fullPath.components(separatedBy: "?")
        let path = pathComponents.first ?? fullPath
        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            for item in pathComponents[1].components(separatedBy: "&") {
                let kv = item.components(separatedBy: "=")
                if kv.count == 2 {
                    queryParams[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }
        
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }
        
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "text/plain", data: Data())
            return
        }
        
        // PIN / Toegangssleutel Validatie
        var isAuthorized = false
        var setAuthCookie = false
        if accessKey.isEmpty {
            isAuthorized = true
        } else {
            if let key = queryParams["key"], key == accessKey {
                isAuthorized = true
                setAuthCookie = true
            } else if let pin = queryParams["pin"], pin == accessKey {
                isAuthorized = true
                setAuthCookie = true
            } else if let authHeader = headers["x-access-key"] ?? headers["x-access-pin"], authHeader == accessKey {
                isAuthorized = true
            } else if let cookieHeader = headers["cookie"] {
                for cookie in cookieHeader.components(separatedBy: ";") {
                    let cParts = cookie.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
                    if cParts.count == 2 && (cParts[0] == "autocam_pin" || cParts[0] == "key") && cParts[1] == accessKey {
                        isAuthorized = true
                        break
                    }
                }
            }
        }
        
        if method == "POST" && path == "/api/verify" {
            var pin = ""
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let p = json["pin"] as? String {
                pin = p.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !accessKey.isEmpty && pin == accessKey {
                let respData = Data("{\"success\":true}".utf8)
                let extraHeaders = "Set-Cookie: autocam_pin=\(accessKey); Path=/; Max-Age=2592000; SameSite=Lax\r\n"
                sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: respData, cacheable: false, extraHeaders: extraHeaders)
            } else if accessKey.isEmpty {
                let respData = Data("{\"success\":true}".utf8)
                sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: respData, cacheable: false)
            } else {
                let respData = Data("{\"success\":false,\"error\":\"Onjuiste PIN\"}".utf8)
                sendResponse(connection: connection, status: 401, statusText: "Unauthorized", type: "application/json", data: respData, cacheable: false)
            }
            return
        }
        
        if method == "GET" && path == "/" {
            let html = AutoCamWebServer.htmlUI
            var extraHeaders = ""
            if isAuthorized && setAuthCookie {
                extraHeaders = "Set-Cookie: autocam_pin=\(accessKey); Path=/; Max-Age=2592000; SameSite=Lax\r\n"
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
                sendResponse(connection: connection, status: 503, statusText: "Service Unavailable", type: "text/plain", data: Data("Camera warming up".utf8), cacheable: false)
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
        
        if method == "POST" && path == "/api/autodetect" {
            let pts = onAutoDetect?() ?? []
            let resp: [String: Any] = ["success": true, "points": pts.map { [$0.x, $0.y] }]
            let json = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data("{}".utf8)
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: json, cacheable: false)
            return
        }
        
        if method == "POST" && path == "/api/resetbox" {
            let pts = onResetBox?() ?? []
            let resp: [String: Any] = ["success": true, "points": pts.map { [$0.x, $0.y] }]
            let json = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data("{}".utf8)
            sendResponse(connection: connection, status: 200, statusText: "OK", type: "application/json", data: json, cacheable: false)
            return
        }
        
        if method == "POST" && path == "/api/setnightmode" {
            var mode = "auto"
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let m = json["mode"] as? String {
                mode = m
            }
            onSetNightMode?(mode)
            var dict = onGetStatus?() ?? [:]
            dict["nightMode"] = mode
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
    
    static let htmlUI = #"""
<!DOCTYPE html>
<html lang="nl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>AutoCam Remote</title>
<style>
  :root {
    --bg: #07090e;
    --card: rgba(18, 24, 34, 0.78);
    --card-border: rgba(255, 255, 255, 0.08);
    --accent: #00e676;
    --accent-glow: rgba(0, 230, 118, 0.35);
    --danger: #ff453a;
    --blue: #0a84ff;
    --text: #f5f7fa;
    --text-muted: #8b949e;
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body {
    margin: 0; padding: 14px;
    background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    display: flex; flex-direction: column; align-items: center;
    min-height: 100vh;
  }
  .app-container {
    width: 100%; max-width: 540px;
    display: flex; flex-direction: column; gap: 12px;
  }
  .header {
    display: flex; justify-content: space-between; align-items: center;
    padding: 4px 6px;
  }
  .title {
    font-size: 21px; font-weight: 800; letter-spacing: -0.6px;
    display: flex; align-items: center; gap: 8px;
  }
  .badge {
    padding: 6px 14px; border-radius: 20px; font-size: 11px; font-weight: 800;
    letter-spacing: 0.6px; text-transform: uppercase;
    display: flex; align-items: center; gap: 6px;
    backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
  }
  .badge-armed { background: rgba(0, 230, 118, 0.16); color: var(--accent); border: 1px solid var(--accent); }
  .badge-standby { background: rgba(255, 159, 10, 0.16); color: #ff9f0a; border: 1px solid rgba(255, 159, 10, 0.5); }
  .badge-dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor; }

  .metrics-bar {
    display: flex; gap: 6px; width: 100%;
  }
  .metric-pill {
    flex: 1; background: var(--card); border: 1px solid var(--card-border);
    backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
    border-radius: 12px; padding: 7px 10px; font-size: 11px; font-weight: 600;
    text-align: center; color: var(--text-muted);
  }
  .metric-pill strong { color: var(--text); display: block; font-size: 12px; }

  .stream-card {
    width: 100%; background: #000; border-radius: 22px; overflow: hidden;
    position: relative; box-shadow: 0 16px 40px rgba(0,0,0,0.6);
    border: 1px solid var(--card-border);
    touch-action: none; user-select: none; -webkit-user-select: none;
    line-height: 0;
  }
  #streamImg {
    width: 100%; height: auto; display: block;
    background: #000;
  }
  #overlayCanvas {
    position: absolute; top: 0; left: 0; width: 100%; height: 100%;
    touch-action: none; cursor: crosshair;
  }
  .stream-tag {
    position: absolute; top: 12px; left: 12px;
    background: rgba(0, 0, 0, 0.65); backdrop-filter: blur(10px);
    border: 1px solid rgba(255,255,255,0.15); border-radius: 12px;
    padding: 4px 10px; font-size: 11px; font-weight: 700; color: #fff;
    display: flex; align-items: center; gap: 6px; pointer-events: none;
  }
  .live-dot { width: 7px; height: 7px; border-radius: 50%; background: #ff453a; animation: pulse 1.6s infinite; }
  @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }

  .stream-action-tag {
    position: absolute; top: 12px; right: 12px;
    background: rgba(0, 0, 0, 0.65); backdrop-filter: blur(10px);
    border: 1px solid rgba(255,255,255,0.15); border-radius: 12px;
    padding: 4px 10px; font-size: 11px; font-weight: 600; color: #aaa;
    pointer-events: none;
  }

  .panel-card {
    background: var(--card); border: 1px solid var(--card-border);
    backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
    border-radius: 20px; padding: 14px; display: flex; flex-direction: column; gap: 10px;
  }
  .section-label {
    font-size: 11px; font-weight: 800; letter-spacing: 0.6px;
    text-transform: uppercase; color: var(--text-muted); margin-bottom: 2px;
  }
  .btn-row { display: flex; gap: 8px; width: 100%; }
  
  button {
    flex: 1; padding: 13px 14px; border-radius: 14px; border: none;
    font-size: 13.5px; font-weight: 700; cursor: pointer;
    display: flex; align-items: center; justify-content: center; gap: 7px;
    transition: all 0.12s ease;
  }
  button:active { transform: scale(0.97); opacity: 0.85; }
  
  .btn-arm { background: var(--accent); color: #000; box-shadow: 0 4px 18px var(--accent-glow); }
  .btn-disarm { background: var(--danger); color: #fff; box-shadow: 0 4px 18px rgba(255,69,58,0.35); }
  .btn-secondary { background: rgba(255, 255, 255, 0.08); color: #fff; border: 1px solid var(--card-border); }
  .btn-primary { background: var(--blue); color: #fff; }
  
  .seg-control {
    display: flex; background: rgba(0, 0, 0, 0.4); border-radius: 12px; padding: 3px; gap: 3px;
    border: 1px solid var(--card-border);
  }
  .seg-btn {
    flex: 1; padding: 8px 10px; border-radius: 9px; font-size: 12px; font-weight: 700;
    background: transparent; color: var(--text-muted); border: none;
  }
  .seg-btn.active {
    background: rgba(255, 255, 255, 0.16); color: #fff;
  }

  .hint {
    font-size: 11.5px; color: var(--text-muted); text-align: center; line-height: 1.45;
  }
  .toast {
    position: fixed; bottom: 24px; background: rgba(0,230,118,0.96); color: #000;
    padding: 10px 22px; border-radius: 24px; font-weight: 800; font-size: 13px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.5); opacity: 0; pointer-events: none; transition: opacity 0.25s, transform 0.25s;
    transform: translateY(10px); z-index: 1000;
  }
  .toast.show { opacity: 1; transform: translateY(0); }

  /* PIN Gate Modal */
  .modal-overlay {
    position: fixed; inset: 0; background: rgba(0, 0, 0, 0.88); backdrop-filter: blur(14px);
    display: none; align-items: center; justify-content: center; z-index: 2000; padding: 20px;
  }
  .modal-overlay.active { display: flex; }
  .modal-card {
    background: #151a24; border: 1px solid var(--card-border);
    border-radius: 24px; padding: 26px; width: 100%; max-width: 360px;
    box-shadow: 0 20px 50px rgba(0,0,0,0.8); text-align: center;
    display: flex; flex-direction: column; gap: 14px;
  }
  .modal-title { font-size: 20px; font-weight: 800; }
  .modal-desc { font-size: 13px; color: var(--text-muted); line-height: 1.4; }
  .pin-input {
    background: rgba(0, 0, 0, 0.4); border: 1px solid rgba(255,255,255,0.15);
    border-radius: 14px; padding: 14px; font-size: 24px; font-weight: 800;
    color: #fff; text-align: center; letter-spacing: 6px; outline: none;
    width: 100%;
  }
  .pin-input:focus { border-color: var(--accent); }
</style>
</head>
<body>
  <div class="app-container">
    <div class="header">
      <div class="title">🛡️ AutoCam Remote</div>
      <div id="statusBadge" class="badge badge-standby"><span class="badge-dot"></span><span id="statusText">STANDBY</span></div>
    </div>

    <div class="metrics-bar">
      <div class="metric-pill">FPS <strong id="metricFps">10 FPS</strong></div>
      <div class="metric-pill">FILTER <strong id="metricFilter">🛡️ SLIM</strong></div>
      <div class="metric-pill">NACHT <strong id="metricNight">AUTO</strong></div>
      <div class="metric-pill">ACCU <strong id="metricBattery">--%</strong></div>
    </div>

    <div class="stream-card" id="streamContainer">
      <img id="streamImg" alt="Live Camerabeeld" />
      <canvas id="overlayCanvas"></canvas>
      <div class="stream-tag"><span class="live-dot"></span> 10 FPS LIVE</div>
      <div class="stream-action-tag">📐 Sleep 4 hoeken</div>
    </div>

    <div class="panel-card">
      <div class="section-label">Hoofdbediening</div>
      <button id="armBtn" class="btn-arm" onclick="toggleArm()">▶ Start Bewaking</button>
      
      <div class="section-label" style="margin-top: 6px;">Bewakingszone Omlijning</div>
      <div class="btn-row">
        <button class="btn-primary" onclick="saveBox()">💾 Opslaan</button>
        <button class="btn-secondary" onclick="autoDetect()">🚗 Auto Box</button>
        <button class="btn-secondary" onclick="resetBox()">🔄 Reset</button>
      </div>

      <div class="section-label" style="margin-top: 6px;">Nachtmodus & Helderheid Booster</div>
      <div class="seg-control">
        <button id="nightAutoBtn" class="seg-btn active" onclick="setNightMode('auto')">🌙 Auto</button>
        <button id="nightOnBtn" class="seg-btn" onclick="setNightMode('on')">🔥 Aan (+1.8 EV)</button>
        <button id="nightOffBtn" class="seg-btn" onclick="setNightMode('off')">☀️ Uit</button>
      </div>

      <div class="section-label" style="margin-top: 6px;">Stealth & Accubesparing</div>
      <div class="btn-row">
        <button id="screenToggleBtn" class="btn-secondary" onclick="toggleScreen()">🕶️ Scherm 100% Zwart (OLED)</button>
      </div>

      <div class="hint">
        👉 Sleep de 4 hoekpunten direct op het beeld over je auto, of sleep het midden om de hele zone te verplaatsen.
      </div>
    </div>
  </div>

  <div id="toast" class="toast">Box opgeslagen!</div>

  <!-- PIN Modal -->
  <div id="pinModal" class="modal-overlay">
    <div class="modal-card">
      <div style="font-size: 36px;">🔒</div>
      <div class="modal-title">Toegang Beveiligd</div>
      <div class="modal-desc">Voer de 4-cijferige PIN van je AutoCam in om toegang te krijgen.</div>
      <input type="password" id="pinField" class="pin-input" maxlength="8" placeholder="••••" />
      <button class="btn-arm" onclick="submitPIN()">Ontgrendel</button>
    </div>
  </div>

  <script>
    let points = [ [0.18, 0.32], [0.82, 0.32], [0.82, 0.68], [0.18, 0.68] ];
    let isArmed = false;
    let activeCorner = -1;
    let isDraggingBox = false;
    let dragStart = { x: 0, y: 0 };
    let dragStartPoints = [];
    
    const canvas = document.getElementById('overlayCanvas');
    const ctx = canvas.getContext('2d');
    const img = document.getElementById('streamImg');

    function showToast(msg) {
      const t = document.getElementById('toast');
      t.innerText = msg;
      t.classList.add('show');
      setTimeout(() => t.classList.remove('show'), 2200);
    }

    function checkPINParam() {
      const urlParams = new URLSearchParams(window.location.search);
      const key = urlParams.get('key') || urlParams.get('pin');
      if (key) {
        document.cookie = `autocam_pin=${key}; path=/; max-age=2592000; SameSite=Lax`;
      }
    }
    checkPINParam();

    async function submitPIN() {
      const pin = document.getElementById('pinField').value;
      if (!pin) return;
      try {
        const res = await fetch('/api/verify', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ pin: pin })
        });
        const data = await res.json();
        if (data.success) {
          document.cookie = `autocam_pin=${pin}; path=/; max-age=2592000; SameSite=Lax`;
          document.getElementById('pinModal').classList.remove('active');
          showToast('✓ Toegang verleend!');
          loadStatus();
          refreshFrame();
        } else {
          alert('Onjuiste PIN code!');
        }
      } catch (e) {
        alert('Fout bij verifiëren');
      }
    }

    function resizeCanvas() {
      if (img.clientWidth > 0 && img.clientHeight > 0) {
        canvas.width = img.clientWidth;
        canvas.height = img.clientHeight;
        draw();
      }
    }
    window.addEventListener('resize', resizeCanvas);

    function draw() {
      const w = canvas.width;
      const h = canvas.height;
      if (!w || !h) return;
      ctx.clearRect(0, 0, w, h);

      if (points.length === 4) {
        ctx.beginPath();
        ctx.moveTo(points[0][0] * w, points[0][1] * h);
        for (let i = 1; i < 4; i++) {
          ctx.lineTo(points[i][0] * w, points[i][1] * h);
        }
        ctx.closePath();
        ctx.fillStyle = isArmed ? "rgba(0, 230, 118, 0.22)" : "rgba(0, 230, 118, 0.28)";
        ctx.fill();
        ctx.lineWidth = 3;
        ctx.strokeStyle = "#00e676";
        ctx.stroke();

        for (let i = 0; i < 4; i++) {
          const px = points[i][0] * w;
          const py = points[i][1] * h;

          ctx.beginPath();
          ctx.arc(px, py, 18, 0, Math.PI * 2);
          ctx.fillStyle = "rgba(255, 255, 255, 0.32)";
          ctx.fill();

          ctx.beginPath();
          ctx.arc(px, py, 11, 0, Math.PI * 2);
          ctx.fillStyle = "#ffffff";
          ctx.fill();

          ctx.beginPath();
          ctx.arc(px, py, 6, 0, Math.PI * 2);
          ctx.fillStyle = "#00e676";
          ctx.fill();
        }
      }
    }

    function getCanvasCoords(e) {
      const rect = canvas.getBoundingClientRect();
      const clientX = e.touches ? e.touches[0].clientX : e.clientX;
      const clientY = e.touches ? e.touches[0].clientY : e.clientY;
      const x = clientX - rect.left;
      const y = clientY - rect.top;
      return {
        x: x,
        y: y,
        normX: Math.max(0.01, Math.min(0.99, x / rect.width)),
        normY: Math.max(0.01, Math.min(0.99, y / rect.height))
      };
    }

    function pointInPoly(pt, poly) {
      let inside = false;
      for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
        let xi = poly[i][0], yi = poly[i][1];
        let xj = poly[j][0], yj = poly[j][1];
        let intersect = ((yi > pt[1]) !== (yj > pt[1])) && (pt[0] < (xj - xi) * (pt[1] - yi) / (yj - yi) + xi);
        if (intersect) inside = !inside;
      }
      return inside;
    }

    function handleStart(e) {
      e.preventDefault();
      const pos = getCanvasCoords(e);
      const w = canvas.width, h = canvas.height;
      activeCorner = -1;
      isDraggingBox = false;

      for (let i = 0; i < 4; i++) {
        const cx = points[i][0] * w;
        const cy = points[i][1] * h;
        const dist = Math.hypot(pos.x - cx, pos.y - cy);
        if (dist < 36) {
          activeCorner = i;
          break;
        }
      }

      if (activeCorner === -1 && pointInPoly([pos.normX, pos.normY], points)) {
        isDraggingBox = true;
        dragStart = { x: pos.normX, y: pos.normY };
        dragStartPoints = JSON.parse(JSON.stringify(points));
      }
    }

    function handleMove(e) {
      if (activeCorner === -1 && !isDraggingBox) return;
      e.preventDefault();
      const pos = getCanvasCoords(e);

      if (activeCorner !== -1) {
        points[activeCorner] = [pos.normX, pos.normY];
        draw();
      } else if (isDraggingBox) {
        const dx = pos.normX - dragStart.x;
        const dy = pos.normY - dragStart.y;
        let newPts = [];
        let ok = true;
        for (let p of dragStartPoints) {
          let nx = p[0] + dx;
          let ny = p[1] + dy;
          if (nx < 0.01 || nx > 0.99 || ny < 0.01 || ny > 0.99) { ok = false; break; }
          newPts.push([nx, ny]);
        }
        if (ok) {
          points = newPts;
          draw();
        }
      }
    }

    function handleEnd(e) {
      if (activeCorner !== -1 || isDraggingBox) {
        activeCorner = -1;
        isDraggingBox = false;
        saveBox();
      }
    }

    canvas.addEventListener('touchstart', handleStart, { passive: false });
    canvas.addEventListener('touchmove', handleMove, { passive: false });
    canvas.addEventListener('touchend', handleEnd);
    canvas.addEventListener('mousedown', handleStart);
    canvas.addEventListener('mousemove', handleMove);
    canvas.addEventListener('mouseup', handleEnd);

    function refreshFrame() {
      const next = new Image();
      next.onload = () => {
        img.src = next.src;
        resizeCanvas();
        setTimeout(refreshFrame, 320);
      };
      next.onerror = () => {
        setTimeout(refreshFrame, 1500);
      };
      next.src = '/snapshot?t=' + Date.now();
    }
    refreshFrame();

    async function loadStatus() {
      try {
        const res = await fetch('/api/status');
        if (res.status === 401) {
          document.getElementById('pinModal').classList.add('active');
          return;
        }
        const data = await res.json();
        isArmed = data.isArmed;
        if (data.points && data.points.length === 4) {
          points = data.points;
        }
        updateStatusUI(data);
        draw();
      } catch (e) {
        console.error(e);
      }
    }

    function updateStatusUI(data) {
      const badge = document.getElementById('statusBadge');
      const text = document.getElementById('statusText');
      const armBtn = document.getElementById('armBtn');
      const bat = document.getElementById('metricBattery');
      const fps = document.getElementById('metricFps');
      const night = document.getElementById('metricNight');
      const screen = document.getElementById('metricScreen');
      const screenBtn = document.getElementById('screenToggleBtn');

      if (data.battery !== undefined) {
        bat.innerText = `${data.battery}% ${data.isCharging ? '⚡' : ''}`;
      }
      if (data.fps !== undefined) {
        fps.innerText = `${data.fps} FPS`;
      }
      const filter = document.getElementById('metricFilter');
      if (filter && data.filteredNoiseCount !== undefined) {
        filter.innerText = `🛡️ ${data.filteredNoiseCount}x`;
      }
      if (data.nightMode !== undefined) {
        const isBoost = data.isNightBoostActive ? ' 🔥' : '';
        night.innerText = `${data.nightMode.toUpperCase()}${isBoost}`;
        document.getElementById('nightAutoBtn').className = 'seg-btn' + (data.nightMode === 'auto' ? ' active' : '');
        document.getElementById('nightOnBtn').className = 'seg-btn' + (data.nightMode === 'on' ? ' active' : '');
        document.getElementById('nightOffBtn').className = 'seg-btn' + (data.nightMode === 'off' ? ' active' : '');
      }
      if (data.isScreenBlack !== undefined) {
        screen.innerText = data.isScreenBlack ? 'OLED ZWART' : 'AAN';
        screenBtn.innerText = data.isScreenBlack ? '💡 Scherm Verlichten' : '🕶️ Scherm 100% Zwart (OLED)';
      }

      if (data.isArmed) {
        badge.className = 'badge badge-armed';
        text.innerText = 'BEWAKING ACTIEF';
        armBtn.className = 'btn-disarm';
        armBtn.innerText = '⏹ Stop Bewaking';
      } else {
        badge.className = 'badge badge-standby';
        text.innerText = 'STANDBY';
        armBtn.className = 'btn-arm';
        armBtn.innerText = '▶ Start Bewaking';
      }
    }

    async function toggleArm() {
      try {
        const res = await fetch('/api/togglearm', { method: 'POST' });
        const data = await res.json();
        updateStatusUI(data);
        showToast(data.isArmed ? '🟢 Bewaking Geactiveerd!' : '⚪ Bewaking Gepauzeerd');
      } catch (e) {
        showToast('Fout bij schakelen');
      }
    }

    async function saveBox() {
      try {
        await fetch('/api/box', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ points: points })
        });
        showToast('✓ Box Opgeslagen!');
      } catch (e) {
        showToast('Opslaan mislukt');
      }
    }

    async function autoDetect() {
      try {
        showToast('🔍 Auto detecteren...');
        const res = await fetch('/api/autodetect', { method: 'POST' });
        const data = await res.json();
        if (data.points) {
          points = data.points;
          draw();
          showToast('✓ Auto omlijnd!');
        }
      } catch (e) {
        showToast('Detectie mislukt');
      }
    }

    async function resetBox() {
      try {
        const res = await fetch('/api/resetbox', { method: 'POST' });
        const data = await res.json();
        if (data.points) {
          points = data.points;
          draw();
          showToast('Box hersteld naar standaard');
        }
      } catch (e) {
        showToast('Reset mislukt');
      }
    }

    async function setNightMode(mode) {
      try {
        const res = await fetch('/api/setnightmode', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ mode: mode })
        });
        const data = await res.json();
        updateStatusUI(data);
        showToast(`Nachtmodus: ${mode.toUpperCase()}`);
      } catch (e) {
        showToast('Fout bij instellen');
      }
    }

    async function toggleScreen() {
      try {
        const res = await fetch('/api/togglescreen', { method: 'POST' });
        const data = await res.json();
        updateStatusUI(data);
        showToast(data.isScreenBlack ? '🕶️ OLED Scherm Zwart' : '💡 Scherm Aan');
      } catch (e) {
        showToast('Fout bij schakelen');
      }
    }

    loadStatus();
    setInterval(loadStatus, 3500);
  </script>
</body>
</html>
"""#
}

// MARK: - Telegram Bot Tweerichtings-Commando Listener (Long Polling)
class TelegramBotCommandListener {
    var botToken: String = ""
    var chatId: String = ""
    private var lastUpdateId: Int = 0
    private var isRunning = false
    private var currentTask: URLSessionDataTask?
    
    var onArm: (() -> Void)?
    var onDisarm: (() -> Void)?
    var onSnapshotRequested: ((@escaping (Data?) -> Void) -> Void)?
    var onBoxOverlayRequested: ((@escaping (Data?) -> Void) -> Void)?
    var onStatusRequested: (() -> [String: Any])?
    var onWebUrlRequested: (() -> String)?
    var onResetBox: (() -> Void)?
    var onAutoDetectBox: (() -> [CGPoint])?
    var onAdjustBox: ((_ dx: CGFloat, _ dy: CGFloat, _ scale: CGFloat) -> [CGPoint])?
    var onNightMode: ((String) -> Void)?
    var onScreenToggle: ((Bool) -> Void)?
    var onSetPIN: ((String) -> Void)?
    
    var boxKeyboard: [String: Any] {
        return [
            "inline_keyboard": [
                [
                    ["text": "⬆️ Boven", "callback_data": "box:up"]
                ],
                [
                    ["text": "⬅️ Links", "callback_data": "box:left"],
                    ["text": "➡️ Rechts", "callback_data": "box:right"]
                ],
                [
                    ["text": "⬇️ Onder", "callback_data": "box:down"]
                ],
                [
                    ["text": "➕ Groter", "callback_data": "box:bigger"],
                    ["text": "➖ Kleiner", "callback_data": "box:smaller"]
                ],
                [
                    ["text": "🚗 Auto Box", "callback_data": "box:auto"],
                    ["text": "🔄 Reset", "callback_data": "box:reset"]
                ]
            ]
        ]
    }
    
    func start() {
        guard !isRunning, !botToken.isEmpty else { return }
        isRunning = true
        poll()
    }
    
    func stop() {
        isRunning = false
        currentTask?.cancel()
        currentTask = nil
    }
    
    private func poll() {
        guard isRunning, !botToken.isEmpty else { return }
        let urlStr = "https://api.telegram.org/bot\(botToken)/getUpdates?offset=\(lastUpdateId + 1)&timeout=20"
        guard let url = URL(string: urlStr) else { return }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        
        currentTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, self.isRunning else { return }
            
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["result"] as? [[String: Any]] {
                
                for update in results {
                    if let updateId = update["update_id"] as? Int {
                        self.lastUpdateId = max(self.lastUpdateId, updateId)
                    }
                    
                    if let cb = update["callback_query"] as? [String: Any],
                       let queryId = cb["id"] as? String,
                       let dataStr = cb["data"] as? String {
                        let from = cb["from"] as? [String: Any]
                        let fromId = "\(from?["id"] ?? "")"
                        if self.chatId.isEmpty {
                            self.chatId = fromId
                            UserDefaults.standard.set(fromId, forKey: "tg_chat_id")
                        }
                        if fromId == self.chatId || self.chatId.isEmpty {
                            self.handleCallbackQuery(id: queryId, data: dataStr)
                        }
                    } else if let message = update["message"] as? [String: Any],
                       let text = message["text"] as? String,
                       let chat = message["chat"] as? [String: Any] {
                        
                        let senderId = "\(chat["id"] ?? "")"
                        if self.chatId.isEmpty {
                            self.chatId = senderId
                            UserDefaults.standard.set(senderId, forKey: "tg_chat_id")
                        }
                        
                        if senderId == self.chatId {
                            self.executeCommand(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
            }
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.poll()
            }
        }
        currentTask?.resume()
    }
    
    private func handleCallbackQuery(id: String, data: String) {
        answerCallbackQuery(id: id)
        
        switch data {
        case "box:up":
            _ = onAdjustBox?(0, -0.05, 1.0)
        case "box:down":
            _ = onAdjustBox?(0, 0.05, 1.0)
        case "box:left":
            _ = onAdjustBox?(-0.05, 0, 1.0)
        case "box:right":
            _ = onAdjustBox?(0.05, 0, 1.0)
        case "box:bigger":
            _ = onAdjustBox?(0, 0, 1.10)
        case "box:smaller":
            _ = onAdjustBox?(0, 0, 0.90)
        case "box:auto":
            _ = onAutoDetectBox?()
        case "box:reset":
            onResetBox?()
        default:
            break
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.onBoxOverlayRequested? { [weak self] jpegData in
                guard let self = self, let data = jpegData else { return }
                self.sendPhoto(jpegData: data,
                               caption: "📐 *Bewakingszone Aangepast*\nGebruik de knoppen om de box verder te verplaatsen:",
                               replyMarkup: self.boxKeyboard)
            }
        }
    }
    
    func answerCallbackQuery(id: String, text: String? = nil) {
        guard !botToken.isEmpty else { return }
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/answerCallbackQuery") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["callback_query_id": id]
        if let text = text {
            payload["text"] = text
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
    
    private func executeCommand(_ cmd: String) {
        let lower = cmd.lowercased()
        
        if lower.hasPrefix("/start") || lower.hasPrefix("/arm") || lower == "start" || lower == "arm" {
            DispatchQueue.main.async { self.onArm?() }
            sendReply("🟢 *Bewaking geactiveerd* (10 FPS)")
        } else if lower.hasPrefix("/stop") || lower.hasPrefix("/disarm") || lower == "stop" || lower == "disarm" {
            DispatchQueue.main.async { self.onDisarm?() }
            sendReply("⚪ *Bewaking gepauzeerd*")
        } else if lower.hasPrefix("/foto") || lower.hasPrefix("/snap") || lower.hasPrefix("/photo") || lower == "foto" {
            onSnapshotRequested? { [weak self] jpegData in
                guard let self = self, let data = jpegData else {
                    self?.sendReply("⚠️ Camera snapshot niet beschikbaar.")
                    return
                }
                let df = DateFormatter()
                df.dateFormat = "dd-MM-yyyy HH:mm:ss"
                let dateStr = df.string(from: Date())
                self.sendPhoto(jpegData: data, caption: "📸 *Live Camerabeeld* (\(dateStr))")
            }
        } else if lower.hasPrefix("/box") {
            let parts = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let sub = parts.count > 1 ? parts[1] : ""
            
            if sub == "up" || sub == "boven" {
                _ = onAdjustBox?(0, -0.05, 1.0)
            } else if sub == "down" || sub == "onder" {
                _ = onAdjustBox?(0, 0.05, 1.0)
            } else if sub == "left" || sub == "links" {
                _ = onAdjustBox?(-0.05, 0, 1.0)
            } else if sub == "right" || sub == "rechts" {
                _ = onAdjustBox?(0.05, 0, 1.0)
            } else if sub == "bigger" || sub == "groter" {
                _ = onAdjustBox?(0, 0, 1.10)
            } else if sub == "smaller" || sub == "kleiner" {
                _ = onAdjustBox?(0, 0, 0.90)
            } else if sub == "auto" {
                _ = onAutoDetectBox?()
            } else if sub == "reset" {
                onResetBox?()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self else { return }
                self.onBoxOverlayRequested? { [weak self] jpegData in
                    guard let self = self, let data = jpegData else {
                        self?.sendReply("⚠️ Kon box overlay niet genereren.")
                        return
                    }
                    self.sendPhoto(jpegData: data,
                                   caption: "📐 *Bewakingszone*\nGebruik onderstaande knoppen om de box te verschuiven:",
                                   replyMarkup: self.boxKeyboard)
                }
            }
        } else if lower.hasPrefix("/night") || lower.hasPrefix("/nacht") {
            if lower.contains("off") || lower.contains("uit") {
                DispatchQueue.main.async { self.onNightMode?("off") }
                sendReply("☀️ *Nachtmodus Handmatig UIT*")
            } else if lower.contains("on") || lower.contains("aan") {
                DispatchQueue.main.async { self.onNightMode?("on") }
                sendReply("🌙 *Nachtmodus Handmatig AAN* (+1.8 EV)")
            } else {
                DispatchQueue.main.async { self.onNightMode?("auto") }
                sendReply("🌗 *Nachtmodus op AUTO*")
            }
        } else if lower.hasPrefix("/screen") || lower.hasPrefix("/scherm") {
            if lower.contains("on") || lower.contains("aan") {
                DispatchQueue.main.async { self.onScreenToggle?(false) }
                sendReply("💡 *Scherm Verlicht*")
            } else {
                DispatchQueue.main.async { self.onScreenToggle?(true) }
                sendReply("🕶️ *Pitched OLED Scherm Zwart*")
            }
        } else if lower.hasPrefix("/pin") {
            let parts = cmd.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 2 {
                let newPin = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if newPin.count >= 4 {
                    DispatchQueue.main.async { self.onSetPIN?(newPin) }
                    sendReply("🔑 *Nieuwe Web PIN Ingesteld*: `\(newPin)`")
                } else {
                    sendReply("⚠️ De PIN moet minimaal 4 tekens lang zijn. Bijvoorbeeld: `/pin 4829`")
                }
            } else {
                sendReply("ℹ️ Gebruik `/pin <nieuwe_code>` om je toegangscode te wijzigen. Bijvoorbeeld: `/pin 5566`")
            }
        } else if lower.hasPrefix("/status") || lower == "status" {
            let status = onStatusRequested?() ?? [:]
            let isArmed = status["isArmed"] as? Bool ?? false
            let fps = status["fps"] as? Int ?? 10
            let nightMode = (status["nightMode"] as? String ?? "auto").uppercased()
            let isNightActive = status["isNightBoostActive"] as? Bool ?? false
            let isScreenBlack = status["isScreenBlack"] as? Bool ?? false
            let luma = status["luma"] as? Float ?? 0.0
            let battery = status["battery"] as? Int ?? 0
            let isCharging = status["isCharging"] as? Bool ?? false
            let disk = status["disk"] as? String ?? ""
            let noiseCount = status["filteredNoiseCount"] as? Int ?? 0
            let remoteLinks = onWebUrlRequested?() ?? ""
            
            let reply = """
            🛡️ *AutoCam Systeemstatus*
            • Bewaking: \(isArmed ? "🟢 ACTIEF" : "⚪ STANDBY")
            • Frame rate: ⚡ \(fps) FPS
            • AI Ruisfilter: 🛡️ ACTIEF (Boom-, Gordijn- & Reflectiefilter)
            • Valse meldingen genegeerd: 🍃 \(noiseCount)x gefilterd
            • Nachtmodus: 🌙 \(nightMode) \(isNightActive ? "(BOOSTER ACTIEF 🔥)" : "(Normaal)")
            • Omgevingslicht: 💡 \(String(format: "%.2f", luma)) luma
            • Scherm: \(isScreenBlack ? "🕶️ 100% OLED Zwart (Uit)" : "💡 Actief verlicht")
            • Batterij: 🔋 \(battery)% \(isCharging ? "⚡ (Aan de lader)" : "")
            • Vrije opslag: 💾 \(disk)
            
            🌐 *Web Afstandsbediening*:
            \(remoteLinks)
            """
            sendReply(reply)
        } else if lower.hasPrefix("/web") || lower.hasPrefix("/link") || lower == "web" {
            let remoteLinks = onWebUrlRequested?() ?? ""
            let reply = """
            🌐 *AutoCam Afstandsbediening*:
            
            \(remoteLinks)
            """
            sendReply(reply)
        } else if lower.hasPrefix("/reset") {
            DispatchQueue.main.async { self.onResetBox?() }
            sendReply("🔄 Bewakingsbox is hersteld naar standaardpositie.")
        } else {
            let reply = """
            🤖 *AutoCam Commando's*:
            • `/arm` of `/start` - Bewaking inschakelen (10 FPS)
            • `/disarm` of `/stop` - Bewaking uitschakelen
            • `/foto` - Live camerabeeld opvragen
            • `/box` - Zone bekijken & verplaatsen met interactieve knoppen
            • `/box [up|down|left|right|auto|reset]` - Box direct aanpassen
            • `/night [auto|on|off]` - Nachtmodus & Booster
            • `/screen [off|on]` - Scherm 100% pikzwart of aan
            • `/pin <code>` - Web PIN code instellen
            • `/status` - Batterij, FPS, nachtmodus & links
            • `/web` - Links voor Safari afstandsbediening
            """
            sendReply(reply)
        }
    }
    
    func sendReply(_ markdown: String, replyMarkup: [String: Any]? = nil) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "chat_id": chatId,
            "text": markdown,
            "parse_mode": "Markdown"
        ]
        if let replyMarkup = replyMarkup {
            payload["reply_markup"] = replyMarkup
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
    
    func sendPhoto(jpegData: Data, caption: String, replyMarkup: [String: Any]? = nil) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        let boundary = "Boundary-\(UUID().uuidString)"
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendPhoto") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n\(chatId)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n\(caption)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"parse_mode\"\r\n\r\nMarkdown\r\n".data(using: .utf8)!)
        
        if let replyMarkup = replyMarkup,
           let markupData = try? JSONSerialization.data(withJSONObject: replyMarkup),
           let markupStr = String(data: markupData, encoding: .utf8) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"reply_markup\"\r\n\r\n\(markupStr)\r\n".data(using: .utf8)!)
        }
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"live.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }
}
