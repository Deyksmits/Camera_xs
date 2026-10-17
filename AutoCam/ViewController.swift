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

// MARK: - Slimme Bewegingsdetector (Filtert kleine ruis zoals dwarrelende blaadjes)
class ZoneMotionDetector {
    private var lastGrid: [UInt8]?
    private let cols = 64
    private let rows = 36
    private var consecutiveMotionFrames = 0
    private let requiredConsecutiveFrames = 2 // Minimaal 2 opeenvolgende frames voor betrouwbaarheid
    private let pixelDeltaThreshold: Int = 22  // Drempelwaarde voor pixelhelderheid (filtert sensorruis)
    
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
        
        var currentGrid = [UInt8](repeating: 0, count: cols * rows)
        let stepX = width / cols
        let stepY = height / rows
        
        if CVPixelBufferIsPlanar(pixelBuffer) {
            // YUV formaat: Plane 0 is Luminance (helderheid)
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
            // BGRA formaat
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
        
        guard let prevGrid = lastGrid else {
            lastGrid = currentGrid
            return false
        }
        
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
                
                // Controleer of de pixel binnen het getekende vak ligt
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
        
        // Reken de ruimtelijke spreiding (bounding box) van de beweging uit
        let spanCols = max(0, maxCol - minCol + 1)
        let spanRows = max(0, maxRow - minRow + 1)
        let spanArea = spanCols * spanRows
        
        // Drempel: een klein voorbijvliegend blaadje beslaat slechts 2 tot 5 cellen.
        // Een persoon, fietser, dier of auto beslaat minimaal 14 cellen met een 2D spreiding.
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
    
    // MARK: - Auto Bewakingszone
    private var polygonPoints: [CGPoint] = [] // Genormaliseerd (0.0 ... 1.0)
    private var isDrawingZone = false
    private var isArmed = false
    private let motionDetector = ZoneMotionDetector()
    
    // MARK: - Video Opname & Incident State
    private var isRecording = false
    private var recordingStartTime = Date.distantPast
    private var lastMotionTime = Date.distantPast
    private var recordingTimer: Timer?
    
    // Wachttijd nadat beweging stopt (object uit beeld) voordat opname afrondt
    private let noMotionPostRollSeconds: TimeInterval = 3.5
    private let minRecordDuration: TimeInterval = 6.0
    private let maxRecordDuration: TimeInterval = 60.0
    
    // Keyframes verzameld tijdens de actieve opname voor latere classificatie
    private var sampleKeyframes: [CGImage] = []
    private var lastKeyframeSampleTime = Date.distantPast
    private var currentIncidentSnapshotData: Data?
    private var currentIncidentDate = Date()
    
    // Telegram Alert Cooldown voor directe snapshot melding
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

    // MARK: - UI Elementen
    private let canvasView = ZoneCanvasView()
    private let hudLabel = UILabel()
    private let recBadgeView = UIView()
    private let recDotView = UIView()
    private let recBadgeLabel = UILabel()
    
    private let armButton = UIButton(type: .system)
    private let editZoneButton = UIButton(type: .system)
    private let clearZoneButton = UIButton(type: .system)
    private let clipsButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let stealthButton = UIButton(type: .system)
    
    private let stealthOverlay = UIView()
    private let stealthClockLabel = UILabel()
    private let stealthRecDot = UIView()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        setupStorageDirectories()
        loadSavedPolygon()
        setupCamera()
        setupUI()
        setupWakeLock()
        updateClipsButtonTitle()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        canvasView.frame = view.bounds
        stealthOverlay.frame = view.bounds
    }

    // MARK: - Mapjes Structuur Aanmaken (Personen, Fietsers, Autos, Overig)
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
        
