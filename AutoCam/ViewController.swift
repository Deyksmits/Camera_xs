import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Camera & Vision Properties
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let videoOutput = AVCaptureVideoDataOutput()
    private let cameraQueue = DispatchQueue(label: "autocam.camera.queue")
    private let visionQueue = DispatchQueue(label: "autocam.vision.queue")
    
    // MARK: - Auto Zone State
    private var polygonPoints: [CGPoint] = [] // Genormaliseerd (0.0 ... 1.0)
    private var isDrawingZone = false
    private var isArmed = false
    private var lastAlertTime = Date.distantPast
    private let alertCooldown: TimeInterval = 30.0 // Seconden tussen meldingen
    
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
    private let armButton = UIButton(type: .system)
    private let editZoneButton = UIButton(type: .system)
    private let clearZoneButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let stealthButton = UIButton(type: .system)
    private let stealthOverlay = UIView()
    private let stealthClockLabel = UILabel()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        loadSavedPolygon()
        setupCamera()
        setupUI()
        setupWakeLock()
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
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("Fout bij openen camera")
            return
        }
        
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        
        videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        
        captureSession.commitConfiguration()
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)
        
        cameraQueue.async {
            self.captureSession.startRunning()
        }
    }

    private func setupWakeLock() {
        // Zorg dat de iPhone Xs NOOIT naar het vergrendelscherm gaat
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

        // Status HUD
        hudLabel.backgroundColor = UIColor(white: 0, alpha: 0.6)
        hudLabel.textColor = .systemGreen
        hudLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        hudLabel.textAlignment = .center
        hudLabel.layer.cornerRadius = 8
        hudLabel.clipsToBounds = true
        hudLabel.text = "● STANDBY | Stel zone in"
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hudLabel)

        // Knoppenbalk onderin
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        configureButton(armButton, title: "▶ Start", color: .systemGreen, action: #selector(toggleArm))
        configureButton(editZoneButton, title: "✏️ Zone", color: .systemBlue, action: #selector(toggleEditZone))
        configureButton(clearZoneButton, title: "🗑 Wis", color: .systemGray, action: #selector(clearZone))
        configureButton(settingsButton, title: "⚙️ Setup", color: .systemIndigo, action: #selector(showSettings))
        configureButton(stealthButton, title: "🌙 Zwart", color: .black, action: #selector(enableStealthMode))
        stealthButton.layer.borderColor = UIColor.darkGray.cgColor
        stealthButton.layer.borderWidth = 1

        stackView.addArrangedSubview(armButton)
        stackView.addArrangedSubview(editZoneButton)
        stackView.addArrangedSubview(clearZoneButton)
        stackView.addArrangedSubview(settingsButton)
        stackView.addArrangedSubview(stealthButton)

        // OLED Stealth Overlay
        stealthOverlay.backgroundColor = .black
        stealthOverlay.isHidden = true
        let stealthTap = UITapGestureRecognizer(target: self, action: #selector(disableStealthMode))
        stealthOverlay.addGestureRecognizer(stealthTap)
        view.addSubview(stealthOverlay)

        stealthClockLabel.textColor = UIColor(white: 0.2, alpha: 1)
        stealthClockLabel.font = UIFont.monospacedSystemFont(ofSize: 28, weight: .bold)
        stealthClockLabel.textAlignment = .center
        stealthClockLabel.translatesAutoresizingMaskIntoConstraints = false
        stealthOverlay.addSubview(stealthClockLabel)

        NSLayoutConstraint.activate([
            hudLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            hudLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hudLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            hudLabel.heightAnchor.constraint(equalToConstant: 34),

            stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stackView.heightAnchor.constraint(equalToConstant: 44),

            stealthClockLabel.centerXAnchor.constraint(equalTo: stealthOverlay.centerXAnchor),
            stealthClockLabel.centerYAnchor.constraint(equalTo: stealthOverlay.centerYAnchor)
        ])
    }

    private func configureButton(_ btn: UIButton, title: String, color: UIColor, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = color
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
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
            hudLabel.text = "Tik op het scherm om zone om de auto te maken"
        } else {
            editZoneButton.setTitle("✏️ Zone", for: .normal)
            editZoneButton.backgroundColor = .systemBlue
            hudLabel.text = isArmed ? "● BEWAKING ACTIEF" : "● STANDBY"
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
            "text": "✅ *Verbinding geslaagd!*\nJe oude iPhone Xs is succesvol gekoppeld aan je nieuwe telefoon.",
            "parse_mode": "Markdown"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - AVCaptureOutput & Apple Vision AI Verwerking
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isArmed else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let request = VNDetectHumanRectanglesRequest { [weak self] (req, err) in
            guard let self = self, let observations = req.results as? [VNHumanObservation] else { return }
            
            for person in observations {
                // In Vision is Y = 0 onderin. Reken om naar schermcoördinaten:
                let footPoint = CGPoint(x: person.boundingBox.midX, y: 1.0 - person.boundingBox.minY)
                
                if self.isPointInPolygon(point: footPoint, polygon: self.polygonPoints) {
                    self.triggerAlarm(pixelBuffer: pixelBuffer)
                    break
                }
            }
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    // MARK: - Polygoon Controle
    private func isPointInPolygon(point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return true }
        let path = UIBezierPath()
        path.move(to: polygon[0])
        for pt in polygon.dropFirst() { path.addLine(to: pt) }
        path.close()
        return path.contains(point)
    }

    // MARK: - Alarm & Foto Verzenden
    private func triggerAlarm(pixelBuffer: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastAlertTime) > alertCooldown else { return }
        lastAlertTime = now

        DispatchQueue.main.async {
            self.hudLabel.textColor = .systemRed
            self.hudLabel.text = "🚨 ALARM: PERSOON IN AUTOZONE!"
        }

        // Converteer CVPixelBuffer naar JPEG
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else { return }

        sendTelegramAlert(jpegData: jpegData)
    }

    private func sendTelegramAlert(jpegData: Data) {
        guard !botToken.isEmpty, !chatId.isEmpty else { return }
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendPhoto")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // Chat ID
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)
        // Caption
        let caption = "🚨 *ALARM: Persoon gesignaleerd bij je auto!*\n📅 \(Date().formatted())"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)
        // Foto
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"alarm.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        URLSession.shared.dataTask(with: request) { _, _, _ in
            print("Notificatie verzonden naar Telegram")
        }.resume()
    }
}

// Hulpscherm voor het renderen van de getekende auto zone
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

        // Teken punten
        for (idx, pt) in points.enumerated() {
            let circle = UIBezierPath(arcCenter: CGPoint(x: pt.x * bounds.width, y: pt.y * bounds.height),
                                      radius: 6, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            (idx == 0 ? UIColor.systemRed : UIColor.systemBlue).setFill()
            circle.fill()
        }
    }
}
