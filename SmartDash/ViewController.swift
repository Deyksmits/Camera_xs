import UIKit
import CoreLocation
import CoreMotion
import AVFoundation

// MARK: - DashViewController (Flitsmeister / Waze Stijl met HUD & 0-100 Sprint Timer)
class DashViewController: UIViewController, CLLocationManagerDelegate, SpeedCameraManagerDelegate, MotionGForceDetectorDelegate, DualDashcamRecorderDelegate {
    
    // Core Engines
    private let recorder = DualDashcamRecorder()
    private let speedCameraManager = SpeedCameraManager.shared
    private let performanceTimer = PerformanceTimer.shared
    private let motionDetector = MotionGForceDetector.shared
    private let locationManager = CLLocationManager()
    
    // Telemetry State
    private var currentSpeedKmh: Double = 0.0
    private var isHUDMirrored: Bool = false
    private var previousBrightness: CGFloat = 0.5
    
    // MARK: - UI Containers
    private let dashboardContainer = UIView()
    
    // Top Bar (GPS & Opname Status)
    private let topStatusBar = UIStackView()
    private let gpsStatusBadge = UILabel()
    private let recPillView = UIView()
    private let recDot = UIView()
    private let recTextLabel = UILabel()
    private let segmentTimerLabel = UILabel()
    
    // Flitsmeister Radar Alert Card (Vaste Flitspalen & Trajectcontroles)
    private let radarCard = UIView()
    private let radarIconLabel = UILabel()
    private let radarTitleLabel = UILabel()
    private let radarSubtitleLabel = UILabel()
    private let radarLimitBadge = UILabel()
    private let radarProgressBar = UIProgressView(progressViewStyle: .bar)
    private var radarCardHeightConstraint: NSLayoutConstraint?
    
    // Snelheidsmeter Card (Flitsmeister / Waze stijl)
    private let speedCard = UIView()
    private let speedLabel = UILabel()
    private let speedUnitLabel = UILabel()
    private let speedSubStatusLabel = UILabel()
    private let speedRingProgress = UIProgressView(progressViewStyle: .bar)
    
    // 0 - 100 km/u Sprint Performance Card
    private let sprintCard = UIView()
    private let sprintIconLabel = UILabel()
    private let sprintTitleLabel = UILabel()
    private let sprintTimeLabel = UILabel()
    private let sprintRecordLabel = UILabel()
    private let sprintProgressBar = UIProgressView(progressViewStyle: .bar)
    
    // G-Force Telemetry Card
    private let gforceCard = UIView()
    private let gforceCrosshair = UIView()
    private let gforceDot = UIView()
    private let gforceLabel = UILabel()
    private let gforceSubLabel = UILabel()
    
    // Bottom Action Bar (Google Maps / Waze Floating Pills)
    private let bottomControlsStack = UIStackView()
    private let hudMirrorButton = UIButton(type: .system)
    private let lockClipButton = UIButton(type: .system)
    private let galleryButton = UIButton(type: .system)
    private let recordToggleBtn = UIButton(type: .system)
    
    // Noodgeval Schermflits
    private let impactFlashView = UIView()
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    override var prefersStatusBarHidden: Bool {
        return isHUDMirrored
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupEngines()
        setupCarPowerAutomation()
        
        // Start multi-cam 30 FPS en sensoren
        recorder.setupAndStartSession()
        recorder.startRecording()
        motionDetector.start()
        
        // Luister naar 0-100 sprint updates
        setupSprintTimerCallbacks()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        recDot.layer.cornerRadius = recDot.bounds.width / 2
        gforceCrosshair.layer.cornerRadius = gforceCrosshair.bounds.width / 2
        radarLimitBadge.layer.cornerRadius = radarLimitBadge.bounds.width / 2
    }
    
