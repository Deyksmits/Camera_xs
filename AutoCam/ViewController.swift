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

// MARK: - Zone Inrichting Modi
enum ZoneEditMode {
    case autoCarBox      // 1-tik op de auto selecteert en omlijnt de complete auto
    case manualPolygon   // Zelf hoekpunten plaatsen om een eigen box/polygoon te tekenen
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
    
    // MARK: - Auto Bewakingszone
    private var polygonPoints: [CGPoint] = [] // Genormaliseerde camera coordinaten (0.0 ... 1.0)
    private var isDrawingZone = false
    private var zoneEditMode: ZoneEditMode = .autoCarBox
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
    private var currentIncidentSnapshotData: Data?
    private var currentIncidentDate = Date()
    
    private var lastSnapshotAlertTime = Date.distantPast
    private let snapshotAlertCooldown: TimeInterval = 25.0

    // MARK: - Telegram Instellingen
    private var botToken: String {
        get { UserDefaults.standard.string(forKey: "tg_bot_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tg_bot_token") }
    }
    private var chatId: String {
        get { UserDefaults.standard.string(forKey: "tg_chat_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tg_chat_id") }
    }

    // MARK: - Prachtige Moderne UI Elementen
    private let canvasView = ZoneCanvasView()
    
    // Top Bar met Frosted Glassmorphism
    private let topGlassBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let statusDotView = UIView()
    private let statusTitleLabel = UILabel()
    private let recBadgeView = UIView()
    private let recDotView = UIView()
    private let recBadgeLabel = UILabel()
    
    // Countdown Card Overlay
    private let countdownCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let countdownNumberLabel = UILabel()
    private let countdownSubLabel = UILabel()
    private let countdownCancelButton = UIButton(type: .system)
    
    // Zone Edit Toolbar
    private let zoneEditBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let autoCarBoxButton = UIButton(type: .system)
    private let manualDrawButton = UIButton(type: .system)
    private let clearZoneButton = UIButton(type: .system)
    private let doneZoneButton = UIButton(type: .system)
    
    // Bottom Controls Bar met Frosted Glass
    private let bottomGlassBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let armButton = UIButton(type: .system)
    private let zoneButton = UIButton(type: .system)
    private let clipsButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let stealthButton = UIButton(type: .system)
    
    // Stealth Overlay (OLED Pure Black)
    private let stealthOverlay = UIView()
    private let stealthClockLabel = UILabel()
    private let stealthRecDot = UIView()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        setupStorageDirectories()
        setupCamera()
        setupModernUI()
        loadSavedPolygon()
        setupWakeLock()
        updateClipsButtonTitle()
        
        // Controleer en schoon berichten en video's ouder dan 2 weken op
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

    // MARK: - Opslag Directories (Personen, Fietsers, Autos, Overig)
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
            print("Fout bij openen achtercamera")
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

    // MARK: - Prachtige Moderne UI Opbouw
    private func setupModernUI() {
        canvasView.backgroundColor = .clear
        canvasView.isUserInteractionEnabled = true
        view.addSubview(canvasView)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        canvasView.addGestureRecognizer(tapGesture)

        // 1. Top Frosted Glass Status Bar
        topGlassBar.layer.cornerRadius = 20
        topGlassBar.clipsToBounds = true
        topGlassBar.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        topGlassBar.layer.borderWidth = 0.5
        topGlassBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topGlassBar)

        statusDotView.backgroundColor = .systemYellow
        statusDotView.layer.cornerRadius = 5
        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        topGlassBar.contentView.addSubview(statusDotView)

        statusTitleLabel.text = "STANDBY • Stel zone in"
        statusTitleLabel.textColor = .white
        statusTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        statusTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        topGlassBar.contentView.addSubview(statusTitleLabel)

