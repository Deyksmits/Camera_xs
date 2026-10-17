import UIKit
import AVFoundation
import Vision
import Photos
import AVKit

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

// MARK: - Slimme Bewegingsdetector (Filtert ruis zoals dwarrelende blaadjes)
class ZoneMotionDetector {
    private var lastGrid: [UInt8]?
    private var lastCols = 36
    private var lastRows = 64
    private var consecutiveMotionFrames = 0
    private let requiredConsecutiveFrames = 2
    private let pixelDeltaThreshold: Int = 22
    
    func reset() {
        lastGrid = nil
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
        
        if lastGrid == nil || lastCols != cols || lastRows != rows {
            lastGrid = currentGrid
            lastCols = cols
            lastRows = rows
            return false
        }
        
        guard let prevGrid = lastGrid else { return false }
        lastGrid = currentGrid
        
        var totalZoneCells = 0
        var changedCells = 0
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
                let delta = abs(Int(currentGrid[idx]) - Int(prevGrid[idx]))
                
                if delta > pixelDeltaThreshold {
                    changedCells += 1
                    minCol = min(minCol, c)
                    maxCol = max(maxCol, c)
                    minRow = min(minRow, r)
                    maxRow = max(maxRow, r)
                }
            }
        }
        
        guard totalZoneCells > 0 else { return false }
        
        let spanCols = max(0, maxCol - minCol + 1)
        let spanRows = max(0, maxRow - minRow + 1)
        let spanArea = spanCols * spanRows
        
        let minRequiredCells = max(14, Int(Double(totalZoneCells) * 0.02))
        let isSignificantMotion = (changedCells >= minRequiredCells) && (spanArea >= 12) && (spanCols >= 3 && spanRows >= 3)
        
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
    
    // MARK: - Auto Bewakingszone (Standaard 4 hoeken die gesleept kunnen worden)
    private var polygonPoints: [CGPoint] = [] // Genormaliseerde camera coordinaten (0.0 ... 1.0)
    private var isEditingZone = false
    private var isArmed = false
    private let motionDetector = ZoneMotionDetector()
    
    // MARK: - Start Countdown Timer (5 Seconden)
    private var isCountingDown = false
    private var countdownRemaining = 5
    private var countdownTimer: Timer?
    
    // MARK: - Video Opname State
    private var isRecording = false
    private var recordingStartTime = Date.distantPast
    private var lastMotionTime = Date.distantPast
    private var recordingTimer: Timer?
    
    private let noMotionPostRollSeconds: TimeInterval = 3.5
    private let minRecordDuration: TimeInterval = 6.0
    private let maxRecordDuration: TimeInterval = 60.0
    
    // Bewaartermijn: 2 weken (14 dagen)
    private let retentionDurationSeconds: TimeInterval = 14 * 24 * 3600
    
    private var sampleKeyframes: [CGImage] = []
    private var lastKeyframeSampleTime = Date.distantPast
    private var currentIncidentDate = Date()

    // MARK: - Telegram Instellingen
    private var botToken: String {
        get { UserDefaults.standard.string(forKey: "tg_bot_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tg_bot_token") }
    }
    private var chatId: String {
        get { UserDefaults.standard.string(forKey: "tg_chat_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tg_chat_id") }
    }

    // MARK: - Prachtige, Schone & Minimalistische UI
    private let canvasView = ZoneCanvasView()
    
    // Minimalistische Floating Status Pill bovenin
    private let statusPill = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    
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
    private let clipsBtn = UIButton(type: .system)
    private let settingsBtn = UIButton(type: .system)
    private let stealthBtn = UIButton(type: .system)
    
    // Stealth Mode Overlay (OLED Pitch Black)
    private let stealthOverlay = UIView()
    private let stealthClock = UILabel()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        setupStorageDirectories()
        setupCamera()
        setupCleanUI()
        loadSavedPolygon()
        setupWakeLock()
        updateClipsButtonTitle()
        
        cleanupOldTelegramMessages()
        cleanupOldLocalRecordings()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        canvasView.frame = view.bounds
        stealthOverlay.frame = view.bounds
        updateOrientations()
        canvasView.setNeedsDisplay()
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

    // MARK: - Camera Setup
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

    private func setupWakeLock() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - Schone, Minimalistische & Moderne UI
    private func setupCleanUI() {
        // 1. Interactief Canvas met sleepbare hoeken
        canvasView.backgroundColor = .clear
        view.addSubview(canvasView)
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        canvasView.addGestureRecognizer(tap)

        // 2. Top Floating Status Pill
        statusPill.layer.cornerRadius = 18
        statusPill.clipsToBounds = true
        statusPill.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        statusPill.layer.borderWidth = 0.5
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusPill)

        statusDot.backgroundColor = .systemYellow
        statusDot.layer.cornerRadius = 4.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusPill.contentView.addSubview(statusDot)

        statusLabel.text = "STANDBY"
        statusLabel.textColor = .white
        statusLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPill.contentView.addSubview(statusLabel)

        // 3. Zone Edit Floating Toolbar
        zoneToolbar.layer.cornerRadius = 18
        zoneToolbar.clipsToBounds = true
        zoneToolbar.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
        zoneToolbar.layer.borderWidth = 1
        zoneToolbar.isHidden = true
        zoneToolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoneToolbar)

        let zoneStack = UIStackView()
        zoneStack.axis = .horizontal
        zoneStack.distribution = .fillProportionally
        zoneStack.spacing = 6
        zoneStack.translatesAutoresizingMaskIntoConstraints = false
        zoneToolbar.contentView.addSubview(zoneStack)

        stylePill(autoDetectCarBtn, title: "🚗 Auto Tik", color: .systemBlue, action: #selector(autoDetectCarTapped))
        stylePill(resetBoxBtn, title: "↺ Herstel", color: UIColor.white.withAlphaComponent(0.15), action: #selector(resetBoxToCenter))
        stylePill(doneZoneBtn, title: "✓ Klaar", color: .systemGreen, action: #selector(finishZoneEdit))

        zoneStack.addArrangedSubview(autoDetectCarBtn)
        zoneStack.addArrangedSubview(resetBoxBtn)
        zoneStack.addArrangedSubview(doneZoneBtn)

        // 4. Countdown Pill
        countdownPill.layer.cornerRadius = 22
        countdownPill.clipsToBounds = true
        countdownPill.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.6).cgColor
        countdownPill.layer.borderWidth = 1.5
        countdownPill.isHidden = true
        countdownPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(countdownPill)

        countdownLabel.text = "⏳ Start in 5s • Tik om te annuleren"
        countdownLabel.textColor = .white
        countdownLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        countdownLabel.textAlignment = .center
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownPill.contentView.addSubview(countdownLabel)

        let cancelTap = UITapGestureRecognizer(target: self, action: #selector(cancelCountdown))
        countdownPill.addGestureRecognizer(cancelTap)

        // 5. Bottom Floating Control Dock
        controlDock.layer.cornerRadius = 24
        controlDock.clipsToBounds = true
        controlDock.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        controlDock.layer.borderWidth = 0.5
        controlDock.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlDock)

        let dockStack = UIStackView()
        dockStack.axis = .horizontal
        dockStack.distribution = .fillEqually
        dockStack.spacing = 8
        dockStack.translatesAutoresizingMaskIntoConstraints = false
        controlDock.contentView.addSubview(dockStack)

        stylePill(armBtn, title: "▶ Start", color: .systemGreen, action: #selector(toggleArm))
        stylePill(zoneBtn, title: "📐 Zone", color: UIColor.white.withAlphaComponent(0.15), action: #selector(toggleEditZone))
        stylePill(clipsBtn, title: "📁 Clips", color: UIColor.white.withAlphaComponent(0.15), action: #selector(showClipsMenu))
        stylePill(settingsBtn, title: "⚙️ Setup", color: UIColor.white.withAlphaComponent(0.15), action: #selector(showSettings))
        stylePill(stealthBtn, title: "🌙 Zwart", color: UIColor.black, action: #selector(enableStealthMode))
        stealthBtn.layer.borderColor = UIColor.darkGray.cgColor
        stealthBtn.layer.borderWidth = 1

        dockStack.addArrangedSubview(armBtn)
        dockStack.addArrangedSubview(zoneBtn)
        dockStack.addArrangedSubview(clipsBtn)
        dockStack.addArrangedSubview(settingsBtn)
        dockStack.addArrangedSubview(stealthBtn)

        // 6. Stealth Overlay
        stealthOverlay.backgroundColor = .black
        stealthOverlay.isHidden = true
        let sTap = UITapGestureRecognizer(target: self, action: #selector(disableStealthMode))
        stealthOverlay.addGestureRecognizer(sTap)
        view.addSubview(stealthOverlay)

        stealthClock.textColor = UIColor(white: 0.22, alpha: 1)
        stealthClock.font = UIFont.monospacedSystemFont(ofSize: 34, weight: .bold)
        stealthClock.textAlignment = .center
        stealthClock.translatesAutoresizingMaskIntoConstraints = false
        stealthOverlay.addSubview(stealthClock)

        // Constraints
        NSLayoutConstraint.activate([
            // Status Pill
            statusPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusPill.heightAnchor.constraint(equalToConstant: 36),

            statusDot.leadingAnchor.constraint(equalTo: statusPill.contentView.leadingAnchor, constant: 14),
            statusDot.centerYAnchor.constraint(equalTo: statusPill.contentView.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 9),
            statusDot.heightAnchor.constraint(equalToConstant: 9),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.contentView.trailingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: statusPill.contentView.centerYAnchor),

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
            countdownPill.widthAnchor.constraint(equalToConstant: 260),

            countdownLabel.centerXAnchor.constraint(equalTo: countdownPill.contentView.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: countdownPill.contentView.centerYAnchor),

            // Control Dock
            controlDock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            controlDock.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            controlDock.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            controlDock.heightAnchor.constraint(equalToConstant: 52),

            dockStack.topAnchor.constraint(equalTo: controlDock.contentView.topAnchor, constant: 6),
            dockStack.bottomAnchor.constraint(equalTo: controlDock.contentView.bottomAnchor, constant: -6),
            dockStack.leadingAnchor.constraint(equalTo: controlDock.contentView.leadingAnchor, constant: 8),
            dockStack.trailingAnchor.constraint(equalTo: controlDock.contentView.trailingAnchor, constant: -8),

            // Stealth Clock
            stealthClock.centerXAnchor.constraint(equalTo: stealthOverlay.centerXAnchor),
            stealthClock.centerYAnchor.constraint(equalTo: stealthOverlay.centerYAnchor)
        ])
    }

    private func stylePill(_ btn: UIButton, title: String, color: UIColor, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = color
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        btn.layer.cornerRadius = 14
        btn.clipsToBounds = true
        btn.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - 5-Seconden Countdown Timer
    @objc private func toggleArm() {
        if isArmed {
            isArmed = false
            armBtn.setTitle("▶ Start", for: .normal)
            armBtn.backgroundColor = .systemGreen
            statusDot.backgroundColor = .systemYellow
            statusLabel.text = "STANDBY"
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
        countdownLabel.text = "⏳ Start in 5s • Tik om te annuleren"
        
        armBtn.setTitle("❌ Stop", for: .normal)
        armBtn.backgroundColor = .systemRed
        statusDot.backgroundColor = .systemOrange
        statusLabel.text = "START OVER 5s"
        
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            self.countdownRemaining -= 1
            
            if self.countdownRemaining > 0 {
                self.countdownLabel.text = "⏳ Start in \(self.countdownRemaining)s • Tik om te annuleren"
                self.statusLabel.text = "START OVER \(self.countdownRemaining)s"
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
        
        armBtn.setTitle("▶ Start", for: .normal)
        armBtn.backgroundColor = .systemGreen
        statusDot.backgroundColor = .systemYellow
        statusLabel.text = "STANDBY"
    }

    private func activateArmedMode() {
        isCountingDown = false
        countdownPill.isHidden = true
        
        motionDetector.reset()
        isArmed = true
        
        armBtn.setTitle("⏸ Stop", for: .normal)
        armBtn.backgroundColor = .systemRed
        statusDot.backgroundColor = .systemGreen
        statusLabel.text = "BEWAKING ACTIEF"
        
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
        
        let devicePoint: CGPoint
        if let preview = previewLayer {
            devicePoint = preview.captureDevicePointConverted(fromLayerPoint: location)
        } else {
            devicePoint = CGPoint(x: location.x / canvasView.bounds.width, y: location.y / canvasView.bounds.height)
        }
        
        // Pas de box direct aan naar de specifieke aangeklikte auto (ook bij diagonale stand of rij)
        fitBoxToTappedCar(at: devicePoint)
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

    // MARK: - Stealth Modus (OLED Pitch Black)
    @objc private func enableStealthMode() {
        stealthOverlay.isHidden = false
        updateClock()
    }

    @objc private func disableStealthMode() {
        stealthOverlay.isHidden = true
    }

    private func updateClock() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        stealthClock.text = formatter.string(from: Date())
        if !stealthOverlay.isHidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.updateClock()
            }
        }
    }

    // MARK: - Instellingen (Telegram & 2 Weken Opschoning)
    @objc private func showSettings() {
        let tracked = UserDefaults.standard.array(forKey: "tg_tracked_messages") as? [[String: Any]] ?? []
        let msgCount = tracked.count
        
        let alert = UIAlertController(title: "Telegram Instellingen",
                                      message: "Beelden worden na 2 weken automatisch gewist uit Telegram en lokale opslag.\n(\(msgCount) actieve opnames)",
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "Bot Token (van @BotFather)"
            tf.text = self.botToken
        }
        alert.addTextField { tf in
            tf.placeholder = "Chat ID (van @userinfobot)"
            tf.text = self.chatId
        }
        alert.addAction(UIAlertAction(title: "Opslaan & Test", style: .default, handler: { _ in
            self.botToken = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.chatId = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    // MARK: - AVCapture Video Data Output (Bewegingsdetectie in de Zone)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isArmed || isEditingZone else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let now = Date()
        
        if now.timeIntervalSince(lastStoredFrameTime) > 0.4 {
            lastStoredFrameTime = now
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            self.latestFrameCGImage = context.createCGImage(ciImage, from: ciImage.extent)
        }
        
        guard isArmed else { return }
        
        let hasMotionInZone = motionDetector.processFrame(pixelBuffer: pixelBuffer, polygon: self.polygonPoints)
        
        if hasMotionInZone {
            lastMotionTime = now
            
            // Verzamel keyframes voor latere AI-classificatie
            if isRecording && sampleKeyframes.count < 6 && now.timeIntervalSince(lastKeyframeSampleTime) > 1.0 {
                lastKeyframeSampleTime = now
                let ci = CIImage(cvPixelBuffer: pixelBuffer)
                let ctx = CIContext(options: [.useSoftwareRenderer: false])
                if let cg = ctx.createCGImage(ci, from: ci.extent) {
                    sampleKeyframes.append(cg)
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.isRecording {
                    // Start direct met filmen (GEEN apart fotobericht versturen naar Telegram!)
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

    // MARK: - Video Opname Beheer
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
        lastKeyframeSampleTime = Date()
        
        statusDot.backgroundColor = .systemRed
        statusLabel.text = "🔴 OPNEMEN"
        
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.recordingStartTime))
            self.statusLabel.text = "🔴 OPNEMEN (0:\(String(format: "%02d", elapsed)))"
            
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

    // MARK: - AVCaptureFileOutputRecordingDelegate (Opname Gereed -> Export & 1 Bericht naar Telegram)
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.statusDot.backgroundColor = .systemOrange
            self?.statusLabel.text = "🔍 Analyseren van object..."
        }
        
        guard error == nil else {
            print("Fout bij opname: \(String(describing: error))")
            sampleKeyframes.removeAll()
            return
        }
        
        let framesToAnalyze = self.sampleKeyframes
        self.sampleKeyframes = []
        let incidentDate = self.currentIncidentDate
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            self.classifyIncident(frames: framesToAnalyze) { category in
                self.handleClassifiedIncident(videoURL: outputFileURL,
                                             category: category,
                                             incidentDate: incidentDate)
            }
        }
    }

    // MARK: - Object Classificatie via Apple Vision
    private func classifyIncident(frames: [CGImage], completion: @escaping (DetectionCategory) -> Void) {
        guard !frames.isEmpty else {
            completion(.other)
            return
        }
        
        var foundPerson = false
        var foundCyclist = false
        var foundCar = false
        
        let group = DispatchGroup()
        
        for cgImage in frames {
            group.enter()
            
            let humanRequest = VNDetectHumanRectanglesRequest { req, _ in
                if let observations = req.results as? [VNHumanObservation], !observations.isEmpty {
                    foundPerson = true
                }
            }
            
            let classifyRequest = VNClassifyImageRequest { req, _ in
                if let observations = req.results as? [VNClassificationObservation] {
                    for obs in observations.prefix(15) where obs.confidence > 0.18 {
                        let id = obs.identifier.lowercased()
                        
                        if id.contains("bicycle") || id.contains("cyclist") || id.contains("cycling") ||
                           id.contains("bike") || id.contains("tricycle") || id.contains("moped") || id.contains("scooter") {
                            foundCyclist = true
                        } else if id.contains("car") || id.contains("automobile") || id.contains("vehicle") ||
                                id.contains("sedan") || id.contains("suv") || id.contains("truck") ||
                                id.contains("pickup") || id.contains("van") || id.contains("minivan") ||
                                id.contains("cab") || id.contains("jeep") || id.contains("bus") {
                            foundCar = true
                        } else if id.contains("person") || id.contains("human") || id.contains("pedestrian") ||
                                id.contains("walker") || id.contains("man") || id.contains("woman") {
                            foundPerson = true
                        }
                    }
                }
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([humanRequest, classifyRequest])
            group.leave()
        }
        
        group.notify(queue: .global()) {
            if foundCyclist {
                completion(.cyclist)
            } else if foundPerson {
                completion(.person)
            } else if foundCar {
                completion(.car)
            } else {
                completion(.other)
            }
        }
    }

    // MARK: - Afhandeling Incident (Opslag in Mapje & Exact 1 Bericht naar Telegram)
    private func handleClassifiedIncident(videoURL: URL, category: DetectionCategory, incidentDate: Date) {
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
                    self.statusLabel.text = "BEWAKING ACTIEF"
                }
            }
        }
    }

    // MARK: - Video Export zonder Vervorming (Bakes In True Orientation)
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

        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH:mm:ss"
        
        var header = ""
        switch category {
        case .person: header = "🚨 *BEWAKING: PERSOON BIJ AUTO*"
        case .cyclist: header = "🚲 *BEWAKING: FIETSER BIJ AUTO*"
        case .car: header = "🚗 *BEWAKING: AUTO / VOERTUIG*"
        case .other: header = "📦 *BEWAKING: ONBEKEND OBJECT*"
        }
        
        let caption = """
        \(header)
        📁 Categorie: *\(category.folderName)*
        📅 \(formatter.string(from: date))
        ⏱️ Duur: \(durationSeconds)s
        
        _Object heeft de zone verlaten en is automatisch geclassificeerd._
        ⏱️ _Wordt na 2 weken automatisch gewist._
        """
        
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
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEditing, points.count == 4, let preview = previewLayer else { return }
        
        let touchLocation = gesture.location(in: self)
        let screenPoints = points.map { preview.layerPointConverted(fromCaptureDevicePoint: $0) }
        
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
                let devPoint = preview.captureDevicePointConverted(fromLayerPoint: touchLocation)
                let clampedX = max(0.01, min(0.99, devPoint.x))
                let clampedY = max(0.01, min(0.99, devPoint.y))
                points[cornerIdx] = CGPoint(x: clampedX, y: clampedY)
                setNeedsDisplay()
            } else if isDraggingWholeBox {
                let p0 = preview.captureDevicePointConverted(fromLayerPoint: dragStartTouch)
                let p1 = preview.captureDevicePointConverted(fromLayerPoint: touchLocation)
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
        let screenPoints: [CGPoint] = points.map { pt in
            if let preview = previewLayer {
                return preview.layerPointConverted(fromCaptureDevicePoint: pt)
            } else {
                return CGPoint(x: pt.x * bounds.width, y: pt.y * bounds.height)
            }
        }
        
        path.move(to: screenPoints[0])
        for pt in screenPoints.dropFirst() {
            path.addLine(to: pt)
        }
        if screenPoints.count >= 3 {
            path.close()
            UIColor(red: 0.1, green: 0.85, blue: 0.45, alpha: isEditing ? 0.28 : 0.18).setFill()
            path.fill()
        }
        
        // Neon rand
        UIColor(red: 0.2, green: 0.95, blue: 0.55, alpha: 0.95).setStroke()
        path.lineWidth = isEditing ? 3.0 : 2.0
        path.lineJoinStyle = .round
        path.stroke()

        // Als we bewerken: teken duidelijke, grote sleepbare handvatten op de 4 hoeken
        if isEditing {
            for pt in screenPoints {
                // Buitenste cirkel
                let outer = UIBezierPath(arcCenter: pt, radius: 14, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.white.withAlphaComponent(0.35).setFill()
                outer.fill()
                
                // Middenste ring
                let mid = UIBezierPath(arcCenter: pt, radius: 9, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.white.setFill()
                mid.fill()
                
                // Binnenste kern
                let inner = UIBezierPath(arcCenter: pt, radius: 5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.systemGreen.setFill()
                inner.fill()
            }
        } else {
            // Rustige, discrete hoekpunten tijdens bewaking
            for pt in screenPoints {
                let dot = UIBezierPath(arcCenter: pt, radius: 4, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor.white.setFill()
                dot.fill()
            }
        }
    }
}