    // MARK: - Layout Setup
    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0)
        
        // Container voor HUD Spiegeling
        dashboardContainer.translatesAutoresizingMaskIntoConstraints = false
        dashboardContainer.backgroundColor = .clear
        view.addSubview(dashboardContainer)
        
        // Tap gesture om HUD modus snel te verlaten
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleScreenTap))
        view.addGestureRecognizer(tap)
        
        // 1. Top Status Bar
        setupTopStatusBar()
        
        // 2. Flitsmeister Radar Card
        setupRadarCard()
        
        // 3. Speedometer Card
        setupSpeedometerCard()
        
        // 4. Middle Dual Tiles: 0-100 Sprint + G-Force
        setupMiddleTiles()
        
        // 5. Bottom Navigation Dock
        setupBottomControls()
        
        // 6. Impact Flash Overlay
        impactFlashView.translatesAutoresizingMaskIntoConstraints = false
        impactFlashView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.4)
        impactFlashView.alpha = 0.0
        impactFlashView.isUserInteractionEnabled = false
        view.addSubview(impactFlashView)
        
        NSLayoutConstraint.activate([
            dashboardContainer.topAnchor.constraint(equalTo: view.topAnchor),
            dashboardContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashboardContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dashboardContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            impactFlashView.topAnchor.constraint(equalTo: view.topAnchor),
            impactFlashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            impactFlashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            impactFlashView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    // MARK: - 1. Top Status Bar
    private func setupTopStatusBar() {
        topStatusBar.translatesAutoresizingMaskIntoConstraints = false
        topStatusBar.axis = .horizontal
        topStatusBar.distribution = .equalSpacing
        topStatusBar.alignment = .center
        dashboardContainer.addSubview(topStatusBar)
        
        // GPS Status Badge
        gpsStatusBadge.text = "🟢 GPS ACTIEF"
        gpsStatusBadge.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        gpsStatusBadge.textColor = UIColor(red: 0.2, green: 0.9, blue: 0.5, alpha: 1.0)
        
        // REC Pill
        recPillView.translatesAutoresizingMaskIntoConstraints = false
        recPillView.backgroundColor = UIColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 0.9)
        recPillView.layer.cornerRadius = 14
        recPillView.layer.borderWidth = 1.0
        recPillView.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        
        let recInnerStack = UIStackView()
        recInnerStack.translatesAutoresizingMaskIntoConstraints = false
        recInnerStack.axis = .horizontal
        recInnerStack.spacing = 6
        recInnerStack.alignment = .center
        recPillView.addSubview(recInnerStack)
        
        recDot.translatesAutoresizingMaskIntoConstraints = false
        recDot.backgroundColor = .systemRed
        NSLayoutConstraint.activate([
            recDot.widthAnchor.constraint(equalToConstant: 8),
            recDot.heightAnchor.constraint(equalToConstant: 8)
        ])
        
        recTextLabel.text = "30 FPS"
        recTextLabel.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        recTextLabel.textColor = .white
        
        segmentTimerLabel.text = "00:00"
        segmentTimerLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        segmentTimerLabel.textColor = .lightGray
        
        recInnerStack.addArrangedSubview(recDot)
        recInnerStack.addArrangedSubview(recTextLabel)
        recInnerStack.addArrangedSubview(segmentTimerLabel)
        
        NSLayoutConstraint.activate([
            recInnerStack.leadingAnchor.constraint(equalTo: recPillView.leadingAnchor, constant: 10),
            recInnerStack.trailingAnchor.constraint(equalTo: recPillView.trailingAnchor, constant: -10),
            recInnerStack.topAnchor.constraint(equalTo: recPillView.topAnchor, constant: 4),
            recInnerStack.bottomAnchor.constraint(equalTo: recPillView.bottomAnchor, constant: -4)
        ])
        
        topStatusBar.addArrangedSubview(gpsStatusBadge)
        topStatusBar.addArrangedSubview(recPillView)
        
        NSLayoutConstraint.activate([
            topStatusBar.topAnchor.constraint(equalTo: dashboardContainer.safeAreaLayoutGuide.topAnchor, constant: 4),
            topStatusBar.leadingAnchor.constraint(equalTo: dashboardContainer.leadingAnchor, constant: 18),
            topStatusBar.trailingAnchor.constraint(equalTo: dashboardContainer.trailingAnchor, constant: -18),
            topStatusBar.heightAnchor.constraint(equalToConstant: 32)
        ])
        
        // Pulserende REC animatie
        UIView.animate(withDuration: 0.8, delay: 0.0, options: [.repeat, .autoreverse], animations: {
            self.recDot.alpha = 0.2
        }, completion: nil)
    }
    
    // MARK: - 2. Flitsmeister Radar Alert Card
    private func setupRadarCard() {
        radarCard.translatesAutoresizingMaskIntoConstraints = false
        radarCard.backgroundColor = UIColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 0.95)
        radarCard.layer.cornerRadius = 18
        radarCard.layer.borderWidth = 1.5
        radarCard.layer.borderColor = UIColor.systemCyan.cgColor
        radarCard.clipsToBounds = true
        radarCard.alpha = 0.0 // Begint verborgen
        dashboardContainer.addSubview(radarCard)
        
        let cardStack = UIStackView()
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.axis = .horizontal
        cardStack.alignment = .center
        cardStack.spacing = 12
        radarCard.addSubview(cardStack)
        
        radarIconLabel.text = "🚨"
        radarIconLabel.font = UIFont.systemFont(ofSize: 28)
        
        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2
        
        radarTitleLabel.text = "FLITSER OVER 500M"
        radarTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .heavy)
        radarTitleLabel.textColor = .white
        
        radarSubtitleLabel.text = "Vaste Flitspaal A2 • Jouw snelheid: Veilig"
        radarSubtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        radarSubtitleLabel.textColor = UIColor(red: 0.8, green: 0.85, blue: 0.95, alpha: 1.0)
        
        textStack.addArrangedSubview(radarTitleLabel)
        textStack.addArrangedSubview(radarSubtitleLabel)
        
        radarLimitBadge.text = "100"
        radarLimitBadge.font = UIFont.systemFont(ofSize: 17, weight: .heavy)
        radarLimitBadge.textColor = .white
        radarLimitBadge.backgroundColor = .systemRed
        radarLimitBadge.textAlignment = .center
        radarLimitBadge.clipsToBounds = true
        radarLimitBadge.widthAnchor.constraint(equalToConstant: 38).isActive = true
        radarLimitBadge.heightAnchor.constraint(equalToConstant: 38).isActive = true
        
        cardStack.addArrangedSubview(radarIconLabel)
        cardStack.addArrangedSubview(textStack)
        cardStack.addArrangedSubview(radarLimitBadge)
        
        radarProgressBar.translatesAutoresizingMaskIntoConstraints = false
        radarProgressBar.progressTintColor = .systemCyan
        radarProgressBar.trackTintColor = UIColor.white.withAlphaComponent(0.1)
        radarProgressBar.progress = 1.0
        radarCard.addSubview(radarProgressBar)
        
        radarCardHeightConstraint = radarCard.heightAnchor.constraint(equalToConstant: 0)
        
        NSLayoutConstraint.activate([
            radarCard.topAnchor.constraint(equalTo: topStatusBar.bottomAnchor, constant: 8),
            radarCard.leadingAnchor.constraint(equalTo: dashboardContainer.leadingAnchor, constant: 16),
            radarCard.trailingAnchor.constraint(equalTo: dashboardContainer.trailingAnchor, constant: -16),
            radarCardHeightConstraint!,
            
            cardStack.leadingAnchor.constraint(equalTo: radarCard.leadingAnchor, constant: 14),
            cardStack.trailingAnchor.constraint(equalTo: radarCard.trailingAnchor, constant: -14),
            cardStack.centerYAnchor.constraint(equalTo: radarCard.centerYAnchor, constant: -2),
            
            radarProgressBar.leadingAnchor.constraint(equalTo: radarCard.leadingAnchor),
            radarProgressBar.trailingAnchor.constraint(equalTo: radarCard.trailingAnchor),
            radarProgressBar.bottomAnchor.constraint(equalTo: radarCard.bottomAnchor),
            radarProgressBar.heightAnchor.constraint(equalToConstant: 4)
        ])
    }
    
    // MARK: - 3. Speedometer Card (Groot, Haarscherp, Flitsmeister Stijl)
    private func setupSpeedometerCard() {
        speedCard.translatesAutoresizingMaskIntoConstraints = false
        speedCard.backgroundColor = UIColor(red: 0.08, green: 0.11, blue: 0.17, alpha: 0.95)
        speedCard.layer.cornerRadius = 24
        speedCard.layer.borderWidth = 1.0
        speedCard.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        dashboardContainer.addSubview(speedCard)
        
        let vertStack = UIStackView()
        vertStack.translatesAutoresizingMaskIntoConstraints = false
        vertStack.axis = .vertical
        vertStack.alignment = .center
        vertStack.spacing = -6
        speedCard.addSubview(vertStack)
        
        speedLabel.text = "0"
        speedLabel.font = UIFont.systemFont(ofSize: 124, weight: .heavy)
        speedLabel.textColor = .white
        speedLabel.textAlignment = .center
        
        speedUnitLabel.text = "KM / U"
        speedUnitLabel.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        speedUnitLabel.textColor = UIColor(red: 0.0, green: 0.85, blue: 0.95, alpha: 1.0)
        
        speedSubStatusLabel.text = "GPS SNELHEID"
        speedSubStatusLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        speedSubStatusLabel.textColor = .lightGray
        
        vertStack.addArrangedSubview(speedLabel)
        vertStack.addArrangedSubview(speedUnitLabel)
        vertStack.addArrangedSubview(speedSubStatusLabel)
        
        speedRingProgress.translatesAutoresizingMaskIntoConstraints = false
        speedRingProgress.progressTintColor = UIColor(red: 0.0, green: 0.85, blue: 0.95, alpha: 1.0)
        speedRingProgress.trackTintColor = UIColor.white.withAlphaComponent(0.06)
        speedRingProgress.progress = 0.0
        speedCard.addSubview(speedRingProgress)
        
        NSLayoutConstraint.activate([
            speedCard.topAnchor.constraint(equalTo: radarCard.bottomAnchor, constant: 10),
            speedCard.leadingAnchor.constraint(equalTo: dashboardContainer.leadingAnchor, constant: 16),
            speedCard.trailingAnchor.constraint(equalTo: dashboardContainer.trailingAnchor, constant: -16),
            speedCard.heightAnchor.constraint(equalToConstant: 185),
            
            vertStack.centerXAnchor.constraint(equalTo: speedCard.centerXAnchor),
            vertStack.centerYAnchor.constraint(equalTo: speedCard.centerYAnchor, constant: -4),
            
            speedRingProgress.leadingAnchor.constraint(equalTo: speedCard.leadingAnchor, constant: 16),
            speedRingProgress.trailingAnchor.constraint(equalTo: speedCard.trailingAnchor, constant: -16),
            speedRingProgress.bottomAnchor.constraint(equalTo: speedCard.bottomAnchor, constant: -10),
            speedRingProgress.heightAnchor.constraint(equalToConstant: 4)
        ])
    }
    
    // MARK: - 4. Middle Dual Tiles: 0-100 Sprint + G-Force Meter
    private func setupMiddleTiles() {
        let tilesStack = UIStackView()
        tilesStack.translatesAutoresizingMaskIntoConstraints = false
        tilesStack.axis = .horizontal
        tilesStack.distribution = .fillEqually
        tilesStack.spacing = 12
        dashboardContainer.addSubview(tilesStack)
        
        // 0-100 Performance Card
        sprintCard.backgroundColor = UIColor(red: 0.08, green: 0.11, blue: 0.17, alpha: 0.95)
        sprintCard.layer.cornerRadius = 20
        sprintCard.layer.borderWidth = 1.0
        sprintCard.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.2).cgColor
        
        let sprintStack = UIStackView()
        sprintStack.translatesAutoresizingMaskIntoConstraints = false
        sprintStack.axis = .vertical
        sprintStack.alignment = .leading
        sprintStack.spacing = 4
        sprintCard.addSubview(sprintStack)
        
        sprintTitleLabel.text = "⚡ 0 - 100 KM/U"
        sprintTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        sprintTitleLabel.textColor = .systemCyan
        
        sprintTimeLabel.text = "GEREED"
        sprintTimeLabel.font = UIFont.systemFont(ofSize: 22, weight: .heavy)
        sprintTimeLabel.textColor = .white
        
        let best = performanceTimer.personalBestTime
        sprintRecordLabel.text = best != nil ? String(format: "🏆 PR: %.2fs", best!) : "Trap het gaspedaal in"
        sprintRecordLabel.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        sprintRecordLabel.textColor = .lightGray
        
        sprintProgressBar.translatesAutoresizingMaskIntoConstraints = false
        sprintProgressBar.progressTintColor = .systemCyan
        sprintProgressBar.trackTintColor = UIColor.white.withAlphaComponent(0.08)
        sprintProgressBar.progress = 0.0
        
        sprintStack.addArrangedSubview(sprintTitleLabel)
        sprintStack.addArrangedSubview(sprintTimeLabel)
        sprintStack.addArrangedSubview(sprintRecordLabel)
        sprintStack.addArrangedSubview(sprintProgressBar)
        
        NSLayoutConstraint.activate([
            sprintStack.leadingAnchor.constraint(equalTo: sprintCard.leadingAnchor, constant: 14),
            sprintStack.trailingAnchor.constraint(equalTo: sprintCard.trailingAnchor, constant: -14),
            sprintStack.topAnchor.constraint(equalTo: sprintCard.topAnchor, constant: 12),
            sprintStack.bottomAnchor.constraint(equalTo: sprintCard.bottomAnchor, constant: -12),
            sprintProgressBar.widthAnchor.constraint(equalTo: sprintStack.widthAnchor),
            sprintProgressBar.heightAnchor.constraint(equalToConstant: 4)
        ])
        
        // G-Force Telemetry Card
        gforceCard.backgroundColor = UIColor(red: 0.08, green: 0.11, blue: 0.17, alpha: 0.95)
        gforceCard.layer.cornerRadius = 20
        gforceCard.layer.borderWidth = 1.0
        gforceCard.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        
        let gStack = UIStackView()
        gStack.translatesAutoresizingMaskIntoConstraints = false
        gStack.axis = .horizontal
        gStack.alignment = .center
        gStack.spacing = 10
        gforceCard.addSubview(gStack)
        
        // Circular crosshair
        gforceCrosshair.translatesAutoresizingMaskIntoConstraints = false
        gforceCrosshair.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0)
        gforceCrosshair.layer.borderWidth = 1.0
        gforceCrosshair.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.4).cgColor
        
        gforceDot.translatesAutoresizingMaskIntoConstraints = false
        gforceDot.backgroundColor = .systemCyan
        gforceDot.layer.cornerRadius = 3.5
        gforceCrosshair.addSubview(gforceDot)
        
        NSLayoutConstraint.activate([
            gforceCrosshair.widthAnchor.constraint(equalToConstant: 46),
            gforceCrosshair.heightAnchor.constraint(equalToConstant: 46),
            gforceDot.centerXAnchor.constraint(equalTo: gforceCrosshair.centerXAnchor),
            gforceDot.centerYAnchor.constraint(equalTo: gforceCrosshair.centerYAnchor),
            gforceDot.widthAnchor.constraint(equalToConstant: 7),
            gforceDot.heightAnchor.constraint(equalToConstant: 7)
        ])
        
        let gTextStack = UIStackView()
        gTextStack.axis = .vertical
        gTextStack.spacing = 2
        
        gforceLabel.text = "0.00 G"
        gforceLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .heavy)
        gforceLabel.textColor = .white
        
        gforceSubLabel.text = "G-FORCE"
        gforceSubLabel.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        gforceSubLabel.textColor = .systemCyan
        
        gTextStack.addArrangedSubview(gforceLabel)
        gTextStack.addArrangedSubview(gforceSubLabel)
        
        gStack.addArrangedSubview(gforceCrosshair)
        gStack.addArrangedSubview(gTextStack)
        
        NSLayoutConstraint.activate([
            gStack.leadingAnchor.constraint(equalTo: gforceCard.leadingAnchor, constant: 12),
            gStack.trailingAnchor.constraint(equalTo: gforceCard.trailingAnchor, constant: -12),
            gStack.centerYAnchor.constraint(equalTo: gforceCard.centerYAnchor)
        ])
        
        tilesStack.addArrangedSubview(sprintCard)
        tilesStack.addArrangedSubview(gforceCard)
        
        NSLayoutConstraint.activate([
            tilesStack.topAnchor.constraint(equalTo: speedCard.bottomAnchor, constant: 12),
            tilesStack.leadingAnchor.constraint(equalTo: dashboardContainer.leadingAnchor, constant: 16),
            tilesStack.trailingAnchor.constraint(equalTo: dashboardContainer.trailingAnchor, constant: -16),
            tilesStack.heightAnchor.constraint(equalToConstant: 95)
        ])
    }
    
    // MARK: - 5. Bottom Navigation Dock (Google Maps / Waze Floating Pills)
    private func setupBottomControls() {
        bottomControlsStack.translatesAutoresizingMaskIntoConstraints = false
        bottomControlsStack.axis = .horizontal
        bottomControlsStack.distribution = .fillEqually
        bottomControlsStack.spacing = 10
        dashboardContainer.addSubview(bottomControlsStack)
        
        configureButton(hudMirrorButton, title: "🪞 HUD", bg: UIColor(red: 0.12, green: 0.18, blue: 0.28, alpha: 1.0))
        hudMirrorButton.addTarget(self, action: #selector(toggleHUDMode), for: .touchUpInside)
        
        configureButton(lockClipButton, title: "🔒 Noodclip", bg: UIColor(red: 0.35, green: 0.12, blue: 0.15, alpha: 1.0))
        lockClipButton.addTarget(self, action: #selector(lockClipTapped), for: .touchUpInside)
        
        configureButton(galleryButton, title: "📁 Ritten", bg: UIColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 1.0))
        galleryButton.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
        
        configureButton(recordToggleBtn, title: "⏹️ Stop", bg: UIColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 1.0))
        recordToggleBtn.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        
        bottomControlsStack.addArrangedSubview(hudMirrorButton)
        bottomControlsStack.addArrangedSubview(lockClipButton)
        bottomControlsStack.addArrangedSubview(galleryButton)
        bottomControlsStack.addArrangedSubview(recordToggleBtn)
        
        NSLayoutConstraint.activate([
            bottomControlsStack.leadingAnchor.constraint(equalTo: dashboardContainer.leadingAnchor, constant: 16),
            bottomControlsStack.trailingAnchor.constraint(equalTo: dashboardContainer.trailingAnchor, constant: -16),
            bottomControlsStack.bottomAnchor.constraint(equalTo: dashboardContainer.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bottomControlsStack.heightAnchor.constraint(equalToConstant: 48)
        ])
    }
    
    private func configureButton(_ btn: UIButton, title: String, bg: UIColor) {
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .heavy)
        btn.backgroundColor = bg
        btn.layer.cornerRadius = 14
        btn.clipsToBounds = true
    }
    
    // MARK: - Setup Engines & Callbacks
    private func setupEngines() {
        recorder.delegate = self
        speedCameraManager.delegate = self
        motionDetector.delegate = self
        
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 0.5
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    // MARK: - 0 - 100 km/u Sprint Callbacks
    private func setupSprintTimerCallbacks() {
        performanceTimer.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch status {
                case .ready:
                    self.sprintTimeLabel.text = "GEREED"
                    self.sprintTimeLabel.textColor = UIColor(red: 0.2, green: 0.9, blue: 0.5, alpha: 1.0)
                    self.sprintProgressBar.setProgress(0.0, animated: false)
                    
                case .running(let elapsed, let speed):
                    self.sprintTimeLabel.text = String(format: "%.1fs", elapsed)
                    self.sprintTimeLabel.textColor = .systemCyan
                    let progress = Float(speed / 100.0)
                    self.sprintProgressBar.setProgress(min(1.0, progress), animated: true)
                    
                case .completed(let result):
                    self.sprintTimeLabel.text = "\(result.formattedTime)s 🏆"
                    self.sprintTimeLabel.textColor = .systemYellow
                    self.sprintProgressBar.setProgress(1.0, animated: true)
                    self.sprintRecordLabel.text = result.isNewPR ? "⚡ NIEUW RECORD!" : String(format: "🏆 PR: %.2fs", self.performanceTimer.personalBestTime ?? result.timeSeconds)
                    
                    // Toon pop-up felicitatie banner
                    let title = result.isNewPR ? "⚡ NIEUW RECORD!" : "🏆 0 - 100 KM/U VOLTOOID"
                    let msg = "Geklokt in \(result.formattedTime) seconde!"
                    let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Geweldig!", style: .default))
                    self.present(alert, animated: true)
                    
                case .idle:
                    let best = self.performanceTimer.personalBestTime
                    self.sprintTimeLabel.text = best != nil ? String(format: "%.2fs", best!) : "--"
                    self.sprintTimeLabel.textColor = .white
                    self.sprintProgressBar.setProgress(0.0, animated: true)
                }
            }
        }
    }
    
    // MARK: - Windshield HUD Mirror Mode (Voorruit Projectie)
    @objc private func toggleHUDMode() {
        isHUDMirrored = !isHUDMirrored
        
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5, options: [], animations: {
            if self.isHUDMirrored {
                // Spiegel horizontaal zodat de weerspiegeling op het raam correct leesbaar is!
                self.dashboardContainer.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                self.previousBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 1.0 // Maximaal fel voor reflectie
                self.hudMirrorButton.setTitle("📱 Scherm", for: .normal)
                self.hudMirrorButton.backgroundColor = .systemCyan
            } else {
                self.dashboardContainer.transform = .identity
                UIScreen.main.brightness = self.previousBrightness
                self.hudMirrorButton.setTitle("🪞 HUD", for: .normal)
                self.hudMirrorButton.backgroundColor = UIColor(red: 0.12, green: 0.18, blue: 0.28, alpha: 1.0)
            }
            self.setNeedsStatusBarAppearanceUpdate()
        }, completion: nil)
    }
    
    @objc private func handleScreenTap() {
        if isHUDMirrored {
            toggleHUDMode()
        }
    }
    
    // MARK: - Auto-Start bij Auto Stroom (Contact Aan / Uit)
    private func setupCarPowerAutomation() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(batteryStateDidChange), name: UIDevice.batteryStateDidChangeNotification, object: nil)
    }
    
    @objc private func batteryStateDidChange() {
        let state = UIDevice.current.batteryState
        let isPlugged = (state == .charging || state == .full)
        
        if isPlugged && !recorder.isRecording {
            print("SmartDash: Stroom gedetecteerd -> Start dashcam opname.")
            recorder.startRecording()
            updateRecordButtonState()
        } else if !isPlugged && recorder.isRecording {
            print("SmartDash: Stroom uit -> Sluit dashcam opname netjes af.")
            recorder.stopRecording { [weak self] in
                self?.updateRecordButtonState()
            }
        }
    }
    
    // MARK: - CLLocationManager Delegate (Snelheid & Flitsers)
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        let rawSpeed = location.speed
        let speed = rawSpeed > 0 ? (rawSpeed * 3.6) : 0.0
        currentSpeedKmh = speed
        
        // Update grote snelheidsmeter
        speedLabel.text = "\(Int(speed))"
        let speedProgress = Float(speed / 160.0)
        speedRingProgress.setProgress(min(1.0, speedProgress), animated: true)
        
        // Check 0-100 sprint timer
        performanceTimer.updateSpeed(kmh: speed)
        
        // Evalueer Flitsers
        speedCameraManager.evaluate(location: location, speedKmh: speed, course: location.course)
    }
    
    // MARK: - SpeedCameraManager Delegate (Flitsmeister Radar Alerts)
    func speedCameraManager(_ manager: SpeedCameraManager, didDetectAlert alert: SpeedCameraAlert) {
        radarTitleLabel.text = "\(alert.camera.type.icon) FLITSER OVER \(alert.formattedDistance.uppercased())"
        radarSubtitleLabel.text = "\(alert.camera.name) • Max \(alert.camera.speedLimit) km/u"
        radarLimitBadge.text = "\(alert.camera.speedLimit)"
        
        let progress = Float(alert.distanceMeters / manager.warningDistanceMeters)
        radarProgressBar.setProgress(max(0.05, min(1.0, progress)), animated: true)
        
        if alert.isSpeeding {
            radarCard.backgroundColor = UIColor(red: 0.28, green: 0.06, blue: 0.08, alpha: 0.98)
            radarCard.layer.borderColor = UIColor.systemRed.cgColor
            radarProgressBar.progressTintColor = .systemRed
            speedLabel.textColor = .systemRed
            speedSubStatusLabel.text = "⚠️ TE SNEL VOOR FLITSER"
            speedSubStatusLabel.textColor = .systemRed
        } else {
            radarCard.backgroundColor = UIColor(red: 0.08, green: 0.14, blue: 0.22, alpha: 0.98)
            radarCard.layer.borderColor = UIColor.systemCyan.cgColor
            radarProgressBar.progressTintColor = .systemCyan
            speedLabel.textColor = .white
            speedSubStatusLabel.text = "VEILIGE SNELHEID"
            speedSubStatusLabel.textColor = UIColor(red: 0.2, green: 0.9, blue: 0.5, alpha: 1.0)
        }
        
        if radarCard.alpha == 0.0 {
            radarCardHeightConstraint?.constant = 68
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.6, options: [], animations: {
                self.radarCard.alpha = 1.0
                self.dashboardContainer.layoutIfNeeded()
            }, completion: nil)
        }
    }
    
    func speedCameraManagerDidClearAlert(_ manager: SpeedCameraManager) {
        radarCardHeightConstraint?.constant = 0
        UIView.animate(withDuration: 0.3, animations: {
            self.radarCard.alpha = 0.0
            self.speedLabel.textColor = .white
            self.speedSubStatusLabel.text = "GPS SNELHEID"
            self.speedSubStatusLabel.textColor = .lightGray
            self.dashboardContainer.layoutIfNeeded()
        })
    }
    
    // MARK: - MotionGForceDetector Delegate
    func motionDetector(_ detector: MotionGForceDetector, didUpdateGForce lateral: Double, longitudinal: Double, total: Double) {
        gforceLabel.text = String(format: "%.2f G", total)
        
        let maxOffset: CGFloat = 16.0
        let x = CGFloat(lateral) * maxOffset
        let y = CGFloat(-longitudinal) * maxOffset
        
        gforceDot.transform = CGAffineTransform(translationX: min(maxOffset, max(-maxOffset, x)),
                                                y: min(maxOffset, max(-maxOffset, y)))
    }
    
    func motionDetector(_ detector: MotionGForceDetector, didDetectImpact gForce: Double) {
        // Noodstop of botsing: direct beide video's vergrendelen!
        recorder.lockCurrentSegment(reason: String(format: "Impact %.2fG", gForce))
        
        UIView.animate(withDuration: 0.15, animations: {
            self.impactFlashView.alpha = 0.8
        }) { _ in
            UIView.animate(withDuration: 0.6, animations: {
                self.impactFlashView.alpha = 0.0
            })
        }
    }
    
    // MARK: - DualDashcamRecorder Delegate
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didUpdateRecordingDuration duration: TimeInterval) {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        segmentTimerLabel.text = String(format: "%02d:%02d", mins, secs)
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didCompleteSegment roadURL: URL, cabinURL: URL?) {
        print("SmartDash: Ritsegment voltooid: \(roadURL.lastPathComponent)")
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didLockSegment url: URL) {
        let toast = UIAlertController(title: "🔒 Rit Beveiligd", message: "De huidige video is vergrendeld en wordt niet overschreven.", preferredStyle: .alert)
        present(toast, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            toast.dismiss(animated: true)
        }
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didUpdateStorageUsage bytesUsed: Int64, maxBytes: Int64) {
        // Stilzwijgend beheerd door de loop buffer
    }
    
    // MARK: - Button Actions
    @objc private func lockClipTapped() {
        recorder.lockCurrentSegment(reason: "Handmatig vergrendeld door bestuurder")
    }
    
    @objc private func galleryTapped() {
        let galleryVC = ClipsGalleryViewController()
        let nav = UINavigationController(rootViewController: galleryVC)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    
    @objc private func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording { [weak self] in
                self?.updateRecordButtonState()
            }
        } else {
            recorder.startRecording()
            updateRecordButtonState()
        }
    }
    
    private func updateRecordButtonState() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let isRec = self.recorder.isRecording
            self.recordToggleBtn.setTitle(isRec ? "⏹️ Stop" : "▶️ Opnemen", for: .normal)
            self.recordToggleBtn.backgroundColor = isRec ? UIColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 1.0) : .systemGreen
            self.recDot.isHidden = !isRec
            self.recTextLabel.text = isRec ? "30 FPS" : "PAUZE"
        }
    }
}