        // REC Pill
        recBadgeView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.2)
        recBadgeView.layer.cornerRadius = 10
        recBadgeView.layer.borderColor = UIColor.systemRed.cgColor
        recBadgeView.layer.borderWidth = 1
        recBadgeView.isHidden = true
        recBadgeView.translatesAutoresizingMaskIntoConstraints = false
        topGlassBar.contentView.addSubview(recBadgeView)

        recDotView.backgroundColor = .systemRed
        recDotView.layer.cornerRadius = 4
        recDotView.translatesAutoresizingMaskIntoConstraints = false
        recBadgeView.addSubview(recDotView)

        recBadgeLabel.text = "REC"
        recBadgeLabel.textColor = .systemRed
        recBadgeLabel.font = UIFont.systemFont(ofSize: 11, weight: .black)
        recBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        recBadgeView.addSubview(recBadgeLabel)

        // 2. Zone Edit Bar (verschijnt bij instellen)
        zoneEditBar.layer.cornerRadius = 18
        zoneEditBar.clipsToBounds = true
        zoneEditBar.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.4).cgColor
        zoneEditBar.layer.borderWidth = 1
        zoneEditBar.isHidden = true
        zoneEditBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoneEditBar)

        let zoneStack = UIStackView()
        zoneStack.axis = .horizontal
        zoneStack.distribution = .fillEqually
        zoneStack.spacing = 6
        zoneStack.translatesAutoresizingMaskIntoConstraints = false
        zoneEditBar.contentView.addSubview(zoneStack)

        stylePillButton(autoCarBoxButton, title: "🚗 Auto Box", color: .systemBlue, action: #selector(selectAutoCarMode))
        stylePillButton(manualDrawButton, title: "✏️ Zelf Tekenen", color: UIColor.white.withAlphaComponent(0.15), action: #selector(selectManualDrawMode))
        stylePillButton(clearZoneButton, title: "🗑 Wis", color: UIColor.white.withAlphaComponent(0.15), action: #selector(clearZone))
        stylePillButton(doneZoneButton, title: "✓ Klaar", color: .systemGreen, action: #selector(finishZoneEdit))

        zoneStack.addArrangedSubview(autoCarBoxButton)
        zoneStack.addArrangedSubview(manualDrawButton)
        zoneStack.addArrangedSubview(clearZoneButton)
        zoneStack.addArrangedSubview(doneZoneButton)

        // 3. Countdown Card (Voor 5-seconden afteller)
        countdownCard.layer.cornerRadius = 24
        countdownCard.clipsToBounds = true
        countdownCard.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.5).cgColor
        countdownCard.layer.borderWidth = 1.5
        countdownCard.isHidden = true
        countdownCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(countdownCard)

        countdownNumberLabel.text = "5"
        countdownNumberLabel.textColor = .systemOrange
        countdownNumberLabel.font = UIFont.systemFont(ofSize: 56, weight: .heavy)
        countdownNumberLabel.textAlignment = .center
        countdownNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownCard.contentView.addSubview(countdownNumberLabel)

        countdownSubLabel.text = "Plaats je iPhone in positie...\nBewaking start zo direct."
        countdownSubLabel.textColor = .white
        countdownSubLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        countdownSubLabel.numberOfLines = 2
        countdownSubLabel.textAlignment = .center
        countdownSubLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownCard.contentView.addSubview(countdownSubLabel)

        countdownCancelButton.setTitle("Annuleren", for: .normal)
        countdownCancelButton.setTitleColor(.systemRed, for: .normal)
        countdownCancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        countdownCancelButton.addTarget(self, action: #selector(cancelCountdown), for: .touchUpInside)
        countdownCancelButton.translatesAutoresizingMaskIntoConstraints = false
        countdownCard.contentView.addSubview(countdownCancelButton)

        // 4. Bottom Controls Bar met Frosted Glass
        bottomGlassBar.layer.cornerRadius = 24
        bottomGlassBar.clipsToBounds = true
        bottomGlassBar.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        bottomGlassBar.layer.borderWidth = 0.5
        bottomGlassBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomGlassBar)

        let bottomStack = UIStackView()
        bottomStack.axis = .horizontal
        bottomStack.distribution = .fillEqually
        bottomStack.spacing = 8
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomGlassBar.contentView.addSubview(bottomStack)

        stylePillButton(armButton, title: "▶ Start", color: .systemGreen, action: #selector(toggleArm))
        stylePillButton(zoneButton, title: "📐 Zone", color: .systemBlue, action: #selector(toggleEditZone))
        stylePillButton(clipsButton, title: "📁 Clips", color: .systemPurple, action: #selector(showClipsMenu))
        stylePillButton(settingsButton, title: "⚙️ Setup", color: UIColor.white.withAlphaComponent(0.18), action: #selector(showSettings))
        stylePillButton(stealthButton, title: "🌙 Zwart", color: UIColor.black, action: #selector(enableStealthMode))
        stealthButton.layer.borderColor = UIColor.darkGray.cgColor
        stealthButton.layer.borderWidth = 1

        bottomStack.addArrangedSubview(armButton)
        bottomStack.addArrangedSubview(zoneButton)
        bottomStack.addArrangedSubview(clipsButton)
        bottomStack.addArrangedSubview(settingsButton)
        bottomStack.addArrangedSubview(stealthButton)

        // 5. Stealth Mode (OLED Pure Black)
        stealthOverlay.backgroundColor = .black
        stealthOverlay.isHidden = true
        let stealthTap = UITapGestureRecognizer(target: self, action: #selector(disableStealthMode))
        stealthOverlay.addGestureRecognizer(stealthTap)
        view.addSubview(stealthOverlay)

        stealthClockLabel.textColor = UIColor(white: 0.2, alpha: 1)
        stealthClockLabel.font = UIFont.monospacedSystemFont(ofSize: 34, weight: .bold)
        stealthClockLabel.textAlignment = .center
        stealthClockLabel.translatesAutoresizingMaskIntoConstraints = false
        stealthOverlay.addSubview(stealthClockLabel)

        stealthRecDot.backgroundColor = .systemRed
        stealthRecDot.layer.cornerRadius = 3
        stealthRecDot.isHidden = true
        stealthRecDot.translatesAutoresizingMaskIntoConstraints = false
        stealthOverlay.addSubview(stealthRecDot)

        // Constraints
        NSLayoutConstraint.activate([
            // Top Glass Bar
            topGlassBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            topGlassBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topGlassBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            topGlassBar.heightAnchor.constraint(equalToConstant: 44),

            statusDotView.leadingAnchor.constraint(equalTo: topGlassBar.leadingAnchor, constant: 14),
            statusDotView.centerYAnchor.constraint(equalTo: topGlassBar.centerYAnchor),
            statusDotView.widthAnchor.constraint(equalToConstant: 10),
            statusDotView.heightAnchor.constraint(equalToConstant: 10),

            statusTitleLabel.leadingAnchor.constraint(equalTo: statusDotView.trailingAnchor, constant: 10),
            statusTitleLabel.centerYAnchor.constraint(equalTo: topGlassBar.centerYAnchor),
            statusTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: recBadgeView.leadingAnchor, constant: -8),

            recBadgeView.trailingAnchor.constraint(equalTo: topGlassBar.trailingAnchor, constant: -12),
            recBadgeView.centerYAnchor.constraint(equalTo: topGlassBar.centerYAnchor),
            recBadgeView.widthAnchor.constraint(equalToConstant: 58),
            recBadgeView.heightAnchor.constraint(equalToConstant: 24),

            recDotView.leadingAnchor.constraint(equalTo: recBadgeView.leadingAnchor, constant: 8),
            recDotView.centerYAnchor.constraint(equalTo: recBadgeView.centerYAnchor),
            recDotView.widthAnchor.constraint(equalToConstant: 8),
            recDotView.heightAnchor.constraint(equalToConstant: 8),

            recBadgeLabel.leadingAnchor.constraint(equalTo: recDotView.trailingAnchor, constant: 6),
            recBadgeLabel.centerYAnchor.constraint(equalTo: recBadgeView.centerYAnchor),

            // Zone Edit Bar
            zoneEditBar.topAnchor.constraint(equalTo: topGlassBar.bottomAnchor, constant: 10),
            zoneEditBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            zoneEditBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            zoneEditBar.heightAnchor.constraint(equalToConstant: 44),

            zoneStack.topAnchor.constraint(equalTo: zoneEditBar.topAnchor, constant: 5),
            zoneStack.bottomAnchor.constraint(equalTo: zoneEditBar.bottomAnchor, constant: -5),
            zoneStack.leadingAnchor.constraint(equalTo: zoneEditBar.leadingAnchor, constant: 8),
            zoneStack.trailingAnchor.constraint(equalTo: zoneEditBar.trailingAnchor, constant: -8),

            // Countdown Card
            countdownCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            countdownCard.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            countdownCard.widthAnchor.constraint(equalToConstant: 240),
            countdownCard.heightAnchor.constraint(equalToConstant: 180),

            countdownNumberLabel.topAnchor.constraint(equalTo: countdownCard.topAnchor, constant: 16),
            countdownNumberLabel.centerXAnchor.constraint(equalTo: countdownCard.centerXAnchor),

            countdownSubLabel.topAnchor.constraint(equalTo: countdownNumberLabel.bottomAnchor, constant: 6),
            countdownSubLabel.leadingAnchor.constraint(equalTo: countdownCard.leadingAnchor, constant: 16),
            countdownSubLabel.trailingAnchor.constraint(equalTo: countdownCard.trailingAnchor, constant: -16),

            countdownCancelButton.bottomAnchor.constraint(equalTo: countdownCard.bottomAnchor, constant: -10),
            countdownCancelButton.centerXAnchor.constraint(equalTo: countdownCard.centerXAnchor),

            // Bottom Glass Bar
            bottomGlassBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            bottomGlassBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            bottomGlassBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            bottomGlassBar.heightAnchor.constraint(equalToConstant: 56),

            bottomStack.topAnchor.constraint(equalTo: bottomGlassBar.topAnchor, constant: 6),
            bottomStack.bottomAnchor.constraint(equalTo: bottomGlassBar.bottomAnchor, constant: -6),
            bottomStack.leadingAnchor.constraint(equalTo: bottomGlassBar.leadingAnchor, constant: 8),
            bottomStack.trailingAnchor.constraint(equalTo: bottomGlassBar.trailingAnchor, constant: -8),

            // Stealth
            stealthClockLabel.centerXAnchor.constraint(equalTo: stealthOverlay.centerXAnchor),
            stealthClockLabel.centerYAnchor.constraint(equalTo: stealthOverlay.centerYAnchor),
            
            stealthRecDot.topAnchor.constraint(equalTo: stealthClockLabel.topAnchor, constant: -12),
            stealthRecDot.centerXAnchor.constraint(equalTo: stealthOverlay.centerXAnchor),
            stealthRecDot.widthAnchor.constraint(equalToConstant: 6),
            stealthRecDot.heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    private func stylePillButton(_ btn: UIButton, title: String, color: UIColor, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = color
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        btn.layer.cornerRadius = 14
        btn.clipsToBounds = true
        btn.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - 5-Seconden Countdown Timer (Voor Rustig Neerzetten van de Telefoon)
    @objc private func toggleArm() {
        if isArmed {
            // Uitschakelen
            isArmed = false
            armButton.setTitle("▶ Start", for: .normal)
            armButton.backgroundColor = .systemGreen
            statusDotView.backgroundColor = .systemYellow
            statusTitleLabel.text = "STANDBY"
            if isRecording { stopVideoRecording() }
        } else if isCountingDown {
            cancelCountdown()
        } else {
            startCountdown()
        }
    }

    private func startCountdown() {
        if isDrawingZone { finishZoneEdit() }
        
        isCountingDown = true
        countdownRemaining = 5
        countdownNumberLabel.text = "\(countdownRemaining)"
        countdownCard.isHidden = false
        
        armButton.setTitle("❌ Stop", for: .normal)
        armButton.backgroundColor = .systemRed
        statusDotView.backgroundColor = .systemOrange
        statusTitleLabel.text = "START OVER 5s • Plaats telefoon"
        
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            self.countdownRemaining -= 1
            
            if self.countdownRemaining > 0 {
                self.countdownNumberLabel.text = "\(self.countdownRemaining)"
                self.statusTitleLabel.text = "START OVER \(self.countdownRemaining)s • Plaats telefoon"
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
        countdownCard.isHidden = true
        
        armButton.setTitle("▶ Start", for: .normal)
        armButton.backgroundColor = .systemGreen
        statusDotView.backgroundColor = .systemYellow
        statusTitleLabel.text = "STANDBY"
    }

    private func activateArmedMode() {
        isCountingDown = false
        countdownCard.isHidden = true
        
        // Reset bewegingsdetector naar de huidige stilstaande situatie
        motionDetector.reset()
        isArmed = true
        
        armButton.setTitle("⏸ Stop", for: .normal)
        armButton.backgroundColor = .systemRed
        statusDotView.backgroundColor = .systemGreen
        statusTitleLabel.text = "BEWAKING ACTIEF • Zone bewaakt"
        
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Zone Inrichten: Auto Box & Zelf Tekenen
    @objc private func toggleEditZone() {
        isDrawingZone.toggle()
        zoneEditBar.isHidden = !isDrawingZone
        
        if isDrawingZone {
            selectAutoCarMode()
        } else {
            statusTitleLabel.text = isArmed ? "BEWAKING ACTIEF" : "STANDBY"
            statusDotView.backgroundColor = isArmed ? .systemGreen : .systemYellow
        }
    }

    @objc private func selectAutoCarMode() {
        zoneEditMode = .autoCarBox
        autoCarBoxButton.backgroundColor = .systemBlue
        manualDrawButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        statusDotView.backgroundColor = .systemBlue
        statusTitleLabel.text = "Tik op je auto om de complete omtrek te kiezen"
    }

    @objc private func selectManualDrawMode() {
        zoneEditMode = .manualPolygon
        manualDrawButton.backgroundColor = .systemBlue
        autoCarBoxButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        statusDotView.backgroundColor = .systemBlue
        statusTitleLabel.text = "Tik 4 hoekpunten op het scherm voor je eigen box"
    }

    @objc private func finishZoneEdit() {
        isDrawingZone = false
        zoneEditBar.isHidden = true
        statusTitleLabel.text = isArmed ? "BEWAKING ACTIEF" : "STANDBY"
        statusDotView.backgroundColor = isArmed ? .systemGreen : .systemYellow
    }

    @objc private func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
        guard isDrawingZone else { return }
        let location = gesture.location(in: canvasView)
        
        let devicePoint: CGPoint
        if let preview = previewLayer {
            devicePoint = preview.captureDevicePointConverted(fromLayerPoint: location)
        } else {
            devicePoint = CGPoint(x: location.x / canvasView.bounds.width, y: location.y / canvasView.bounds.height)
        }
        
        if zoneEditMode == .autoCarBox {
            // Automatisch de complete auto detecteren en omlijnen
            detectFullCarOutline(at: devicePoint)
        } else {
            // Zelf punten plaatsen om een eigen box/polygoon te tekenen
            polygonPoints.append(devicePoint)
            canvasView.points = polygonPoints
            savePolygon()
            
            if polygonPoints.count >= 4 {
                statusTitleLabel.text = "✓ Eigen zone ingesteld! (\(polygonPoints.count) punten)"
            } else {
                statusTitleLabel.text = "Punt \(polygonPoints.count) geplaatst • Tik volgend hoekpunt"
            }
        }
    }

    // MARK: - Volledige Auto Detectie & Omlijning met Marge
    private func detectFullCarOutline(at tapPoint: CGPoint) {
        var mergedCarRect: CGRect?
        
        if let cgImg = self.latestFrameCGImage {
            // Voer zowel Objectness als Attention saliency uit om alle componenten van de auto te vangen
            let objectnessReq = VNGenerateObjectnessBasedSaliencyImageRequest()
            let attentionReq = VNGenerateAttentionBasedSaliencyImageRequest()
            
            let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
            try? handler.perform([objectnessReq, attentionReq])
            
            var candidateRects: [CGRect] = []
            
            let visionTapPoint = CGPoint(x: tapPoint.x, y: 1.0 - tapPoint.y)
            
            // Verzamel alle saliency rechthoeken
            if let obs = objectnessReq.results?.first as? VNSaliencyImageObservation, let objs = obs.salientObjects {
                for o in objs {
                    candidateRects.append(CGRect(x: o.boundingBox.minX, y: 1.0 - o.boundingBox.maxY,
                                                 width: o.boundingBox.width, height: o.boundingBox.height))
                }
            }
            if let obs = attentionReq.results?.first as? VNSaliencyImageObservation, let objs = obs.salientObjects {
                for o in objs {
                    candidateRects.append(CGRect(x: o.boundingBox.minX, y: 1.0 - o.boundingBox.maxY,
                                                 width: o.boundingBox.width, height: o.boundingBox.height))
                }
            }
            
            // Zoek alle rechthoeken die het tikpunt raken of dichtbij de auto liggen
            var carParts: [CGRect] = []
            for r in candidateRects {
                let center = CGPoint(x: r.midX, y: r.midY)
                let dist = hypot(center.x - tapPoint.x, center.y - tapPoint.y)
                if r.contains(tapPoint) || dist < 0.32 {
                    carParts.append(r)
                }
            }
            
            // Voeg alle overlappende/aangrenzende delen samen tot één complete auto-omtrek!
            if !carParts.isEmpty {
                var unionRect = carParts[0]
                for p in carParts.dropFirst() {
                    unionRect = unionRect.union(p)
                }
                mergedCarRect = unionRect
            }
        }
        
        // Zorg dat de box minimaal proportioneel een hele auto dekt
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
        
        if let box = mergedCarRect, box.width >= 0.15 && box.height >= 0.12 {
            // Ruime veiligheidsmarge van 18% rondom de complete auto
            let marginX = max(0.04, box.width * 0.18)
            let marginY = max(0.04, box.height * 0.18)
            minX = max(0.02, box.minX - marginX)
            maxX = min(0.98, box.maxX + marginX)
            minY = max(0.02, box.minY - marginY)
            maxY = min(0.98, box.maxY + marginY)
        } else {
            // Fallback: ruime complete autobox gecentreerd op tikpunt
            let boxW: CGFloat = 0.58
            let boxH: CGFloat = 0.42
            minX = max(0.02, tapPoint.x - boxW / 2)
            maxX = min(0.98, tapPoint.x + boxW / 2)
            minY = max(0.02, tapPoint.y - boxH / 2)
            maxY = min(0.98, tapPoint.y + boxH / 2)
        }
        
        polygonPoints = [
            CGPoint(x: minX, y: minY), // Linksboven
            CGPoint(x: maxX, y: minY), // Rechtsboven
            CGPoint(x: maxX, y: maxY), // Rechtsonder
            CGPoint(x: minX, y: maxY)  // Linksonder
        ]
        
        canvasView.points = polygonPoints
        savePolygon()
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        statusDotView.backgroundColor = .systemGreen
        statusTitleLabel.text = "🚗 Complete auto omlijnd met veiligheidsmarge!"
    }

    @objc private func clearZone() {
        polygonPoints.removeAll()
        canvasView.points = []
        motionDetector.reset()
        savePolygon()
        statusTitleLabel.text = "Zone gewist. Tik op je auto of teken opnieuw."
    }

    private func savePolygon() {
        let array = polygonPoints.map { [$0.x, $0.y] }
        UserDefaults.standard.set(array, forKey: "saved_polygon")
    }

    private func loadSavedPolygon() {
        if let array = UserDefaults.standard.array(forKey: "saved_polygon") as? [[CGFloat]] {
            polygonPoints = array.map { CGPoint(x: $0[0], y: $0[1]) }
            canvasView.points = polygonPoints
        }
    }

    // MARK: - Stealth Modus (OLED Pure Black)
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
        stealthClockLabel.text = formatter.string(from: Date())
        if !stealthOverlay.isHidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.updateClock()
            }
        }
    }

    // MARK: - Instellingen (Telegram & 2-Weken Auto-Verwijdering)
    @objc private func showSettings() {
        let tracked = UserDefaults.standard.array(forKey: "tg_tracked_messages") as? [[String: Any]] ?? []
        let msgCount = tracked.count
        
        let alert = UIAlertController(title: "Instellingen & Bewaartermijn",
                                      message: "Beelden en videoclips worden na 2 weken (14 dagen) automatisch gewist uit Telegram en lokale opslag.\n(\(msgCount) actieve opnames in Telegram)",
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
            "text": "✅ *AutoCam Verbinding Geslaagd!*\nJe iPhone Xs staat klaar om meldingen en videoclips door te sturen.\n⏱️ _Beelden worden na 2 weken automatisch uit deze chat gewist._",
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

    // MARK: - AVCapture Video Data Output (Real-time Bewegingsdetectie in de Zone)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isArmed || isDrawingZone else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let now = Date()
        
        if now.timeIntervalSince(lastStoredFrameTime) > 0.4 {
            lastStoredFrameTime = now
            if let cg = createCGImage(from: pixelBuffer) {
                self.latestFrameCGImage = cg
            }
        }
        
        guard isArmed else { return }
        
        let hasMotionInZone = motionDetector.processFrame(pixelBuffer: pixelBuffer, polygon: self.polygonPoints)
        
        if hasMotionInZone {
            lastMotionTime = now
            
            if isRecording && sampleKeyframes.count < 6 && now.timeIntervalSince(lastKeyframeSampleTime) > 1.0 {
                lastKeyframeSampleTime = now
                if let cgImg = createCGImage(from: pixelBuffer) {
                    sampleKeyframes.append(cgImg)
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.isRecording {
                    if let cgImage = self.createCGImage(from: pixelBuffer) {
                        let uiImg = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
                        self.currentIncidentSnapshotData = uiImg.jpegData(compressionQuality: 0.85)
                        self.sampleKeyframes.append(cgImage)
                    }
                    self.currentIncidentDate = Date()
                    self.startVideoRecording()
                }
            }
        } else {
            if isRecording {
                let timeSinceLastMotion = now.timeIntervalSince(lastMotionTime)
                let totalDuration = now.timeIntervalSince(recordingStartTime)
                
                if (timeSinceLastMotion >= noMotionPostRollSeconds && totalDuration >= minRecordDuration) || totalDuration >= maxRecordDuration {
                    DispatchQueue.main.async { [weak self] in
                        self?.stopVideoRecording()
                    }
                }
            }
        }
    }

    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ciImage, from: ciImage.extent)
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
        
        updateRecordingUI(active: true)
        
        let now = Date()
        if now.timeIntervalSince(lastSnapshotAlertTime) > snapshotAlertCooldown, let snapData = currentIncidentSnapshotData {
            lastSnapshotAlertTime = now
            sendInstantMovementAlert(jpegData: snapData)
        }
        
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.recordingStartTime))
            self.statusTitleLabel.text = "🔴 OPNEMEN: BEWEGING BIJ AUTO (\(elapsed)s)"
            
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

    private func updateRecordingUI(active: Bool) {
        recBadgeView.isHidden = !active
        stealthRecDot.isHidden = !active
        if active {
            statusDotView.backgroundColor = .systemRed
            statusTitleLabel.text = "🔴 OPNEMEN: BEWEGING IN ZONE"
        } else {
            statusDotView.backgroundColor = isArmed ? .systemGreen : .systemYellow
            statusTitleLabel.text = isArmed ? "BEWAKING ACTIEF • Zone bewaakt" : "STANDBY"
        }
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate (Opname Gereed -> Analyse & Classificatie)
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.updateRecordingUI(active: false)
            self?.statusDotView.backgroundColor = .systemOrange
            self?.statusTitleLabel.text = "🔍 Analyseren van object..."
        }
        
        guard error == nil else {
            print("Fout bij opname: \(String(describing: error))")
            sampleKeyframes.removeAll()
            return
        }
        
        let framesToAnalyze = self.sampleKeyframes
        self.sampleKeyframes = []
        let snapshotData = self.currentIncidentSnapshotData
        let incidentDate = self.currentIncidentDate
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            self.classifyIncident(frames: framesToAnalyze) { category in
                self.handleClassifiedIncident(videoURL: outputFileURL,
                                             snapshotData: snapshotData,
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

    // MARK: - Afhandeling Geclassificeerd Incident
    private func handleClassifiedIncident(videoURL: URL, snapshotData: Data?, category: DetectionCategory, incidentDate: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let baseName = "AutoCam_\(formatter.string(from: incidentDate))"
        
        let targetCategoryFolder = baseRecordingsFolder.appendingPathComponent(category.folderName, isDirectory: true)
        let finalVideoURL = targetCategoryFolder.appendingPathComponent("\(baseName).mp4")
        let finalPhotoURL = targetCategoryFolder.appendingPathComponent("\(baseName).jpg")
        
        try? FileManager.default.removeItem(at: finalVideoURL)
        try? FileManager.default.moveItem(at: videoURL, to: finalVideoURL)
        
        if let snapData = snapshotData {
            try? snapData.write(to: finalPhotoURL)
        }
        
        print("✅ Bewakingsvideo opgeslagen in [\(category.folderName)]: \(finalVideoURL.path)")
        
        saveVideoToPhotosLibrary(fileURL: finalVideoURL)
        
        let asset = AVAsset(url: finalVideoURL)
        var vidWidth = 720
        var vidHeight = 1280
        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            vidWidth = Int(abs(size.width))
            vidHeight = Int(abs(size.height))
        }
        let durationSec = max(1, Int(CMTimeGetSeconds(asset.duration)))
        
        sendCategorizedTelegramVideo(videoURL: finalVideoURL,
                                     category: category,
                                     durationSeconds: durationSec,
                                     videoWidth: vidWidth,
                                     videoHeight: vidHeight,
                                     date: incidentDate)
        
        cleanupOldTelegramMessages()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateClipsButtonTitle()
            self.statusDotView.backgroundColor = .systemGreen
            self.statusTitleLabel.text = "💾 [\(category.folderName)] \(category.displayName) bewaard"
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if self.isArmed && !self.isRecording {
                    self.statusTitleLabel.text = "BEWAKING ACTIEF • Zone bewaakt"
                }
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
        clipsButton.setTitle("📁 Clips (\(count))", for: .normal)
    }

    @objc private func showClipsMenu() {
        let alert = UIAlertController(title: "Bewakingsopnames per Mapje",
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
                let snapURL = clip.deletingPathExtension().appendingPathExtension("jpg")
                try? fm.removeItem(at: snapURL)
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
        print("📌 Telegram bericht #\(messageId) geregistreerd voor automatische verwijdering na 2 weken.")
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
                print("🗑️ Telegram bericht #\(messageId) na 2 weken verwijderd: \(str)")
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
                    let snapURL = clip.deletingPathExtension().appendingPathExtension("jpg")
                    try? fm.removeItem(at: snapURL)
                    print("🗑️ Lokale opname ouder dan 2 weken opgeruimd: \(clip.lastPathComponent)")
                }
            }
        }
        updateClipsButtonTitle()
    }

    // MARK: - Telegram Berichten
    private func sendInstantMovementAlert(jpegData: Data) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendPhoto")!
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

        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH:mm:ss"
        let caption = "⚠️ *BEWEGING IN AUTO-ZONE!*\n📅 \(formatter.string(from: Date()))\n🎥 _Video-opname is gestart... Zodra het object uit beeld is wordt het geanalyseerd._\n⏱️ _Wordt na 2 weken gewist._"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"snapshot.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
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

    private func sendCategorizedTelegramVideo(videoURL: URL,
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
        case .car: header = "🚗 *BEWAKING: AUTO / VOERTUIG GEDETECTEERD*"
        case .other: header = "📦 *BEWAKING: ONBEKEND OBJECT / BEWEGING*"
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

// MARK: - Zone Canvas View (Prachtige Neon Groene Lijn en Handles)
class ZoneCanvasView: UIView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    
    var points: [CGPoint] = [] {
        didSet { setNeedsDisplay() }
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
            // Zachte gloed vulling
            UIColor(red: 0.1, green: 0.85, blue: 0.45, alpha: 0.22).setFill()
            path.fill()
        }
        
        // Heldere neon rand
        UIColor(red: 0.2, green: 0.95, blue: 0.55, alpha: 0.9).setStroke()
        path.lineWidth = 2.5
        path.lineJoinStyle = .round
        path.stroke()

        // Hoekpunten handles
        for (idx, pt) in screenPoints.enumerated() {
            let outerCircle = UIBezierPath(arcCenter: pt, radius: 7, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor.white.setFill()
            outerCircle.fill()
            
            let innerCircle = UIBezierPath(arcCenter: pt, radius: 4, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            (idx == 0 ? UIColor.systemRed : UIColor.systemGreen).setFill()
            innerCircle.fill()
        }
    }
}
