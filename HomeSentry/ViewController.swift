import UIKit
import AVFoundation
import Vision
import Photos
import AVKit
import Network
import Darwin

// MARK: - Detectie Categorieën voor Thuisbeveiliging
public enum HomeDetectionCategory: String, CaseIterable, Codable {
    case person = "Persoon"
    case delivery = "Pakketje"
    case pet = "Huisdier"
    case emergencyAcoustic = "Noodalarm"
    case other = "Beweging"
    
    public var displayName: String {
        switch self {
        case .person: return "Persoon bij Voordeur"
        case .delivery: return "Pakketbezorger / Pakketje"
        case .pet: return "Huisdier"
        case .emergencyAcoustic: return "Akoestisch Noodalarm"
        case .other: return "Beweging in Hal"
        }
    }
    
    public var emoji: String {
        switch self {
        case .person: return "👤"
        case .delivery: return "📦"
        case .pet: return "🐾"
        case .emergencyAcoustic: return "🚨"
        case .other: return "🚪"
        }
    }
    
    public var folderName: String {
        return self.rawValue
    }
}

// MARK: - Hoofd View Controller voor HomeSentry
public class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {

    // MARK: - Camera & Vision Properties
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let visionQueue = DispatchQueue(label: "com.homesentry.vision.queue", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "com.homesentry.session.queue")
    
    // Bewegingsdetectie in de Voordeur-Zone
    private let motionDetector = ZoneMotionDetector()
    private var polygonPoints: [CGPoint] = []
    
    // Video Opname & Multi-Frame Incident Detectie
    private var isRecording = false
    private var recordingStartTime = Date.distantPast
    private var lastMotionTime = Date.distantPast
    private var recordingTimer: Timer?
    private let noMotionPostRollSeconds: TimeInterval = 3.5
    private let minRecordDuration: TimeInterval = 5.0
    private let maxRecordDuration: TimeInterval = 60.0
    
    private var firstIncidentFrame: CGImage?
    private var incidentKeyframes: [CGImage] = []
    private var lastKeyframeCaptureTime = Date.distantPast
    private var currentIncidentDate = Date()
    private var currentIncidentReason: HomeDetectionCategory? = nil
    