        // Achtercamera instellen
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("Fout bij openen camera")
            return
        }
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        
        // Microfoon toevoegen voor audio bij bewakingsvideo
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }
        
        // Live Video Output voor bewegingsdetectie & Vision
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        
        // Movie Output voor automatische incidentvideo's
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            if let connection = movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
        
        captureSession.commitConfiguration()
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)
        
        cameraQueue.async {
            self.captureSession.startRunning()
        }
    }

    private func setupWakeLock() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - UI Opbouw
    private func setupUI() {
        canvasView.backgroundColor = .clear
        canvasView.isUserInteractionEnabled = true
        view.addSubview(canvasView)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        canvasView.addGestureRecognizer(tapGesture)

        // Status HUD
        hudLabel.backgroundColor = UIColor(white: 0, alpha: 0.65)
        hudLabel.textColor = .systemGreen
        hudLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        hudLabel.textAlignment = .center
        hudLabel.layer.cornerRadius = 8
        hudLabel.clipsToBounds = true
        hudLabel.text = "● STANDBY | Stel zone in"
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hudLabel)

        // REC Badge
        recBadgeView.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        recBadgeView.layer.cornerRadius = 6
        recBadgeView.layer.borderColor = UIColor.systemRed.cgColor
        recBadgeView.layer.borderWidth = 1
        recBadgeView.isHidden = true
        recBadgeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recBadgeView)

        recDotView.backgroundColor = .systemRed
        recDotView.layer.cornerRadius = 4
        recDotView.translatesAutoresizingMaskIntoConstraints = false
        recBadgeView.addSubview(recDotView)

        recBadgeLabel.text = "REC"
        recBadgeLabel.textColor = .white
        recBadgeLabel.font = UIFont.systemFont(ofSize: 11, weight: .black)
        recBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        recBadgeView.addSubview(recBadgeLabel)

        // Knoppenbalk
        let mainStack = UIStackView()
        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.distribution = .fillEqually
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)

        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.distribution = .fillEqually
        topRow.spacing = 8

        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.distribution = .fillEqually
        bottomRow.spacing = 8

        configureButton(armButton, title: "▶ Start", color: .systemGreen, action: #selector(toggleArm))
        configureButton(editZoneButton, title: "✏️ Zone", color: .systemBlue, action: #selector(toggleEditZone))
        configureButton(clearZoneButton, title: "🗑 Wis", color: .systemGray, action: #selector(clearZone))
        topRow.addArrangedSubview(armButton)
        topRow.addArrangedSubview(editZoneButton)
        topRow.addArrangedSubview(clearZoneButton)

        configureButton(clipsButton, title: "📁 Clips (0)", color: .systemPurple, action: #selector(showClipsMenu))
        configureButton(settingsButton, title: "⚙️ Setup", color: .systemIndigo, action: #selector(showSettings))
        configureButton(stealthButton, title: "🌙 Zwart", color: .black, action: #selector(enableStealthMode))
        stealthButton.layer.borderColor = UIColor.darkGray.cgColor
        stealthButton.layer.borderWidth = 1
        bottomRow.addArrangedSubview(clipsButton)
        bottomRow.addArrangedSubview(settingsButton)
        bottomRow.addArrangedSubview(stealthButton)

        mainStack.addArrangedSubview(topRow)
        mainStack.addArrangedSubview(bottomRow)

        // Stealth Overlay
        stealthOverlay.backgroundColor = .black
        stealthOverlay.isHidden = true
        let stealthTap = UITapGestureRecognizer(target: self, action: #selector(disableStealthMode))
        stealthOverlay.addGestureRecognizer(stealthTap)
        view.addSubview(stealthOverlay)

        stealthClockLabel.textColor = UIColor(white: 0.25, alpha: 1)
        stealthClockLabel.font = UIFont.monospacedSystemFont(ofSize: 28, weight: .bold)
        stealthClockLabel.textAlignment = .center
        stealthClockLabel.translatesAutoresizingMaskIntoConstraints = false
        stealthOverlay.addSubview(stealthClockLabel)

        stealthRecDot.backgroundColor = .systemRed
        stealthRecDot.layer.cornerRadius = 3
        stealthRecDot.isHidden = true
        stealthRecDot.translatesAutoresizingMaskIntoConstraints = false
        stealthOverlay.addSubview(stealthRecDot)

        NSLayoutConstraint.activate([
            hudLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hudLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hudLabel.trailingAnchor.constraint(equalTo: recBadgeView.leadingAnchor, constant: -8),
            hudLabel.heightAnchor.constraint(equalToConstant: 34),

            recBadgeView.centerYAnchor.constraint(equalTo: hudLabel.centerYAnchor),
            recBadgeView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            recBadgeView.widthAnchor.constraint(equalToConstant: 62),
            recBadgeView.heightAnchor.constraint(equalToConstant: 28),

            recDotView.leadingAnchor.constraint(equalTo: recBadgeView.leadingAnchor, constant: 8),
            recDotView.centerYAnchor.constraint(equalTo: recBadgeView.centerYAnchor),
            recDotView.widthAnchor.constraint(equalToConstant: 8),
            recDotView.heightAnchor.constraint(equalToConstant: 8),

            recBadgeLabel.leadingAnchor.constraint(equalTo: recDotView.trailingAnchor, constant: 6),
            recBadgeLabel.centerYAnchor.constraint(equalTo: recBadgeView.centerYAnchor),

            mainStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            mainStack.heightAnchor.constraint(equalToConstant: 84),

            stealthClockLabel.centerXAnchor.constraint(equalTo: stealthOverlay.centerXAnchor),
            stealthClockLabel.centerYAnchor.constraint(equalTo: stealthOverlay.centerYAnchor),

            stealthRecDot.topAnchor.constraint(equalTo: stealthClockLabel.topAnchor, constant: -10),
            stealthRecDot.centerXAnchor.constraint(equalTo: stealthOverlay.centerXAnchor),
            stealthRecDot.widthAnchor.constraint(equalToConstant: 6),
            stealthRecDot.heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    private func configureButton(_ btn: UIButton, title: String, color: UIColor, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = color
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        btn.layer.cornerRadius = 8
        btn.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - Zone Teken Logica
    @objc private func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
        guard isDrawingZone else { return }
        let location = gesture.location(in: canvasView)
        let normPoint = CGPoint(x: location.x / canvasView.bounds.width,
                                y: location.y / canvasView.bounds.height)
        polygonPoints.append(normPoint)
        canvasView.points = polygonPoints
        savePolygon()
    }

    @objc private func toggleEditZone() {
        isDrawingZone.toggle()
        if isDrawingZone {
            editZoneButton.setTitle("✓ Klaar", for: .normal)
            editZoneButton.backgroundColor = .systemOrange
            hudLabel.text = "Tik op scherm om zone rond je auto te tekenen"
        } else {
            editZoneButton.setTitle("✏️ Zone", for: .normal)
            editZoneButton.backgroundColor = .systemBlue
            hudLabel.text = isArmed ? "● BEWAKING ACTIEF (ZONE BEWAAKT)" : "● STANDBY"
        }
    }

    @objc private func clearZone() {
        polygonPoints.removeAll()
        canvasView.points = []
        motionDetector.reset()
        savePolygon()
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

    // MARK: - Bewaking Toggle
    @objc private func toggleArm() {
        isArmed.toggle()
        motionDetector.reset()
        if isArmed {
            armButton.setTitle("⏸ Stop", for: .normal)
            armButton.backgroundColor = .systemRed
            hudLabel.textColor = .systemGreen
            hudLabel.text = "● BEWAKING ACTIEF (ZONE BEWAAKT)"
            if isDrawingZone { toggleEditZone() }
        } else {
            armButton.setTitle("▶ Start", for: .normal)
            armButton.backgroundColor = .systemGreen
            hudLabel.textColor = .systemYellow
            hudLabel.text = "● STANDBY"
            if isRecording {
                stopVideoRecording()
            }
        }
    }

    // MARK: - Stealth Modus
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

    // MARK: - Instellingen (Telegram)
    @objc private func showSettings() {
        let alert = UIAlertController(title: "Telegram Meldingen", message: "Vul je bot token en chat ID in:", preferredStyle: .alert)
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
        alert.addAction(UIAlertAction(title: "Annuleren", style: .cancel))
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
            "text": "✅ *AutoCam Verbinding Geslaagd!*\nJe iPhone Xs staat klaar om meldingen en videoclips per categorie (Personen, Fietsers, Auto's, Overig) door te sturen.",
            "parse_mode": "Markdown"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - AVCapture Video Data Output (Real-time Bewegingsdetectie in de Zone)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isArmed else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let hasMotionInZone = motionDetector.processFrame(pixelBuffer: pixelBuffer, polygon: self.polygonPoints)
        let now = Date()
        
        if hasMotionInZone {
            // Beweging gedetecteerd binnen het vak!
            lastMotionTime = now
            
            // Verzamel periodiek keyframes (maximaal 6) tijdens het incident voor latere classificatie
            if isRecording && sampleKeyframes.count < 6 && now.timeIntervalSince(lastKeyframeSampleTime) > 1.0 {
                lastKeyframeSampleTime = now
                if let cgImg = createCGImage(from: pixelBuffer) {
                    sampleKeyframes.append(cgImg)
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.isRecording {
                    // Maak direct een hoge-resolutie foto snapshot van het moment van binnenkomst
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    let context = CIContext()
                    if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                        let uiImg = UIImage(cgImage: cgImage)
                        self.currentIncidentSnapshotData = uiImg.jpegData(compressionQuality: 0.8)
                        self.sampleKeyframes.append(cgImage)
                    }
                    self.currentIncidentDate = Date()
                    self.startVideoRecording()
                }
            }
        } else {
            // Geen beweging op dit moment. Als we opnemen, controleer of het object uit beeld is
            if isRecording {
                let timeSinceLastMotion = now.timeIntervalSince(lastMotionTime)
                let totalDuration = now.timeIntervalSince(recordingStartTime)
                
                // Object is uit beeld wanneer er minimaal 3.5s geen beweging meer is (en minimale opnameduur bereikt is)
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
        let context = CIContext()
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
            connection.videoOrientation = .portrait
        }
        
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        isRecording = true
        recordingStartTime = Date()
        lastMotionTime = Date()
        lastKeyframeSampleTime = Date()
        
        updateRecordingUI(active: true)
        
        // Directe snapshot melding naar Telegram bij binnenkomst (met cooldown)
        let now = Date()
        if now.timeIntervalSince(lastSnapshotAlertTime) > snapshotAlertCooldown, let snapData = currentIncidentSnapshotData {
            lastSnapshotAlertTime = now
            sendInstantMovementAlert(jpegData: snapData)
        }
        
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.recordingStartTime))
            self.hudLabel.text = "🔴 OPNEMEN: BEWEGING IN ZONE (\(elapsed)s)"
            
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
            hudLabel.textColor = .systemRed
            hudLabel.text = "🔴 OPNEMEN: BEWEGING IN ZONE"
        } else {
            hudLabel.textColor = .systemGreen
            hudLabel.text = isArmed ? "● BEWAKING ACTIEF (ZONE BEWAAKT)" : "● STANDBY"
        }
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate (Opname Gereed -> Analyse & Classificatie)
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.updateRecordingUI(active: false)
            self?.hudLabel.textColor = .systemYellow
            self?.hudLabel.text = "🔍 Analyseren van gedetecteerd object..."
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
        
        // Voer classificatie uit op de achtergrond nadat het object uit beeld is
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

    // MARK: - Object Classificatie (Persoon, Fietser, Auto, Overig) via Apple Vision
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
            
            // 1. Mensendetectie via Vision Human Detector
            let humanRequest = VNDetectHumanRectanglesRequest { req, _ in
                if let observations = req.results as? [VNHumanObservation], !observations.isEmpty {
                    foundPerson = true
                }
            }
            
            // 2. Beeldclassificatie via Apple Vision Neuraal Model
            let classifyRequest = VNClassifyImageRequest { req, _ in
                if let observations = req.results as? [VNClassificationObservation] {
                    for obs in observations.prefix(15) where obs.confidence > 0.18 {
                        let id = obs.identifier.lowercased()
                        
                        // Fietser / Fiets categorie
                        if id.contains("bicycle") || id.contains("cyclist") || id.contains("cycling") ||
                           id.contains("bike") || id.contains("tricycle") || id.contains("moped") || id.contains("scooter") {
                            foundCyclist = true
                        }
                        
                        // Auto / Voertuig categorie
                        else if id.contains("car") || id.contains("automobile") || id.contains("vehicle") ||
                                id.contains("sedan") || id.contains("suv") || id.contains("truck") ||
                                id.contains("pickup") || id.contains("van") || id.contains("minivan") ||
                                id.contains("cab") || id.contains("jeep") || id.contains("bus") {
                            foundCar = true
                        }
                        
                        // Persoon categorie
                        else if id.contains("person") || id.contains("human") || id.contains("pedestrian") ||
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
            // Prioriteitsbepaling: Fietser > Persoon > Auto > Overig
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

    // MARK: - Afhandeling Geclassificeerd Incident (Opslag in Mapjes & Aangepast Telegram Bericht)
    private func handleClassifiedIncident(videoURL: URL, snapshotData: Data?, category: DetectionCategory, incidentDate: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let baseName = "AutoCam_\(formatter.string(from: incidentDate))"
        
        // 1. Opslaan in het respectievelijke mapje (Documents/Recordings/<Categorie>/)
        let targetCategoryFolder = baseRecordingsFolder.appendingPathComponent(category.folderName, isDirectory: true)
        let finalVideoURL = targetCategoryFolder.appendingPathComponent("\(baseName).mp4")
        let finalPhotoURL = targetCategoryFolder.appendingPathComponent("\(baseName).jpg")
        
        // Verplaats video naar categorie mapje
        try? FileManager.default.removeItem(at: finalVideoURL)
        try? FileManager.default.moveItem(at: videoURL, to: finalVideoURL)
        
        // Bewaar de foto snapshot in hetzelfde categorie mapje
        if let snapData = snapshotData {
            try? snapData.write(to: finalPhotoURL)
        }
        
        print("✅ Bewakingsvideo opgeslagen in [\(category.folderName)]: \(finalVideoURL.path)")
        
        // 2. Toevoegen aan iOS Foto's Bibliotheek
        saveVideoToPhotosLibrary(fileURL: finalVideoURL)
        
        // 3. Aangepast Telegram bericht versturen met de categorie en video
        let asset = AVAsset(url: finalVideoURL)
        let durationSec = Int(CMTimeGetSeconds(asset.duration))
        sendCategorizedTelegramVideo(videoURL: finalVideoURL, category: category, durationSeconds: durationSec, date: incidentDate)
        
        // 4. Update UI
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateClipsButtonTitle()
            self.hudLabel.textColor = .systemGreen
            self.hudLabel.text = "💾 [\(category.folderName)] \(category.displayName) opgeslagen!"
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if self.isArmed && !self.isRecording {
                    self.hudLabel.text = "● BEWAKING ACTIEF (ZONE BEWAAKT)"
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
                                      message: "Selecteer een mapje om video's te bekijken:",
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
                // Verwijder ook bijbehorende jpg snapshot
                let snapURL = clip.deletingPathExtension().appendingPathExtension("jpg")
                try? fm.removeItem(at: snapURL)
            }
        }
        updateClipsButtonTitle()
    }

    // MARK: - Telegram Berichten (Foto bij Start & Aangepast Video Bericht bij Einde)
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

        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH:mm:ss"
        let caption = "⚠️ *BEWEGING IN AUTO-ZONE!*\n📅 \(formatter.string(from: Date()))\n🎥 _Video-opname is gestart... Zodra het object uit beeld is wordt het geanalyseerd._"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"snapshot.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    private func sendCategorizedTelegramVideo(videoURL: URL, category: DetectionCategory, durationSeconds: Int, date: Date) {
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

        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH:mm:ss"
        
        // Bericht aangepast op de specifieke categorie
        var header = ""
        switch category {
        case .person:
            header = "🚨 *BEWAKING: PERSOON BIJ AUTO*"
        case .cyclist:
            header = "🚲 *BEWAKING: FIETSER BIJ AUTO*"
        case .car:
            header = "🚗 *BEWAKING: AUTO / VOERTUIG GEDETECTEERD*"
        case .other:
            header = "📦 *BEWAKING: ONBEKEND OBJECT / BEWEGING*"
        }
        
        let caption = """
        \(header)
        📁 Categorie: *\(category.folderName)*
        📅 \(formatter.string(from: date))
        ⏱️ Duur: \(durationSeconds)s
        
        _Object heeft de zone verlaten en is automatisch geclassificeerd._
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
        URLSession.shared.dataTask(with: request).resume()
    }
}

// MARK: - Zone Canvas View
class ZoneCanvasView: UIView {
    var points: [CGPoint] = [] {
        didSet { setNeedsDisplay() }
    }
    
    override func draw(_ rect: CGRect) {
        guard points.count >= 2 else { return }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: points[0].x * bounds.width, y: points[0].y * bounds.height))
        for pt in points.dropFirst() {
            path.addLine(to: CGPoint(x: pt.x * bounds.width, y: pt.y * bounds.height))
        }
        if points.count >= 3 {
            path.close()
            UIColor.systemGreen.withAlphaComponent(0.2).setFill()
            path.fill()
        }
        UIColor.systemGreen.setStroke()
        path.lineWidth = 3
        path.stroke()

        for (idx, pt) in points.enumerated() {
            let circle = UIBezierPath(arcCenter: CGPoint(x: pt.x * bounds.width, y: pt.y * bounds.height),
                                      radius: 6, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            (idx == 0 ? UIColor.systemRed : UIColor.systemBlue).setFill()
            circle.fill()
        }
    }
}
