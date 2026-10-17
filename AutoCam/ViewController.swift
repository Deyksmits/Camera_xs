import UIKit
import AVFoundation
import Vision
import Photos
import AVKit

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {

    // MARK: - Camera & Vision Properties
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let cameraQueue = DispatchQueue(label: "autocam.camera.queue")
    private let visionQueue = DispatchQueue(label: "autocam.vision.queue")
    
    // MARK: - Auto Zone State
    private var polygonPoints: [CGPoint] = [] // Genormaliseerd (0.0 ... 1.0)
    private var isDrawingZone = false
    private var isArmed = false
    private var lastPhotoAlertTime = Date.distantPast
    private let photoAlertCooldown: TimeInterval = 30.0 // Seconden tussen Telegram snapshot meldingen
    
    // MARK: - Video Opname State
    private var isRecording = false
    private var recordingStartTime = Date.distantPast
    private var recordEndTime = Date.distantPast
    private var recordingTimer: Timer?
    private let minRecordDuration: TimeInterval = 12.0 // Minimum opnameduur bij detectie
    private let maxRecordDuration: TimeInterval = 60.0 // Maximale opnameduur aaneengesloten
    private let extendDurationOnMovement: TimeInterval = 6.0 // Verlenging per nieuwe detectie
    
    // MARK: - Telegram Instellingen (Opgeslagen in UserDefaults)
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

    // MARK: - Camera Setup
    private func setupCamera() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720
        
        // Achtercamera instellen
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("Fout bij openen achtercamera")
            return
        }
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        
        // Microfoon toevoegen voor audio bij video-opnames
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }
        
        // Live Video Output voor Vision detectie
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        
        // Movie File Output voor automatische opname bij beweging
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
        // Zorg dat de iPhone Xs continu aan blijft en niet vergrendelt
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - UI Opbouw
    private func setupUI() {
        // Canvas voor het tekenen van de zone
        canvasView.backgroundColor = .clear
        canvasView.isUserInteractionEnabled = true
        view.addSubview(canvasView)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        canvasView.addGestureRecognizer(tapGesture)

        // Status HUD bovenin
        hudLabel.backgroundColor = UIColor(white: 0, alpha: 0.65)
        hudLabel.textColor = .systemGreen
        hudLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        hudLabel.textAlignment = .center
        hudLabel.layer.cornerRadius = 8
        hudLabel.clipsToBounds = true
        hudLabel.text = "● STANDBY | Stel zone in"
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hudLabel)

        // REC Badge (verschijnt bij actieve opname)
        recBadgeView.backgroundColor = UIColor.black.withAlphaComponent(0.7)
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

        // Knoppenbalk onderin (2 rijen voor overzichtelijke bediening)
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

        configureButton(clipsButton, title: "📁 Clips (0)", color: .systemPurple, action: #selector(showClipsGallery))
        configureButton(settingsButton, title: "⚙️ Setup", color: .systemIndigo, action: #selector(showSettings))
        configureButton(stealthButton, title: "🌙 Zwart", color: .black, action: #selector(enableStealthMode))
        stealthButton.layer.borderColor = UIColor.darkGray.cgColor
        stealthButton.layer.borderWidth = 1
        bottomRow.addArrangedSubview(clipsButton)
        bottomRow.addArrangedSubview(settingsButton)
        bottomRow.addArrangedSubview(stealthButton)

        mainStack.addArrangedSubview(topRow)
        mainStack.addArrangedSubview(bottomRow)

        // OLED Stealth Overlay
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
            hudLabel.text = isArmed ? "● BEWAKING ACTIEF (LOKALE A12 AI)" : "● STANDBY"
        }
    }

    @objc private func clearZone() {
        polygonPoints.removeAll()
        canvasView.points = []
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
        if isArmed {
            armButton.setTitle("⏸ Stop", for: .normal)
            armButton.backgroundColor = .systemRed
            hudLabel.textColor = .systemGreen
            hudLabel.text = "● BEWAKING ACTIEF (LOKALE A12 AI)"
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

    // MARK: - Stealth Modus (OLED Zwart Scherm)
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

    // MARK: - Instellingen Dialoog (Telegram)
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
            "text": "✅ *AutoCam Verbinding Geslaagd!*\nJe iPhone Xs staat klaar om meldingen en bewakingsvideo's door te sturen naar je telefoon.",
            "parse_mode": "Markdown"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Apple Vision AI Detectie
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isArmed else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let request = VNDetectHumanRectanglesRequest { [weak self] (req, err) in
            guard let self = self, let observations = req.results as? [VNHumanObservation] else { return }
            
            var personCloseToCar = false
            for person in observations {
                // In Apple Vision is (0,0) linksonder. Reken om naar normale schermcoördinaten:
                let footPoint = CGPoint(x: person.boundingBox.midX, y: 1.0 - person.boundingBox.minY)
                let centerPoint = CGPoint(x: person.boundingBox.midX, y: 1.0 - person.boundingBox.midY)
                
                // Controleer of de persoon binnen of vlakbij de auto staat
                if self.isPointInOrNearPolygon(point: footPoint, polygon: self.polygonPoints) ||
                   self.isPointInOrNearPolygon(point: centerPoint, polygon: self.polygonPoints) {
                    personCloseToCar = true
                    break
                }
            }
            
            if personCloseToCar {
                self.handlePersonDetectedNearCar(pixelBuffer: pixelBuffer)
            }
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    // MARK: - Wiskundige Nabijheidscontrole (Point to Polygon Distance)
    private func distanceFromPoint(p: CGPoint, toSegment v: CGPoint, and w: CGPoint) -> CGFloat {
        let l2 = (v.x - w.x)*(v.x - w.x) + (v.y - w.y)*(v.y - w.y)
        if l2 == 0 { return hypot(p.x - v.x, p.y - v.y) }
        let t = max(0, min(1, ((p.x - v.x)*(w.x - v.x) + (p.y - v.y)*(w.y - v.y)) / l2))
        let projection = CGPoint(x: v.x + t * (w.x - v.x), y: v.y + t * (w.y - v.y))
        return hypot(p.x - projection.x, p.y - projection.y)
    }

    private func isPointInOrNearPolygon(point: CGPoint, polygon: [CGPoint], buffer: CGFloat = 0.08) -> Bool {
        guard polygon.count >= 3 else { return true } // Als geen zone getekend is: heel beeld beveiligen
        let path = UIBezierPath()
        path.move(to: polygon[0])
        for pt in polygon.dropFirst() { path.addLine(to: pt) }
        path.close()
        
        if path.contains(point) { return true }
        
        // Controleer nabijheid tot de rand van de auto (buffer van ~8% beeldscherm)
        for i in 0..<polygon.count {
            let p1 = polygon[i]
            let p2 = polygon[(i + 1) % polygon.count]
            if distanceFromPoint(p: point, toSegment: p1, and: p2) <= buffer {
                return true
            }
        }
        return false
    }

    // MARK: - Afhandeling Persoon bij Auto
    private func handlePersonDetectedNearCar(pixelBuffer: CVPixelBuffer) {
        // 1. Directe Foto Snapshot Melding naar Telegram (met cooldown van 30s)
        let now = Date()
        if now.timeIntervalSince(lastPhotoAlertTime) > photoAlertCooldown {
            lastPhotoAlertTime = now
            sendInstantPhotoAlert(pixelBuffer: pixelBuffer)
        }
        
        // 2. Start of Verleng Automatische Video-Opname
        DispatchQueue.main.async { [weak self] in
            self?.triggerOrExtendVideoRecording()
        }
    }

    private func sendInstantPhotoAlert(pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else { return }

        sendTelegramPhoto(jpegData: jpegData)
    }

    // MARK: - Video Opname Logica
    private func triggerOrExtendVideoRecording() {
        guard isArmed else { return }
        
        if !isRecording {
            startVideoRecording()
        } else {
            // Verleng de actieve opname zolang de persoon bij de auto blijft
            let newEnd = Date().addingTimeInterval(extendDurationOnMovement)
            if newEnd.timeIntervalSince(recordingStartTime) <= maxRecordDuration {
                recordEndTime = max(recordEndTime, newEnd)
            }
        }
    }

    private func startVideoRecording() {
        guard !movieOutput.isRecording else { return }
        
        // Zorg dat de opnamemap bestaat in Documents
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingsFolder = docs.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: recordingsFolder.path) {
            try? FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "AutoCam_\(formatter.string(from: Date())).mp4"
        let outputURL = recordingsFolder.appendingPathComponent(filename)
        
        // Zorg voor juiste oriëntatie
        if let connection = movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        
        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        isRecording = true
        recordingStartTime = Date()
        recordEndTime = Date().addingTimeInterval(minRecordDuration)
        
        updateRecordingUI(active: true)
        
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.recordingStartTime))
            self.hudLabel.text = "🔴 OPNEMEN: PERSOON BIJ AUTO (\(elapsed)s)"
            
            // Controleer of de opname moet stoppen
            if Date() >= self.recordEndTime || Date().timeIntervalSince(self.recordingStartTime) >= self.maxRecordDuration {
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
            hudLabel.text = "🔴 OPNEMEN: PERSOON BIJ AUTO"
        } else {
            hudLabel.textColor = .systemGreen
            hudLabel.text = isArmed ? "● BEWAKING ACTIEF (LOKALE A12 AI)" : "● STANDBY"
        }
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate (Opname Afgerond)
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.updateRecordingUI(active: false)
            self?.updateClipsButtonTitle()
        }
        
        guard error == nil else {
            print("Fout bij opslaan opname: \(String(describing: error))")
            return
        }
        
        print("✅ Bewakingsvideo succesvol opgeslagen op: \(outputFileURL.path)")
        
        // 1. Opslaan in de iOS Galerij / Camera Roll
        saveVideoToPhotosLibrary(fileURL: outputFileURL)
        
        // 2. Video rechtstreeks doorsturen naar de Telegram bot
        sendTelegramVideo(videoURL: outputFileURL)
        
        DispatchQueue.main.async {
            self.hudLabel.textColor = .systemGreen
            self.hudLabel.text = "💾 Bewakingsvideo opgeslagen & verzonden!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if self.isArmed && !self.isRecording {
                    self.hudLabel.text = "● BEWAKING ACTIEF (LOKALE A12 AI)"
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
            }) { success, error in
                if success {
                    print("✅ Bewakingsvideo toegevoegd aan iOS Foto's")
                } else {
                    print("Kon video niet toevoegen aan Foto's: \(String(describing: error))")
                }
            }
        }
    }

    // MARK: - Clips Beheer & Galerij Viewer
    private var recordingsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Recordings", isDirectory: true)
    }

    private func getSavedClips() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else {
            return []
        }
        return files.filter { $0.pathExtension.lowercased() == "mp4" || $0.pathExtension.lowercased() == "mov" }
            .sorted { url1, url2 in
                let d1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let d2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return d1 > d2
            }
    }

    private func updateClipsButtonTitle() {
        let count = getSavedClips().count
        clipsButton.setTitle("📁 Clips (\(count))", for: .normal)
    }

    @objc private func showClipsGallery() {
        let clips = getSavedClips()
        let alert = UIAlertController(title: "Opgenomen Bewakingsvideo's",
                                      message: clips.isEmpty ? "Er zijn nog geen video's opgenomen." : "\(clips.count) video('s) bewaard in Bestanden & Foto's.",
                                      preferredStyle: .actionSheet)
        
        for clip in clips.prefix(5) {
            let name = clip.lastPathComponent
            let size = (try? clip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let mb = String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
            
            alert.addAction(UIAlertAction(title: "▶️ \(name) (\(mb))", style: .default, handler: { [weak self] _ in
                self?.playVideo(url: clip)
            }))
        }
        
        if clips.count > 5 {
            alert.addAction(UIAlertAction(title: "... en nog \(clips.count - 5) eerdere video's", style: .default, handler: nil))
        }
        
        if !clips.isEmpty {
            alert.addAction(UIAlertAction(title: "🗑 Wis Alle Opnames", style: .destructive, handler: { [weak self] _ in
                self?.clearAllClips()
            }))
        }
        
        alert.addAction(UIAlertAction(title: "Sluiten", style: .cancel))
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
        let clips = getSavedClips()
        for clip in clips {
            try? fm.removeItem(at: clip)
        }
        updateClipsButtonTitle()
    }

    // MARK: - Telegram Communicatie (Foto & Video)
    private func sendTelegramPhoto(jpegData: Data) {
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
        let caption = "🚨 *ALARM: Persoon gesignaleerd bij je auto!*\n📅 \(formatter.string(from: Date()))\n🎥 _Video-opname is gestart..._"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"alarm.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        URLSession.shared.dataTask(with: request) { _, _, _ in
            print("Snapshot notificatie verzonden naar Telegram")
        }.resume()
    }

    private func sendTelegramVideo(videoURL: URL) {
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
        let caption = "🎥 *BEWAKINGSVIDEO: Persoon bij je auto!*\n📅 \(formatter.string(from: Date()))"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"video\"; filename=\"surveillance.mp4\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(videoData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        URLSession.shared.dataTask(with: request) { _, _, _ in
            print("Bewakingsvideo verzonden naar Telegram")
        }.resume()
    }
}

// MARK: - Hulpscherm voor het renderen van de getekende auto zone
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