    // 2 Weken bewaartermijn
    private let retentionDurationSeconds: TimeInterval = 14 * 24 * 3600
    private var baseRecordingsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("HomeSentry_Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    // Bewakingsstatus
    private var isArmed = true
    private var isBlackScreenActive = false
    private var autoBlackScreenTimer: Timer?
    
    // Telegram & Toegangscode
    private var botToken: String {
        get { UserDefaults.standard.string(forKey: "hs_tg_bot_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "hs_tg_bot_token") }
    }
    private var chatId: String {
        get { UserDefaults.standard.string(forKey: "hs_tg_chat_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "hs_tg_chat_id") }
    }
    private var webAccessPIN: String {
        get { UserDefaults.standard.string(forKey: "hs_web_access_pin") ?? "1234" }
        set { UserDefaults.standard.set(newValue, forKey: "hs_web_access_pin") }
    }
    
    // Web Server & Telegram Listener
    private let webServer = WebDashboardServer.shared
    private let telegramListener = HomeSentryTelegramListener()
    
    // UI Elementen (Tactical CCTV HUD)
    private let canvasView = HomeDoorCanvasView()
    private let topBarView = UIView()
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let tempBadge = UILabel()
    private let pressureBadge = UILabel()
    private let soundBadge = UILabel()
    
    private let bottomControlBar = UIView()
    private let armBtn = UIButton(type: .system)
    private let zoneBtn = UIButton(type: .system)
    private let soundBtn = UIButton(type: .system)
    private let stealthBtn = UIButton(type: .system)
    private let clipsBtn = UIButton(type: .system)
    private let setupBtn = UIButton(type: .system)
    
    private let blackScreenOverlay = UIView()
    
    // Beeld Context & Telemetrie
    private let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    private var latestFrameCGImage: CGImage?
    private var lastStoredFrameTime = Date.distantPast
    
    // MARK: - Lifecycle
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        loadSavedPolygon()
        setupUI()
        setupCaptureSession()
        setupAcousticEngine()
        setupEnvironmentalEngine()
        setupRemoteServices()
        
        // Luister naar batterij en rotatie
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(screenTapped), name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        
        resetAutoBlackScreenTimer()
    }
    
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        canvasView.frame = view.bounds
        blackScreenOverlay.frame = view.bounds
    }
    
    public override var prefersStatusBarHidden: Bool {
        return true
    }
    
    public override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    // MARK: - Setup UI (Tactisch Cyber CCTV HUD)
    private func setupUI() {
        // Preview Layer Container
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer?.videoGravity = .resizeAspectFill
        if let p = previewLayer { view.layer.addSublayer(p) }
        
        // Zone Canvas View
        canvasView.previewLayer = previewLayer
        canvasView.points = self.polygonPoints
        canvasView.onPointsUpdated = { [weak self] pts in
            self?.polygonPoints = pts
            self?.savePolygon()
        }
        view.addSubview(canvasView)
        
        // Top HUD Bar
        topBarView.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 0.85)
        topBarView.layer.cornerRadius = 14
        topBarView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        topBarView.layer.borderWidth = 1
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBarView)
        
        statusDot.backgroundColor = .systemGreen
        statusDot.layer.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        topBarView.addSubview(statusDot)
        
        statusLabel.text = "HOMESENTRY • VOORDEUR BEWAKING"
        statusLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .bold)
        statusLabel.textColor = .white
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        topBarView.addSubview(statusLabel)
        
        tempBadge.text = "🌡️ 20.5°C"
        tempBadge.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        tempBadge.textColor = .systemCyan
        tempBadge.translatesAutoresizingMaskIntoConstraints = false
        topBarView.addSubview(tempBadge)
        
        pressureBadge.text = "🧭 1013 hPa"
        pressureBadge.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        pressureBadge.textColor = .systemTeal
        pressureBadge.translatesAutoresizingMaskIntoConstraints = false
        topBarView.addSubview(pressureBadge)
        
        soundBadge.text = "🎤 40 dB"
        soundBadge.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        soundBadge.textColor = .systemGreen
        soundBadge.translatesAutoresizingMaskIntoConstraints = false
        topBarView.addSubview(soundBadge)
        
        // Bottom Control Deck
        bottomControlBar.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 0.88)
        bottomControlBar.layer.cornerRadius = 18
        bottomControlBar.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        bottomControlBar.layer.borderWidth = 1
        bottomControlBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomControlBar)
        
        armBtn.setTitle("🟢 BEWAKING ACTIEF (STOP)", for: .normal)
        armBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .heavy)
        armBtn.setTitleColor(.white, for: .normal)
        armBtn.backgroundColor = UIColor(red: 0.05, green: 0.22, blue: 0.12, alpha: 0.95)
        armBtn.layer.cornerRadius = 10
        armBtn.layer.borderColor = UIColor.systemGreen.cgColor
        armBtn.layer.borderWidth = 1
        armBtn.addTarget(self, action: #selector(toggleArm), for: .touchUpInside)
        armBtn.translatesAutoresizingMaskIntoConstraints = false
        bottomControlBar.addSubview(armBtn)
        
        let buttonStack = UIStackView()
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        bottomControlBar.addSubview(buttonStack)
        
        setupDeckBtn(zoneBtn, title: "🚪 Zone", action: #selector(toggleZoneEdit))
        setupDeckBtn(soundBtn, title: "🔊 Audio", action: #selector(showAcousticLog))
        setupDeckBtn(stealthBtn, title: "🕶️ Zwart", action: #selector(enableBlackScreen))
        setupDeckBtn(clipsBtn, title: "🎬 Clips", action: #selector(showClipsMenu))
        setupDeckBtn(setupBtn, title: "⚙️ Setup", action: #selector(showSettings))
        
        buttonStack.addArrangedSubview(zoneBtn)
        buttonStack.addArrangedSubview(soundBtn)
        buttonStack.addArrangedSubview(stealthBtn)
        buttonStack.addArrangedSubview(clipsBtn)
        buttonStack.addArrangedSubview(setupBtn)
        
        // OLED Black Screen Overlay (voor stealth in het trapgat)
        blackScreenOverlay.backgroundColor = .black
        blackScreenOverlay.alpha = 0.0
        blackScreenOverlay.isUserInteractionEnabled = false
        view.addSubview(blackScreenOverlay)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(screenTapped))
        view.addGestureRecognizer(tapGesture)
        
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topBarView.heightAnchor.constraint(equalToConstant: 44),
            
            statusDot.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 12),
            statusDot.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
            
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            
            soundBadge.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor, constant: -12),
            soundBadge.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            
            pressureBadge.trailingAnchor.constraint(equalTo: soundBadge.leadingAnchor, constant: -10),
            pressureBadge.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            
            tempBadge.trailingAnchor.constraint(equalTo: pressureBadge.leadingAnchor, constant: -10),
            tempBadge.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            
            bottomControlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bottomControlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bottomControlBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bottomControlBar.heightAnchor.constraint(equalToConstant: 100),
            
            armBtn.topAnchor.constraint(equalTo: bottomControlBar.topAnchor, constant: 8),
            armBtn.leadingAnchor.constraint(equalTo: bottomControlBar.leadingAnchor, constant: 10),
            armBtn.trailingAnchor.constraint(equalTo: bottomControlBar.trailingAnchor, constant: -10),
            armBtn.heightAnchor.constraint(equalToConstant: 38),
            
            buttonStack.topAnchor.constraint(equalTo: armBtn.bottomAnchor, constant: 6),
            buttonStack.leadingAnchor.constraint(equalTo: bottomControlBar.leadingAnchor, constant: 10),
            buttonStack.trailingAnchor.constraint(equalTo: bottomControlBar.trailingAnchor, constant: -10),
            buttonStack.bottomAnchor.constraint(equalTo: bottomControlBar.bottomAnchor, constant: -8)
        ])
    }
    
    private func setupDeckBtn(_ btn: UIButton, title: String, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 0.85)
        btn.layer.cornerRadius = 8
        btn.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        btn.layer.borderWidth = 0.8
        btn.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - Camera Capture Setup (1080p, 15 FPS)
    private func setupCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .hd1920x1080
            
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                print("❌ [HomeSentry] Kon back camera niet vinden")
                self.captureSession.commitConfiguration()
                return
            }
            
            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }
            
            // Audio input
            if let audioDev = AVCaptureDevice.default(for: .audio),
               let audioIn = try? AVCaptureDeviceInput(device: audioDev),
               self.captureSession.canAddInput(audioIn) {
                self.captureSession.addInput(audioIn)
            }
            
            // Video Frame Analysis Output
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }
            
            // Movie File Output voor Video Incidenten
            if self.captureSession.canAddOutput(self.movieOutput) {
                self.captureSession.addOutput(self.movieOutput)
            }
            
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            print("📹 [HomeSentry] Camera actief gericht op de voordeur")
        }
    }
    
    // MARK: - Akoestische Engine Setup (Glas / Rookmelder / Water)
    private func setupAcousticEngine() {
        AcousticSentryEngine.shared.onAcousticEvent = { [weak self] entry in
            guard let self = self else { return }
            self.soundBadge.text = "🎤 \(Int(entry.decibels)) dB • \(entry.type.emoji)"
            if entry.decibels > 65.0 {
                self.soundBadge.textColor = entry.type.isEmergency ? .systemRed : .systemOrange
            } else {
                self.soundBadge.textColor = .systemGreen
            }
        }
        
        AcousticSentryEngine.shared.onEmergencyAlert = { [weak self] entry in
            guard let self = self else { return }
            self.handleEmergencyAcousticEvent(entry)
        }
        
        AcousticSentryEngine.shared.start()
    }
    
    // MARK: - Omgevings- en Barometer Setup
    private func setupEnvironmentalEngine() {
        EnvironmentalEngine.shared.onPressurePulse = { [weak self] diff in
            guard let self = self else { return }
            print("💨 [HomeSentry] Voordeur-tocht drukgolf: \(String(format: "%+.2f", diff)) hPa")
            self.statusLabel.text = "HOMESENTRY • TOCHT / VOORDEUR BEWEEGT"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if self.isArmed && !self.isRecording {
                    self.statusLabel.text = "HOMESENTRY • VOORDEUR BEWAKING"
                }
            }
        }
        EnvironmentalEngine.shared.start()
        
        // Timer voor UI badges
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let temp = EnvironmentalEngine.shared.estimatedRoomTemperatureC
            let press = EnvironmentalEngine.shared.pressureHPa
            let db = AcousticSentryEngine.shared.currentDecibels
            
            self.tempBadge.text = String(format: "🌡️ %.1f°C", temp)
            self.pressureBadge.text = String(format: "🧭 %.0f hPa", press)
            self.soundBadge.text = String(format: "🎤 %.0f dB", db)
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Frame Analyse)
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        
        // Sla periodiek een snapshot op voor Web Remote en Telegram
        if now.timeIntervalSince(lastStoredFrameTime) >= 0.10 {
            lastStoredFrameTime = now
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            self.latestFrameCGImage = self.sharedCIContext.createCGImage(ciImage, from: ciImage.extent)
        }
        
        guard isArmed else { return }
        
        let hasMotionInDoorZone = motionDetector.processFrame(pixelBuffer: pixelBuffer, polygon: self.polygonPoints)
        
        if hasMotionInDoorZone {
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
                    self.firstIncidentFrame = self.latestFrameCGImage
                    if let f = self.firstIncidentFrame { self.incidentKeyframes = [f] }
                    self.lastKeyframeCaptureTime = Date()
                    self.currentIncidentDate = Date()
                    self.currentIncidentReason = .person
                    self.startVideoRecording()
                }
            }
        } else {
            if isRecording {
                let timeSinceLast = now.timeIntervalSince(lastMotionTime)
                let totalDuration = now.timeIntervalSince(recordingStartTime)
                if (timeSinceLast >= noMotionPostRollSeconds && totalDuration >= minRecordDuration) || totalDuration >= maxRecordDuration {
                    DispatchQueue.main.async { [weak self] in
                        self?.stopVideoRecording()
                    }
                }
            }
        }
    }

    // MARK: - Video Opname
    private func startVideoRecording() {
        guard !movieOutput.isRecording else { return }
        
        let tempFolder = FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let tempURL = tempFolder.appendingPathComponent("HomeSentry_\(formatter.string(from: Date())).mp4")
        
        if let conn = movieOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        isRecording = true
        recordingStartTime = Date()
        lastMotionTime = Date()
        
        statusDot.backgroundColor = .systemRed
        statusLabel.text = "HOMESENTRY • INCIDENT OPNEMEN"
        armBtn.setTitle("🔴 OPNEMEN (0:00)", for: .normal)
        armBtn.backgroundColor = UIColor(red: 0.35, green: 0.05, blue: 0.08, alpha: 0.95)
        armBtn.layer.borderColor = UIColor.systemRed.cgColor
        
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.recordingStartTime))
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

    // MARK: - AVCaptureFileOutputRecordingDelegate (Opname Klaar -> AI Validatie)
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isRecording = false
            self.statusDot.backgroundColor = .systemOrange
            self.statusLabel.text = "HOMESENTRY • AI ANALYSEREN..."
            if self.isArmed {
                self.armBtn.setTitle("🟢 BEWAKING ACTIEF (STOP)", for: .normal)
                self.armBtn.backgroundColor = UIColor(red: 0.05, green: 0.22, blue: 0.12, alpha: 0.95)
                self.armBtn.layer.borderColor = UIColor.systemGreen.cgColor
            }
        }
        
        guard error == nil else {
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        
        let framesToAnalyze = self.incidentKeyframes.isEmpty ? [self.firstIncidentFrame].compactMap { $0 } : self.incidentKeyframes
        self.incidentKeyframes.removeAll()
        self.firstIncidentFrame = nil
        let incidentDate = self.currentIncidentDate
        let presetReason = self.currentIncidentReason
        self.currentIncidentReason = nil
        let currentPolygon = self.polygonPoints
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            self.classifyIncidentFrames(keyframes: framesToAnalyze, polygon: currentPolygon, fallbackReason: presetReason) { category in
                self.handleClassifiedIncident(videoURL: outputFileURL, category: category, incidentDate: incidentDate)
            }
        }
    }

    // MARK: - Vision AI Validatie (Persoon, Pakket, Huisdier of Ruis)
    private func classifyIncidentFrames(keyframes: [CGImage],
                                        polygon: [CGPoint],
                                        fallbackReason: HomeDetectionCategory?,
                                        completion: @escaping (HomeDetectionCategory?) -> Void) {
        if fallbackReason == .emergencyAcoustic {
            completion(.emergencyAcoustic)
            return
        }
        
        guard !keyframes.isEmpty else {
            completion(nil)
            return
        }
        
        var foundPerson = false
        var foundDelivery = false
        var foundPet = false
        
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
            // Mensendetectie
            let humanReq = VNDetectHumanRectanglesRequest { req, _ in
                if let obs = req.results as? [VNHumanObservation] {
                    for o in obs where o.confidence > 0.35 {
                        let box = CGRect(x: o.boundingBox.minX, y: 1.0 - o.boundingBox.maxY, width: o.boundingBox.width, height: o.boundingBox.height)
                        if box.intersects(polyRect) || polyRect.insetBy(dx: -0.12, dy: -0.12).intersects(box) {
                            foundPerson = true
                        }
                    }
                }
            }
            
            // Beeldinhoud (Pakketjes, Mensen, Dieren)
            let classReq = VNClassifyImageRequest { req, _ in
                guard let obs = req.results as? [VNClassificationObservation] else { return }
                for o in obs.prefix(20) where o.confidence > 0.14 {
                    let id = o.identifier.lowercased()
                    if id.contains("person") || id.contains("human") || id.contains("pedestrian") || id.contains("man") || id.contains("woman") {
                        foundPerson = true
                    } else if id.contains("box") || id.contains("package") || id.contains("parcel") || id.contains("delivery") || id.contains("carton") {
                        foundDelivery = true
                    } else if id.contains("cat") || id.contains("dog") || id.contains("pet") || id.contains("animal") {
                        foundPet = true
                    }
                }
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([humanReq, classReq])
            
            if foundPerson { break }
        }
        
        if foundPerson {
            completion(.person)
        } else if foundDelivery {
            completion(.delivery)
        } else if foundPet {
            completion(.pet)
        } else {
            // Geen duidelijke persoon of pakket -> filter ruis weg
            completion(nil)
        }
    }

    // MARK: - Afhandeling Incident & Telegram Verzending
    private func handleClassifiedIncident(videoURL: URL, category: HomeDetectionCategory?, incidentDate: Date) {
        guard let category = category else {
            // Valse beweging gefilterd
            try? FileManager.default.removeItem(at: videoURL)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.statusDot.backgroundColor = .systemTeal
                self.statusLabel.text = "HOMESENTRY • RUIS GEFILTERD"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.isArmed && !self.isRecording {
                        self.statusDot.backgroundColor = .systemGreen
                        self.statusLabel.text = "HOMESENTRY • VOORDEUR BEWAKING"
                    }
                }
            }
            return
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let baseName = "HomeSentry_\(formatter.string(from: incidentDate))"
        let targetFolder = baseRecordingsFolder.appendingPathComponent(category.folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: targetFolder.path) {
            try? FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        }
        
        let finalVideoURL = targetFolder.appendingPathComponent("\(baseName).mp4")
        try? FileManager.default.removeItem(at: finalVideoURL)
        try? FileManager.default.moveItem(at: videoURL, to: finalVideoURL)
        
        // Opslaan in Foto's
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: finalVideoURL)
        }, completionHandler: nil)
        
        // Telegram Video Sturen
        sendTelegramVideo(videoURL: finalVideoURL, category: category, date: incidentDate)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusDot.backgroundColor = .systemGreen
            self.statusLabel.text = "💾 [\(category.displayName)] bewaard"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if self.isArmed && !self.isRecording {
                    self.statusLabel.text = "HOMESENTRY • VOORDEUR BEWAKING"
                }
            }
        }
    }

    // MARK: - Akoestisch Noodalarm Afhandelen (Glasbreuk, Rookmelder, Waterlek)
    private func handleEmergencyAcousticEvent(_ entry: AcousticLogEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("🚨 [HomeSentry] NOODALARM: \(entry.type.displayName)")
            self.statusDot.backgroundColor = .systemRed
            self.statusLabel.text = "🚨 NOODALARM • \(entry.type.displayName.uppercased())"
            
            // Start direct een opname om te zien wat er beneden bij de voordeur gebeurt
            if !self.isRecording && self.isArmed {
                self.currentIncidentReason = .emergencyAcoustic
                self.currentIncidentDate = Date()
                self.firstIncidentFrame = self.latestFrameCGImage
                if let f = self.firstIncidentFrame { self.incidentKeyframes = [f] }
                self.startVideoRecording()
            }
            
            // Stuur onmiddellijk een spoed Telegram tekstbericht met sensorstatus
            self.sendEmergencyTelegramText(entry)
        }
    }
    
    // MARK: - Telegram Communicatie
    private func sendTelegramVideo(videoURL: URL, category: HomeDetectionCategory, date: Date) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        guard let data = try? Data(contentsOf: videoURL) else { return }
        
        let temp = EnvironmentalEngine.shared.estimatedRoomTemperatureC
        let press = EnvironmentalEngine.shared.pressureHPa
        let db = AcousticSentryEngine.shared.currentDecibels
        
        let caption = """
        \(category.emoji) *\(category.displayName)* gedetecteerd!
        📅 Tijd: \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium))
        🌡️ Temp: \(String(format: "%.1f°C", temp)) | 🧭 Druk: \(String(format: "%.0f hPa", press))
        🎤 Geluid: \(String(format: "%.0f dB", db))
        """
        
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendVideo")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n\(chatId)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"parse_mode\"\r\n\r\nMarkdown\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n\(caption)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"video.mp4\"\r\nContent-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        
        URLSession.shared.dataTask(with: req).resume()
    }
    
    private func sendEmergencyTelegramText(_ entry: AcousticLogEntry) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        
        let temp = EnvironmentalEngine.shared.estimatedRoomTemperatureC
        let press = EnvironmentalEngine.shared.pressureHPa
        
        let msg = """
        🚨 *HOMESENTRY SPOED NOODALARM!*
        ⚠️ Type: *\(entry.type.emoji) \(entry.type.displayName)*
        🔊 Volume: *\(Int(entry.decibels)) dB* (Zekerheid: \(Int(entry.confidence * 100))%)
        🌡️ Kamertemp: \(String(format: "%.1f°C", temp))
        🧭 Luchtdruk: \(String(format: "%.0f hPa", press))
        
        📹 *Video-opname van de voordeur is direct gestart en volgt zo snel mogelijk.*
        """
        
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": msg,
            "parse_mode": "Markdown"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - Remote Services (Web Remote & Telegram Commando's)
    private func setupRemoteServices() {
        webServer.accessKey = self.webAccessPIN
        webServer.onGetSnapshot = { [weak self] in
            guard let cg = self?.latestFrameCGImage else { return nil }
            return UIImage(cgImage: cg).jpegData(compressionQuality: 0.65)
        }
        webServer.onGetStatus = { [weak self] in
            return self?.getSystemStatusDict() ?? [:]
        }
        webServer.onSaveBox = { [weak self] pts in
            return self?.setPointsFromRemote(ptsArr: pts) ?? []
        }
        webServer.onToggleArm = { [weak self] in
            return self?.toggleArm() ?? false
        }
        webServer.onToggleScreen = { [weak self] in
            guard let self = self else { return false }
            if self.isBlackScreenActive { self.disableBlackScreen() } else { self.enableBlackScreen() }
            return self.isBlackScreenActive
        }
        webServer.onGetClips = { [weak self] in
            return self?.getAllClipsDict() ?? []
        }
        webServer.onGetVideoData = { [weak self] name in
            guard let self = self else { return nil }
            return self.getVideoDataByName(name)
        }
        webServer.start()
        
        // Telegram Bot Command Listener
        telegramListener.botToken = self.botToken
        telegramListener.chatId = self.chatId
        telegramListener.onArm = { [weak self] in self?.activateArmedMode() }
        telegramListener.onDisarm = { [weak self] in self?.deactivateArmedMode() }
        telegramListener.onStatusRequested = { [weak self] in self?.getSystemStatusDict() ?? [:] }
        telegramListener.onSnapshotRequested = { [weak self] completion in
            guard let cg = self?.latestFrameCGImage else { completion(nil); return }
            completion(UIImage(cgImage: cg).jpegData(compressionQuality: 0.70))
        }
        telegramListener.onAdjustBox = { [weak self] dx, dy, scale in
            return self?.adjustBox(deltaX: dx, deltaY: dy, scale: scale) ?? []
        }
        telegramListener.start()
    }
    
    private func getSystemStatusDict() -> [String: Any] {
        let temp = EnvironmentalEngine.shared.estimatedRoomTemperatureC
        let press = EnvironmentalEngine.shared.pressureHPa
        let trend = EnvironmentalEngine.shared.pressureTrend
        let isDraft = EnvironmentalEngine.shared.isDoorDraftPulseDetected
        let thermal = EnvironmentalEngine.shared.thermalStateString
        let db = AcousticSentryEngine.shared.currentDecibels
        let peakDb = AcousticSentryEngine.shared.peakDecibels
        let bat = Int(UIDevice.current.batteryLevel * 100)
        let isCharging = (UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full)
        let disk = getFreeDiskSpaceGB()
        let ip = getLocalIPAddress()
        let recent = AcousticSentryEngine.shared.recentEvents.map { [
            "type": $0.type.rawValue,
            "name": $0.type.displayName,
            "emoji": $0.type.emoji,
            "confidence": $0.confidence,
            "decibels": $0.decibels,
            "isEmergency": $0.type.isEmergency,
            "time": $0.timeString
        ]}
        
        return [
            "isArmed": isArmed,
            "fps": 15,
            "temperature": temp,
            "minTemp": EnvironmentalEngine.shared.minTempToday,
            "maxTemp": EnvironmentalEngine.shared.maxTempToday,
            "pressure": press,
            "pressureTrend": trend,
            "isDraftDetected": isDraft,
            "thermalState": thermal,
            "decibels": db,
            "peakDecibels": peakDb,
            "battery": bat >= 0 ? bat : 100,
            "isCharging": isCharging,
            "disk": disk,
            "ip": ip,
            "points": polygonPoints.map { [$0.x, $0.y] },
            "recentSounds": recent
        ]
    }
    
    // MARK: - Zone & Box Beheer
    private func savePolygon() {
        let arr = polygonPoints.map { [$0.x, $0.y] }
        UserDefaults.standard.set(arr, forKey: "hs_saved_polygon")
    }
    
    private func loadSavedPolygon() {
        if let arr = UserDefaults.standard.array(forKey: "hs_saved_polygon") as? [[CGFloat]], arr.count == 4 {
            polygonPoints = arr.map { CGPoint(x: $0[0], y: $0[1]) }
        } else {
            // Standaard Voordeur Rechthoek (gezien vanaf de trap)
            polygonPoints = [
                CGPoint(x: 0.20, y: 0.35),
                CGPoint(x: 0.80, y: 0.35),
                CGPoint(x: 0.80, y: 0.92),
                CGPoint(x: 0.20, y: 0.92)
            ]
        }
    }
    
    private func setPointsFromRemote(ptsArr: [[CGFloat]]) -> [CGPoint] {
        guard ptsArr.count == 4 else { return polygonPoints }
        let newPts = ptsArr.map { CGPoint(x: $0[0], y: $0[1]) }
        DispatchQueue.main.async {
            self.polygonPoints = newPts
            self.canvasView.points = newPts
            self.savePolygon()
        }
        return newPts
    }
    
    private func adjustBox(deltaX: CGFloat, deltaY: CGFloat, scale: CGFloat) -> [CGPoint] {
        guard polygonPoints.count == 4 else { return polygonPoints }
        var cx: CGFloat = 0, cy: CGFloat = 0
        for p in polygonPoints { cx += p.x; cy += p.y }
        cx /= 4.0; cy /= 4.0
        
        var newPts: [CGPoint] = []
        for p in polygonPoints {
            let sx = cx + (p.x - cx) * scale
            let sy = cy + (p.y - cy) * scale
            newPts.append(CGPoint(x: max(0.02, min(0.98, sx + deltaX)),
                                  y: max(0.02, min(0.98, sy + deltaY))))
        }
        DispatchQueue.main.async {
            self.polygonPoints = newPts
            self.canvasView.points = newPts
            self.savePolygon()
        }
        return newPts
    }

    // MARK: - Knoppen & Acties
    @objc @discardableResult private func toggleArm() -> Bool {
        if isArmed {
            deactivateArmedMode()
            return false
        } else {
            activateArmedMode()
            return true
        }
    }
    
    private func activateArmedMode() {
        isArmed = true
        armBtn.setTitle("🟢 BEWAKING ACTIEF (STOP)", for: .normal)
        armBtn.backgroundColor = UIColor(red: 0.05, green: 0.22, blue: 0.12, alpha: 0.95)
        armBtn.layer.borderColor = UIColor.systemGreen.cgColor
        statusDot.backgroundColor = .systemGreen
        statusLabel.text = "HOMESENTRY • VOORDEUR BEWAKING"
    }
    
    private func deactivateArmedMode() {
        isArmed = false
        armBtn.setTitle("⚪ BEWAKING GESTOPT (START)", for: .normal)
        armBtn.backgroundColor = UIColor(red: 0.15, green: 0.18, blue: 0.25, alpha: 0.95)
        armBtn.layer.borderColor = UIColor.systemGray.cgColor
        statusDot.backgroundColor = .systemYellow
        statusLabel.text = "HOMESENTRY • STANDBY"
        if isRecording { stopVideoRecording() }
    }
    
    @objc private func toggleZoneEdit() {
        resetAutoBlackScreenTimer()
        canvasView.isEditing.toggle()
        zoneBtn.backgroundColor = canvasView.isEditing ? UIColor.systemCyan.withAlphaComponent(0.4) : UIColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 0.85)
        zoneBtn.setTitle(canvasView.isEditing ? "💾 Klaar" : "🚪 Zone", for: .normal)
    }
    
    @objc private func showAcousticLog() {
        resetAutoBlackScreenTimer()
        let events = AcousticSentryEngine.shared.recentEvents
        let msg = events.isEmpty ? "Geen recente geluidswaarnemingen." : events.prefix(8).map {
            "\($0.timeString) • \($0.type.emoji) \($0.type.displayName) (\(Int($0.decibels)) dB)"
        }.joined(separator: "\n")
        
        let alert = UIAlertController(title: "🔊 Akoestisch Geluidslogboek", message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    @objc private func enableBlackScreen() {
        isBlackScreenActive = true
        UIView.animate(withDuration: 0.3) {
            self.blackScreenOverlay.alpha = 1.0
            self.blackScreenOverlay.isUserInteractionEnabled = true
        }
    }
    
    private func disableBlackScreen() {
        isBlackScreenActive = false
        UIView.animate(withDuration: 0.3) {
            self.blackScreenOverlay.alpha = 0.0
            self.blackScreenOverlay.isUserInteractionEnabled = false
        }
        resetAutoBlackScreenTimer()
    }
    
    @objc private func screenTapped() {
        if isBlackScreenActive {
            disableBlackScreen()
        } else {
            resetAutoBlackScreenTimer()
        }
    }
    
    private func resetAutoBlackScreenTimer() {
        autoBlackScreenTimer?.invalidate()
        autoBlackScreenTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.canvasView.isEditing, !self.isRecording else { return }
            self.enableBlackScreen()
        }
    }
    
    @objc private func showClipsMenu() {
        resetAutoBlackScreenTimer()
        let clips = getAllClipsDict()
        let alert = UIAlertController(title: "🎬 Bewakingsopnames", message: "Totaal \(clips.count) opname(s) beschikbaar:", preferredStyle: .actionSheet)
        for c in clips.prefix(10) {
            let title = "\(c["category"] as? String ?? "Clip") • \(c["date"] as? String ?? "") (\(c["duration"] as? Int ?? 0)s)"
            alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
                if let fn = c["filename"] as? String {
                    self?.playVideo(name: fn)
                }
            }))
        }
        alert.addAction(UIAlertAction(title: "Sluiten", style: .cancel))
        present(alert, animated: true)
    }
    
    private func playVideo(name: String) {
        guard let url = findVideoURLByName(name) else { return }
        let player = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = player
        present(vc, animated: true) { player.play() }
    }
    
    @objc private func showSettings() {
        resetAutoBlackScreenTimer()
        let ip = getLocalIPAddress()
        let webLink = "http://\(ip):8082/?key=\(webAccessPIN)"
        
        let alert = UIAlertController(title: "⚙️ HomeSentry Instellingen",
                                      message: "🌐 Web Dashboard:\n\(webLink)\n\nVoer je Telegram Bot gegevens in:",
                                      preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "Bot Token"; tf.text = self.botToken }
        alert.addTextField { tf in tf.placeholder = "Chat ID"; tf.text = self.chatId }
        alert.addTextField { tf in tf.placeholder = "Web PIN (bijv. 1234)"; tf.text = self.webAccessPIN }
        
        alert.addAction(UIAlertAction(title: "Opslaan", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            self.botToken = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.chatId = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.webAccessPIN = alert.textFields?[2].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1234"
            self.webServer.accessKey = self.webAccessPIN
            self.telegramListener.botToken = self.botToken
            self.telegramListener.chatId = self.chatId
            self.telegramListener.start()
        }))
        alert.addAction(UIAlertAction(title: "Annuleren", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Bestands- en Clip Helpers
    private func getAllClipsDict() -> [[String: Any]] {
        var result: [[String: Any]] = []
        let fm = FileManager.default
        let df = DateFormatter()
        df.dateFormat = "dd-MM HH:mm"
        
        for cat in HomeDetectionCategory.allCases {
            let folder = baseRecordingsFolder.appendingPathComponent(cat.folderName)
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else { continue }
            for f in files where f.pathExtension.lowercased() == "mp4" {
                let date = (try? f.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                let asset = AVAsset(url: f)
                let dur = Int(CMTimeGetSeconds(asset.duration))
                result.append([
                    "category": "\(cat.emoji) \(cat.displayName)",
                    "date": df.string(from: date),
                    "duration": dur,
                    "filename": f.lastPathComponent,
                    "timestamp": date.timeIntervalSince1970
                ])
            }
        }
        return result.sorted { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }
    }
    
    private func findVideoURLByName(_ name: String) -> URL? {
        let fm = FileManager.default
        for cat in HomeDetectionCategory.allCases {
            let path = baseRecordingsFolder.appendingPathComponent(cat.folderName).appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { return path }
        }
        return nil
    }
    
    private func getVideoDataByName(_ name: String) -> Data? {
        guard let url = findVideoURLByName(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func getFreeDiskSpaceGB() -> String {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            let gb = Double(free.int64Value) / 1_000_000_000.0
            return String(format: "%.1f GB vrij", gb)
        }
        return ""
    }
    
    private func getLocalIPAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}

// MARK: - Voordeur Canvas View (Sleepbare Hoekpunten in Hal/Trap)
class HomeDoorCanvasView: UIView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    var isEditing: Bool = false { didSet { setNeedsDisplay() } }
    var onPointsUpdated: (([CGPoint]) -> Void)?
    var points: [CGPoint] = [] { didSet { setNeedsDisplay() } }
    
    private var activeCornerIndex: Int? = nil
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEditing, points.count == 4, let preview = previewLayer else { return }
        let touch = gesture.location(in: self)
        let screenPts = points.map { preview.layerPointConverted(fromCaptureDevicePoint: $0) }
        
        switch gesture.state {
        case .began:
            activeCornerIndex = nil
            for (idx, pt) in screenPts.enumerated() {
                if hypot(touch.x - pt.x, touch.y - pt.y) < 44 {
                    activeCornerIndex = idx
                    break
                }
            }
        case .changed:
            guard let idx = activeCornerIndex else { return }
            let devPt = preview.captureDevicePointConverted(fromLayerPoint: touch)
            points[idx] = CGPoint(x: max(0.02, min(0.98, devPt.x)), y: max(0.02, min(0.98, devPt.y)))
            setNeedsDisplay()
        case .ended, .cancelled:
            activeCornerIndex = nil
            onPointsUpdated?(points)
        default: break
        }
    }
    
    override func draw(_ rect: CGRect) {
        guard points.count >= 4 else { return }
        let screenPts: [CGPoint] = points.map { pt in
            previewLayer?.layerPointConverted(fromCaptureDevicePoint: pt) ?? CGPoint(x: pt.x * bounds.width, y: pt.y * bounds.height)
        }
        
        let path = UIBezierPath()
        path.move(to: screenPts[0])
        for p in screenPts.dropFirst() { path.addLine(to: p) }
        path.close()
        
        UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: isEditing ? 0.20 : 0.09).setFill()
        path.fill()
        
        UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.85).setStroke()
        path.lineWidth = isEditing ? 2.5 : 1.5
        path.stroke()
        
        if let topPt = screenPts.min(by: { $0.y < $1.y }) {
            let tag = isEditing ? "[VOORDEUR ZONE • BEWERKEN]" : "[VOORDEUR ZONE 01 • BEWAAKT]"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: UIColor.systemCyan
            ]
            let size = (tag as NSString).size(withAttributes: attrs)
            let tagRect = CGRect(x: max(14, topPt.x - size.width/2), y: max(60, topPt.y - 24), width: size.width + 12, height: 20)
            let bg = UIBezierPath(roundedRect: tagRect, cornerRadius: 4)
            UIColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 0.9).setFill()
            bg.fill()
            (tag as NSString).draw(at: CGPoint(x: tagRect.minX + 6, y: tagRect.minY + 3), withAttributes: attrs)
        }
        
        if isEditing {
            for pt in screenPts {
                let dot = UIBezierPath(arcCenter: pt, radius: 9, startAngle: 0, endAngle: .pi*2, clockwise: true)
                UIColor.systemCyan.setFill()
                dot.fill()
                UIColor.white.setStroke()
                dot.lineWidth = 2
                dot.stroke()
            }
        }
    }
}

// MARK: - Telegram Bot Command Listener voor HomeSentry
class HomeSentryTelegramListener {
    var botToken: String = ""
    var chatId: String = ""
    
    var onArm: (() -> Void)?
    var onDisarm: (() -> Void)?
    var onStatusRequested: (() -> [String: Any])?
    var onSnapshotRequested: (((Data?) -> Void) -> Void)?
    var onAdjustBox: ((CGFloat, CGFloat, CGFloat) -> [CGPoint])?
    
    private var lastUpdateId: Int = 0
    private var isPolling = false
    private var currentTask: URLSessionDataTask?
    
    func start() {
        guard !botToken.isEmpty else { return }
        isPolling = true
        poll()
    }
    
    func stop() {
        isPolling = false
        currentTask?.cancel()
        currentTask = nil
    }
    
    private func poll() {
        guard isPolling, !botToken.isEmpty else { return }
        let urlStr = "https://api.telegram.org/bot\(botToken)/getUpdates?offset=\(lastUpdateId + 1)&timeout=15"
        guard let url = URL(string: urlStr) else { return }
        
        currentTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, self.isPolling else { return }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["result"] as? [[String: Any]] {
                for update in results {
                    if let uid = update["update_id"] as? Int {
                        self.lastUpdateId = max(self.lastUpdateId, uid)
                    }
                    if let message = update["message"] as? [String: Any],
                       let text = message["text"] as? String {
                        self.handleCommand(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.poll()
            }
        }
        currentTask?.resume()
    }
    
    private func handleCommand(_ cmd: String) {
        let lower = cmd.lowercased()
        if lower.hasPrefix("/start") || lower.hasPrefix("/arm") || lower == "arm" {
            DispatchQueue.main.async { self.onArm?() }
            sendReply("🛡️ *HomeSentry Bewaking Ingeschakeld!*\nTrap en voordeur worden 24/7 bewaakt met Vision AI en geluidsdetectie.")
        } else if lower.hasPrefix("/stop") || lower.hasPrefix("/disarm") || lower == "stop" {
            DispatchQueue.main.async { self.onDisarm?() }
            sendReply("⚪ *HomeSentry Bewaking Gepauzeerd*")
        } else if lower.hasPrefix("/snap") || lower.hasPrefix("/foto") || lower == "foto" {
            onSnapshotRequested? { [weak self] data in
                guard let self = self, let d = data else { return }
                self.sendPhoto(jpegData: d, caption: "📹 *Live Camerabeeld vanaf de trap* gericht op voordeur")
            }
        } else if lower.hasPrefix("/status") || lower == "status" {
            let s = onStatusRequested?() ?? [:]
            let isArmed = s["isArmed"] as? Bool ?? false
            let temp = s["temperature"] as? Double ?? 20.5
            let press = s["pressure"] as? Double ?? 1013.0
            let trend = s["pressureTrend"] as? String ?? ""
            let db = s["decibels"] as? Float ?? 40.0
            let bat = s["battery"] as? Int ?? 100
            let isCharging = s["isCharging"] as? Bool ?? false
            let disk = s["disk"] as? String ?? ""
            let ip = s["ip"] as? String ?? ""
            
            let reply = """
            🛡️ *HomeSentry Systeemstatus (Trap & Voordeur)*
            • Status: \(isArmed ? "🟢 BEWAKING ACTIEF" : "⚪ STANDBY")
            • Temperatuur: 🌡️ \(String(format: "%.1f°C", temp))
            • Barometer: 🧭 \(String(format: "%.0f hPa", press)) (\(trend))
            • Geluidsniveau: 🎤 \(Int(db)) dB (Glas/Rook/Water AI actief)
            • iPhone XS Batterij: 🔋 \(bat)% \(isCharging ? "⚡ (Lader)" : "")
            • Opslag: 💾 \(disk)
            
            🌐 *Web Dashboard (Poort 8082)*:
            http://\(ip):8082/
            """
            sendReply(reply)
        } else if lower.hasPrefix("/temp") {
            let s = onStatusRequested?() ?? [:]
            let temp = s["temperature"] as? Double ?? 20.5
            let minT = s["minTemp"] as? Double ?? 19.8
            let maxT = s["maxTemp"] as? Double ?? 21.6
            let press = s["pressure"] as? Double ?? 1013.0
            sendReply("🌡️ *Klimaat & Barometer*\n• Huidige temperatuur: \(String(format: "%.1f°C", temp))\n• Vandaag: Min \(String(format: "%.1f°", minT)) / Max \(String(format: "%.1f°", maxT))\n• Luchtdruk: \(String(format: "%.0f hPa", press))")
        }
    }
    
    private func sendReply(_ text: String) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["chat_id": chatId, "text": text, "parse_mode": "Markdown"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
    
    private func sendPhoto(jpegData: Data, caption: String) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendPhoto")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n\(chatId)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n\(caption)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"parse_mode\"\r\n\r\nMarkdown\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"snap.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }
}
