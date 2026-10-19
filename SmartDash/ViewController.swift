import UIKit
import CoreLocation
import CoreMotion
import AVFoundation

// MARK: - Cockpit Thema
enum CockpitTheme: String, CaseIterable {
    case cyberNeon = "Cyber Neon"
    case nightRed = "Nacht Rood"
    case minimalist = "Minimalistisch"
    
    var accentColor: UIColor {
        switch self {
        case .cyberNeon: return UIColor.systemCyan
        case .nightRed: return UIColor.systemRed
        case .minimalist: return UIColor.white
        }
    }
    
    var secondaryColor: UIColor {
        switch self {
        case .cyberNeon: return UIColor(red: 0.0, green: 0.9, blue: 0.7, alpha: 1.0)
        case .nightRed: return UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1.0)
        case .minimalist: return UIColor.lightGray
        }
    }
}

// MARK: - DashViewController (Digital Cockpit Dashboard HUD)
class DashViewController: UIViewController, CLLocationManagerDelegate, SpeedCameraManagerDelegate, TrafficSignDetectorDelegate, MotionGForceDetectorDelegate, DualDashcamRecorderDelegate {
    
    // Core Engines
    private let recorder = DualDashcamRecorder()
    private let speedCameraManager = SpeedCameraManager.shared
    private let trafficSignDetector = TrafficSignDetector()
    private let motionDetector = MotionGForceDetector.shared
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    
    // Thema
    private var currentTheme: CockpitTheme = .cyberNeon
    
    // Driving Telemetry State
    private var currentSpeedKmh: Double = 0.0
    private var detectedSpeedLimit: Int?
    private var activeCameraAlert: SpeedCameraAlert?
    private var tripDistanceMeters: Double = 0.0
    private var lastLocation: CLLocation?
    private var tripStartTime = Date()
    private var tripTimer: Timer?
    private var lastGeocodeTime = Date.distantPast
    private var currentStreetName: String = "GPS Actief..."
    
    // MARK: - UI Components (Digital Cockpit)
    private let backgroundView = UIView()
    
    // Top Bar (REC status, Dual-cam indicator, Storage)
    private let topStatusBar = UIStackView()
    private let recIndicatorView = UIView()
    private let recDot = UIView()
    private let recLabel = UILabel()
    private let dualCamBadge = UILabel()
    private let segmentTimerLabel = UILabel()
    private let storageLabel = UILabel()
    
    // Radar Flitser Alert Card
    private let radarCard = UIView()
    private let radarIconLabel = UILabel()
    private let radarTitleLabel = UILabel()
    private let radarDistanceLabel = UILabel()
    private let radarLimitBadge = UILabel()
    private let radarProgressBar = UIProgressView(progressViewStyle: .bar)
    private var radarCardTopConstraint: NSLayoutConstraint?
    
    // Center Section: Speedometer & Road Sign
    private let centerStackView = UIStackView()
    private let speedContainer = UIView()
    private let speedLabel = UILabel()
    private let speedUnitLabel = UILabel()
    private let speedDeltaLabel = UILabel()
    
    // RVV Snelheidsbord Badge (Ronde cirkel met rode rand)
    private let signContainer = UIView()
    private let signRedBorder = UIView()
    private let signWhiteDisc = UIView()
    private let signNumberLabel = UILabel()
    private let signSubLabel = UILabel()
    
    // G-Force Meter & Telemetry
    private let telemetryStack = UIStackView()
    private let gforceContainer = UIView()
    private let gforceCrosshair = UIView()
    private let gforceDot = UIView()
    private let gforceLabel = UILabel()
    
    // Trip Info
    private let compassLabel = UILabel()
    private let streetLabel = UILabel()
    private let tripOdoLabel = UILabel()
    private let tripDurationLabel = UILabel()
    
    // Bottom Controls
    private let bottomControlsStack = UIStackView()
    private let lockClipButton = UIButton(type: .system)
    private let galleryButton = UIButton(type: .system)
    private let themeButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    
    // Impact Flash Banner
    private let impactFlashView = UIView()
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    override var prefersStatusBarHidden: Bool {
        return false
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCockpitLayout()
        setupDelegatesAndEngines()
        setupCarPowerAutomation()
        applyTheme(currentTheme)
        
        // Start dual-cam hardware op 30 FPS en automatische ritregistratie
        recorder.setupAndStartSession()
        recorder.startRecording()
        motionDetector.start()
        startTripTracking()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        signRedBorder.layer.cornerRadius = signRedBorder.bounds.width / 2
        signWhiteDisc.layer.cornerRadius = signWhiteDisc.bounds.width / 2
        gforceContainer.layer.cornerRadius = gforceContainer.bounds.width / 2
        recDot.layer.cornerRadius = recDot.bounds.width / 2
    }
    
    // MARK: - Setup Layout (NO CAMERA PREVIEW - Pure Cockpit HUD)
    private func setupCockpitLayout() {
        view.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1.0)
        
        // Background Gradient
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = .clear
        view.addSubview(backgroundView)
        
        // Top Status Bar
        setupTopStatusBar()
        
        // Radar Alert Card (Initially hidden above screen)
        setupRadarCard()
        
        // Center Speed & Sign Recognition Section
        setupCenterSpeedSection()
        
        // Telemetry & G-Force Meter
        setupTelemetrySection()
        
        // Bottom Action Controls
        setupBottomControls()
        
        // Impact Flash Overlay
        impactFlashView.translatesAutoresizingMaskIntoConstraints = false
        impactFlashView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.4)
        impactFlashView.alpha = 0.0
        impactFlashView.isUserInteractionEnabled = false
        view.addSubview(impactFlashView)
        
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            impactFlashView.topAnchor.constraint(equalTo: view.topAnchor),
            impactFlashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            impactFlashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            impactFlashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    // MARK: - Top Status Bar
    private func setupTopStatusBar() {
        topStatusBar.translatesAutoresizingMaskIntoConstraints = false
        topStatusBar.axis = .horizontal
        topStatusBar.distribution = .equalSpacing
        topStatusBar.alignment = .center
        view.addSubview(topStatusBar)
        
        // REC Dot & Label
        let recStack = UIStackView()
        recStack.axis = .horizontal
        recStack.spacing = 6
        recStack.alignment = .center
        
        recDot.translatesAutoresizingMaskIntoConstraints = false
        recDot.backgroundColor = .systemRed
        NSLayoutConstraint.activate([
            recDot.widthAnchor.constraint(equalToConstant: 10),
            recDot.heightAnchor.constraint(equalToConstant: 10)
        ])
        
        recLabel.text = "REC 30 FPS"
        recLabel.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        recLabel.textColor = .white
        
        recStack.addArrangedSubview(recDot)
        recStack.addArrangedSubview(recLabel)
        
        // Dual-Cam Badge
        dualCamBadge.text = "DUAL-CAM (WEG + CABINE)"
        dualCamBadge.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        dualCamBadge.textColor = .systemCyan
        dualCamBadge.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.15)
        dualCamBadge.layer.cornerRadius = 6
        dualCamBadge.clipsToBounds = true
        
        // Segment Timer & Opslag
        let statsStack = UIStackView()
        statsStack.axis = .horizontal
        statsStack.spacing = 8
        statsStack.alignment = .center
        
        segmentTimerLabel.text = "00:00 / 03:00"
        segmentTimerLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        segmentTimerLabel.textColor = .lightGray
        
        storageLabel.text = "0.0 GB"
        storageLabel.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        storageLabel.textColor = .gray
        
        statsStack.addArrangedSubview(segmentTimerLabel)
        statsStack.addArrangedSubview(storageLabel)
        
        topStatusBar.addArrangedSubview(recStack)
        topStatusBar.addArrangedSubview(dualCamBadge)
        topStatusBar.addArrangedSubview(statsStack)
        
        NSLayoutConstraint.activate([
            topStatusBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            topStatusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topStatusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            topStatusBar.heightAnchor.constraint(equalToConstant: 32)
        ])
        
        // Pulseer REC Dot
        UIView.animate(withDuration: 0.8, delay: 0.0, options: [.repeat, .autoreverse], animations: {
            self.recDot.alpha = 0.2
        }, completion: nil)
    }
    
    // MARK: - Radar Flitser Alert Card (Flitsmeister / Waze stijl)
    private func setupRadarCard() {
        radarCard.translatesAutoresizingMaskIntoConstraints = false
        radarCard.backgroundColor = UIColor(red: 0.12, green: 0.05, blue: 0.05, alpha: 0.95)
        radarCard.layer.cornerRadius = 14
        radarCard.layer.borderWidth = 1.5
        radarCard.layer.borderColor = UIColor.systemRed.cgColor
        radarCard.clipsToBounds = true
        radarCard.alpha = 0.0
        view.addSubview(radarCard)
        
        let cardStack = UIStackView()
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.axis = .horizontal
        cardStack.alignment = .center
        cardStack.spacing = 12
        radarCard.addSubview(cardStack)
        
        radarIconLabel.text = "🚨"
        radarIconLabel.font = UIFont.systemFont(ofSize: 32)
        
        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 3
        
        radarTitleLabel.text = "FLITSER OVER 500M"
        radarTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .heavy)
        radarTitleLabel.textColor = .white
        
        radarDistanceLabel.text = "Vaste Flitspaal A2 • Max 100 km/h"
        radarDistanceLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        radarDistanceLabel.textColor = UIColor(red: 1.0, green: 0.8, blue: 0.8, alpha: 1.0)
        
        textStack.addArrangedSubview(radarTitleLabel)
        textStack.addArrangedSubview(radarDistanceLabel)
        
        radarLimitBadge.text = "100"
        radarLimitBadge.font = UIFont.systemFont(ofSize: 18, weight: .heavy)
        radarLimitBadge.textColor = .white
        radarLimitBadge.backgroundColor = .systemRed
        radarLimitBadge.textAlignment = .center
        radarLimitBadge.layer.cornerRadius = 18
        radarLimitBadge.clipsToBounds = true
        radarLimitBadge.widthAnchor.constraint(equalToConstant: 36).isActive = true
        radarLimitBadge.heightAnchor.constraint(equalToConstant: 36).isActive = true
        
        cardStack.addArrangedSubview(radarIconLabel)
        cardStack.addArrangedSubview(textStack)
        cardStack.addArrangedSubview(radarLimitBadge)
        
        radarProgressBar.translatesAutoresizingMaskIntoConstraints = false
        radarProgressBar.progressTintColor = .systemRed
        radarProgressBar.trackTintColor = UIColor.white.withAlphaComponent(0.2)
        radarProgressBar.progress = 1.0
        radarCard.addSubview(radarProgressBar)
        
        radarCardTopConstraint = radarCard.topAnchor.constraint(equalTo: topStatusBar.bottomAnchor, constant: -100)
        
        NSLayoutConstraint.activate([
            radarCardTopConstraint!,
            radarCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            radarCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            radarCard.heightAnchor.constraint(equalToConstant: 68),
            
            cardStack.leadingAnchor.constraint(equalTo: radarCard.leadingAnchor, constant: 14),
            cardStack.trailingAnchor.constraint(equalTo: radarCard.trailingAnchor, constant: -14),
            cardStack.topAnchor.constraint(equalTo: radarCard.topAnchor, constant: 8),
            
            radarProgressBar.leadingAnchor.constraint(equalTo: radarCard.leadingAnchor),
            radarProgressBar.trailingAnchor.constraint(equalTo: radarCard.trailingAnchor),
            radarProgressBar.bottomAnchor.constraint(equalTo: radarCard.bottomAnchor),
            radarProgressBar.heightAnchor.constraint(equalToConstant: 4)
        ])
    }
    
    // MARK: - Center Speed Section & Road Sign Badge
    private func setupCenterSpeedSection() {
        centerStackView.translatesAutoresizingMaskIntoConstraints = false
        centerStackView.axis = .horizontal
        centerStackView.alignment = .center
        centerStackView.distribution = .fillProportionally
        centerStackView.spacing = 16
        view.addSubview(centerStackView)
        
        // Speed Display Container
        speedContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let speedVertStack = UIStackView()
        speedVertStack.translatesAutoresizingMaskIntoConstraints = false
        speedVertStack.axis = .vertical
        speedVertStack.alignment = .center
        speedVertStack.spacing = -8
        speedContainer.addSubview(speedVertStack)
        
        speedLabel.text = "0"
        speedLabel.font = UIFont.systemFont(ofSize: 116, weight: .heavy)
        speedLabel.textColor = .white
        speedLabel.textAlignment = .center
        
        speedUnitLabel.text = "KM/H"
        speedUnitLabel.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        speedUnitLabel.textColor = .systemCyan
        
        speedDeltaLabel.text = "VEILIG"
        speedDeltaLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        speedDeltaLabel.textColor = .systemGreen
        
        speedVertStack.addArrangedSubview(speedLabel)
        speedVertStack.addArrangedSubview(speedUnitLabel)
        speedVertStack.addArrangedSubview(speedDeltaLabel)
        
        NSLayoutConstraint.activate([
            speedVertStack.topAnchor.constraint(equalTo: speedContainer.topAnchor),
            speedVertStack.leadingAnchor.constraint(equalTo: speedContainer.leadingAnchor),
            speedVertStack.trailingAnchor.constraint(equalTo: speedContainer.trailingAnchor),
            speedVertStack.bottomAnchor.constraint(equalTo: speedContainer.bottomAnchor)
        ])
        
        // RVV Snelheidsbord Badge (Borddetectie weergave)
        setupSpeedSignView()
        
        centerStackView.addArrangedSubview(speedContainer)
        centerStackView.addArrangedSubview(signContainer)
        
        NSLayoutConstraint.activate([
            centerStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            centerStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            centerStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            centerStackView.heightAnchor.constraint(equalToConstant: 180)
        ])
    }
    
    private func setupSpeedSignView() {
        signContainer.translatesAutoresizingMaskIntoConstraints = false
        signContainer.widthAnchor.constraint(equalToConstant: 110).isActive = true
        signContainer.heightAnchor.constraint(equalToConstant: 130).isActive = true
        
        signRedBorder.translatesAutoresizingMaskIntoConstraints = false
        signRedBorder.backgroundColor = UIColor(red: 0.95, green: 0.15, blue: 0.15, alpha: 1.0)
        signContainer.addSubview(signRedBorder)
        
        signWhiteDisc.translatesAutoresizingMaskIntoConstraints = false
        signWhiteDisc.backgroundColor = .white
        signRedBorder.addSubview(signWhiteDisc)
        
        signNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        signNumberLabel.text = "--"
        signNumberLabel.font = UIFont.systemFont(ofSize: 38, weight: .heavy)
        signNumberLabel.textColor = .black
        signNumberLabel.textAlignment = .center
        signWhiteDisc.addSubview(signNumberLabel)
        
        signSubLabel.translatesAutoresizingMaskIntoConstraints = false
        signSubLabel.text = "BORD SCAN"
        signSubLabel.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        signSubLabel.textColor = .lightGray
        signSubLabel.textAlignment = .center
        signContainer.addSubview(signSubLabel)
        
        NSLayoutConstraint.activate([
            signRedBorder.topAnchor.constraint(equalTo: signContainer.topAnchor),
            signRedBorder.centerXAnchor.constraint(equalTo: signContainer.centerXAnchor),
            signRedBorder.widthAnchor.constraint(equalToConstant: 96),
            signRedBorder.heightAnchor.constraint(equalToConstant: 96),
            
            signWhiteDisc.centerXAnchor.constraint(equalTo: signRedBorder.centerXAnchor),
            signWhiteDisc.centerYAnchor.constraint(equalTo: signRedBorder.centerYAnchor),
            signWhiteDisc.widthAnchor.constraint(equalToConstant: 74),
            signWhiteDisc.heightAnchor.constraint(equalToConstant: 74),
            
            signNumberLabel.centerXAnchor.constraint(equalTo: signWhiteDisc.centerXAnchor),
            signNumberLabel.centerYAnchor.constraint(equalTo: signWhiteDisc.centerYAnchor),
            
            signSubLabel.topAnchor.constraint(equalTo: signRedBorder.bottomAnchor, constant: 6),
            signSubLabel.centerXAnchor.constraint(equalTo: signContainer.centerXAnchor)
        ])
    }
    
    // MARK: - Telemetry & G-Force Meter
    private func setupTelemetrySection() {
        telemetryStack.translatesAutoresizingMaskIntoConstraints = false
        telemetryStack.axis = .horizontal
        telemetryStack.distribution = .equalCentering
        telemetryStack.alignment = .center
        view.addSubview(telemetryStack)
        
        // G-Force Circular Crosshair
        gforceContainer.translatesAutoresizingMaskIntoConstraints = false
        gforceContainer.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 0.8)
        gforceContainer.layer.borderWidth = 1.0
        gforceContainer.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.4).cgColor
        
        gforceCrosshair.translatesAutoresizingMaskIntoConstraints = false
        gforceCrosshair.backgroundColor = .clear
        gforceContainer.addSubview(gforceCrosshair)
        
        gforceDot.translatesAutoresizingMaskIntoConstraints = false
        gforceDot.backgroundColor = .systemCyan
        gforceDot.layer.cornerRadius = 4
        gforceContainer.addSubview(gforceDot)
        
        gforceLabel.translatesAutoresizingMaskIntoConstraints = false
        gforceLabel.text = "0.00 G"
        gforceLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        gforceLabel.textColor = .systemCyan
        gforceLabel.textAlignment = .center
        gforceContainer.addSubview(gforceLabel)
        
        NSLayoutConstraint.activate([
            gforceContainer.widthAnchor.constraint(equalToConstant: 76),
            gforceContainer.heightAnchor.constraint(equalToConstant: 76),
            
            gforceDot.centerXAnchor.constraint(equalTo: gforceContainer.centerXAnchor),
            gforceDot.centerYAnchor.constraint(equalTo: gforceContainer.centerYAnchor),
            gforceDot.widthAnchor.constraint(equalToConstant: 8),
            gforceDot.heightAnchor.constraint(equalToConstant: 8),
            
            gforceLabel.bottomAnchor.constraint(equalTo: gforceContainer.bottomAnchor, constant: -4),
            gforceLabel.centerXAnchor.constraint(equalTo: gforceContainer.centerXAnchor)
        ])
        
        // Trip Stats Info
        let tripStatsStack = UIStackView()
        tripStatsStack.axis = .vertical
        tripStatsStack.spacing = 4
        tripStatsStack.alignment = .leading
        
        streetLabel.text = "📍 Zoeken naar weg..."
        streetLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        streetLabel.textColor = .white
        
        compassLabel.text = "🧭 000° N"
        compassLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        compassLabel.textColor = .lightGray
        
        tripOdoLabel.text = "🛣️ Rit: 0.0 km"
        tripOdoLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        tripOdoLabel.textColor = .lightGray
        
        tripDurationLabel.text = "⏱️ Duur: 00:00:00"
        tripDurationLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        tripDurationLabel.textColor = .lightGray
        
        tripStatsStack.addArrangedSubview(streetLabel)
        tripStatsStack.addArrangedSubview(compassLabel)
        tripStatsStack.addArrangedSubview(tripOdoLabel)
        tripStatsStack.addArrangedSubview(tripDurationLabel)
        
        telemetryStack.addArrangedSubview(gforceContainer)
        telemetryStack.addArrangedSubview(tripStatsStack)
        
        NSLayoutConstraint.activate([
            telemetryStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            telemetryStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            telemetryStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            telemetryStack.heightAnchor.constraint(equalToConstant: 80)
        ])
    }
    
    // MARK: - Bottom Controls
    private func setupBottomControls() {
        bottomControlsStack.translatesAutoresizingMaskIntoConstraints = false
        bottomControlsStack.axis = .horizontal
        bottomControlsStack.distribution = .fillEqually
        bottomControlsStack.spacing = 10
        view.addSubview(bottomControlsStack)
        
        configureButton(lockClipButton, title: "🔒 Vergrendel", bg: UIColor(red: 0.3, green: 0.1, blue: 0.1, alpha: 1.0))
        lockClipButton.addTarget(self, action: #selector(lockClipTapped), for: .touchUpInside)
        
        configureButton(galleryButton, title: "📁 Opnames", bg: UIColor(red: 0.1, green: 0.15, blue: 0.25, alpha: 1.0))
        galleryButton.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
        
        configureButton(themeButton, title: "🌙 Thema", bg: UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1.0))
        themeButton.addTarget(self, action: #selector(themeTapped), for: .touchUpInside)
        
        configureButton(settingsButton, title: "⚙️ Opties", bg: UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1.0))
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        
        bottomControlsStack.addArrangedSubview(lockClipButton)
        bottomControlsStack.addArrangedSubview(galleryButton)
        bottomControlsStack.addArrangedSubview(themeButton)
        bottomControlsStack.addArrangedSubview(settingsButton)
        
        NSLayoutConstraint.activate([
            bottomControlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bottomControlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomControlsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            bottomControlsStack.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    private func configureButton(_ btn: UIButton, title: String, bg: UIColor) {
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        btn.backgroundColor = bg
        btn.layer.cornerRadius = 10
        btn.clipsToBounds = true
    }
    
    // MARK: - Setup Engines & Delegates
    private func setupDelegatesAndEngines() {
        recorder.delegate = self
        recorder.visionTrafficSignDetector = trafficSignDetector
        trafficSignDetector.delegate = self
        speedCameraManager.delegate = self
        motionDetector.delegate = self
        
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 1.0
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }
    
    // MARK: - Ritregistratie & Timer
    private func startTripTracking() {
        tripStartTime = Date()
        tripTimer?.invalidate()
        tripTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let duration = Int(Date().timeIntervalSince(self.tripStartTime))
            let hours = duration / 3600
            let minutes = (duration % 3600) / 60
            let seconds = duration % 60
            self.tripDurationLabel.text = String(format: "⏱️ Duur: %02d:%02d:%02d", hours, minutes, seconds)
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
            print("SmartDash: Stroom gedetecteerd (auto gestart) -> Dashcam opname gestart!")
            recorder.startRecording()
        } else if !isPlugged && recorder.isRecording {
            print("SmartDash: Stroom onderbroken (auto uit) -> Segment netjes afronden.")
            // Laat eventueel nog 15 seconden lopen voor vertrekvertraging
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                guard let self = self else { return }
                if UIDevice.current.batteryState == .unplugged && self.recorder.isRecording {
                    self.recorder.stopRecording()
                }
            }
        }
    }
    
    // MARK: - CLLocationManager Delegate (Snelheid, Locatie & Flitsers)
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Snelheid in km/u
        let rawSpeed = location.speed
        let speed = rawSpeed > 0 ? (rawSpeed * 3.6) : 0.0
        currentSpeedKmh = speed
        
        // Update Odometer
        if let last = lastLocation {
            let delta = location.distance(from: last)
            if delta > 1.0 && delta < 500.0 { // filter GPS sprongen
                tripDistanceMeters += delta
            }
        }
        lastLocation = location
        tripOdoLabel.text = String(format: "🛣️ Rit: %.1f km", tripDistanceMeters / 1000.0)
        
        // Update Snelheid Display
        speedLabel.text = "\(Int(speed))"
        updateSpeedColors(currentSpeed: speed)
        
        // Flitser Evaluatie
        speedCameraManager.evaluate(location: location, speedKmh: speed, course: location.course)
        
        // Periodieke Straatnaam Geocoding (elke 20 seconden)
        let now = Date()
        if now.timeIntervalSince(lastGeocodeTime) > 20.0 {
            lastGeocodeTime = now
            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
                guard let self = self, let p = placemarks?.first, error == nil else { return }
                let street = p.thoroughfare ?? p.name ?? p.locality ?? "Snelweg"
                let city = p.locality ?? ""
                self.streetLabel.text = city.isEmpty ? "📍 \(street)" : "📍 \(street), \(city)"
            }
            
            // Haal eventueel live OpenStreetMap flitsers op in de buurt
            speedCameraManager.fetchOnlineSpeedCameras(around: location)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let deg = Int(newHeading.trueHeading > 0 ? newHeading.trueHeading : newHeading.magneticHeading)
        let directions = ["N", "NNO", "NO", "ONO", "O", "OZO", "ZO", "ZZO", "Z", "ZZW", "ZW", "WZW", "W", "WNW", "NW", "NNW"]
        let index = Int((Double(deg) + 11.25) / 22.5) % 16
        compassLabel.text = String(format: "🧭 %03d° %@", deg, directions[index])
    }
    
    // MARK: - Dynamische Snelheidskleuren
    private func updateSpeedColors(currentSpeed: Double) {
        guard let limit = detectedSpeedLimit else {
            speedLabel.textColor = currentTheme.accentColor
            speedDeltaLabel.text = "GPS ACTIEF"
            speedDeltaLabel.textColor = .systemCyan
            return
        }
        
        let delta = Int(currentSpeed) - limit
        if delta > 3 {
            // Te snel!
            speedLabel.textColor = .systemRed
            speedDeltaLabel.text = "⚠️ +\(delta) KM/H TE SNEL"
            speedDeltaLabel.textColor = .systemRed
        } else if delta >= -3 {
            // Dicht bij limiet
            speedLabel.textColor = .systemOrange
            speedDeltaLabel.text = "LIMIET BEREIKT"
            speedDeltaLabel.textColor = .systemOrange
        } else {
            // Veilig onder limiet
            speedLabel.textColor = currentTheme.accentColor
            speedDeltaLabel.text = "\(delta) KM/H (VEILIG)"
            speedDeltaLabel.textColor = .systemGreen
        }
    }
    
    // MARK: - TrafficSignDetector Delegate (Bordherkenning)
    func trafficSignDetector(_ detector: TrafficSignDetector, didDetectSpeedLimit speedLimit: Int) {
        self.detectedSpeedLimit = speedLimit
        signNumberLabel.text = "\(speedLimit)"
        signSubLabel.text = "HERKEND"
        
        // Bounce animatie op het bord
        signContainer.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8, options: [], animations: {
            self.signContainer.transform = .identity
        }, completion: nil)
        
        updateSpeedColors(currentSpeed: currentSpeedKmh)
    }
    
    // MARK: - SpeedCameraManager Delegate (Flitser Radar Alerts)
    func speedCameraManager(_ manager: SpeedCameraManager, didDetectAlert alert: SpeedCameraAlert) {
        self.activeCameraAlert = alert
        
        radarTitleLabel.text = "\(alert.camera.type.icon) FLITSER OVER \(alert.formattedDistance.uppercased())"
        radarDistanceLabel.text = "\(alert.camera.name) • Max \(alert.camera.speedLimit) km/h"
        radarLimitBadge.text = "\(alert.camera.speedLimit)"
        
        let progress = Float(alert.distanceMeters / manager.warningDistanceMeters)
        radarProgressBar.setProgress(max(0.05, min(1.0, progress)), animated: true)
        
        if alert.isSpeeding {
            radarCard.backgroundColor = UIColor(red: 0.25, green: 0.05, blue: 0.05, alpha: 0.95)
            radarCard.layer.borderColor = UIColor.systemRed.cgColor
            radarProgressBar.progressTintColor = .systemRed
        } else {
            radarCard.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 0.95)
            radarCard.layer.borderColor = UIColor.systemCyan.cgColor
            radarProgressBar.progressTintColor = .systemCyan
        }
        
        if radarCard.alpha == 0.0 {
            radarCardTopConstraint?.constant = 6
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5, options: [], animations: {
                self.radarCard.alpha = 1.0
                self.view.layoutIfNeeded()
            }, completion: nil)
        }
    }
    
    func speedCameraManagerDidClearAlert(_ manager: SpeedCameraManager) {
        self.activeCameraAlert = nil
        radarCardTopConstraint?.constant = -100
        UIView.animate(withDuration: 0.35, animations: {
            self.radarCard.alpha = 0.0
            self.view.layoutIfNeeded()
        })
    }
    
    // MARK: - MotionGForceDetector Delegate (G-Meter & Botsing)
    func motionDetector(_ detector: MotionGForceDetector, didUpdateGForce lateral: Double, longitudinal: Double, total: Double) {
        gforceLabel.text = String(format: "%.2f G", total)
        
        // Bereken positie van stip in crosshair
        let maxOffset: CGFloat = 26.0
        let x = CGFloat(lateral) * maxOffset
        let y = CGFloat(-longitudinal) * maxOffset
        
        gforceDot.transform = CGAffineTransform(translationX: min(maxOffset, max(-maxOffset, x)),
                                                y: min(maxOffset, max(-maxOffset, y)))
    }
    
    func motionDetector(_ detector: MotionGForceDetector, didDetectImpact gForce: Double) {
        // Noodgeval: Botsing of noodstop gedetecteerd!
        recorder.lockCurrentSegment(reason: String(format: "Impact G-kracht: %.2fG", gForce))
        
        // Schermflits
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
        segmentTimerLabel.text = String(format: "%02d:%02d / 03:00", mins, secs)
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didCompleteSegment roadURL: URL, cabinURL: URL?) {
        print("SmartDash: Segment opgeslagen: \(roadURL.lastPathComponent)")
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didLockSegment url: URL) {
        let toast = UIAlertController(title: "🔒 Clip Beveiligd", message: "De huidige ritclip is permanent opgeslagen in Vergrendelde Clips.", preferredStyle: .alert)
        present(toast, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            toast.dismiss(animated: true)
        }
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didUpdateStorageUsage bytesUsed: Int64, maxBytes: Int64) {
        let gbUsed = Double(bytesUsed) / (1024 * 1024 * 1024)
        let gbMax = Double(maxBytes) / (1024 * 1024 * 1024)
        storageLabel.text = String(format: "%.1f / %.0f GB", gbUsed, gbMax)
    }
    
    // MARK: - Button Actions
    @objc private func lockClipTapped() {
        recorder.lockCurrentSegment(reason: "Handmatig door bestuurder vergrendeld")
    }
    
    @objc private func galleryTapped() {
        let galleryVC = ClipsGalleryViewController()
        let nav = UINavigationController(rootViewController: galleryVC)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    
    @objc private func themeTapped() {
        let alert = UIAlertController(title: "Cockpit Thema", message: "Kies je gewenste dashboard weergave:", preferredStyle: .actionSheet)
        for theme in CockpitTheme.allCases {
            alert.addAction(UIAlertAction(title: theme.rawValue, style: .default, handler: { [weak self] _ in
                self?.applyTheme(theme)
            }))
        }
        alert.addAction(UIAlertAction(title: "Annuleren", style: .cancel))
        present(alert, animated: true)
    }
    
    private func applyTheme(_ theme: CockpitTheme) {
        self.currentTheme = theme
        speedUnitLabel.textColor = theme.accentColor
        gforceLabel.textColor = theme.accentColor
        gforceDot.backgroundColor = theme.accentColor
        gforceContainer.layer.borderColor = theme.accentColor.withAlphaComponent(0.4).cgColor
        dualCamBadge.textColor = theme.accentColor
        dualCamBadge.backgroundColor = theme.accentColor.withAlphaComponent(0.15)
        updateSpeedColors(currentSpeed: currentSpeedKmh)
    }
    
    @objc private func settingsTapped() {
        let alert = UIAlertController(title: "SmartDash Instellingen", message: "Stel dashcam voorkeuren in:", preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "Opslaglimiet: 10 GB (Huidig)", style: .default, handler: nil))
        alert.addAction(UIAlertAction(title: "Segmentduur: 3 Minuten (Huidig)", style: .default, handler: nil))
        alert.addAction(UIAlertAction(title: "G-Sensor Gevoeligheid: 2.4G", style: .default, handler: nil))
        alert.addAction(UIAlertAction(title: "Borddetectie Resetten", style: .default, handler: { [weak self] _ in
            self?.trafficSignDetector.reset()
            self?.detectedSpeedLimit = nil
            self?.signNumberLabel.text = "--"
            self?.signSubLabel.text = "BORD SCAN"
            self?.updateSpeedColors(currentSpeed: self?.currentSpeedKmh ?? 0)
        }))
        alert.addAction(UIAlertAction(title: "Sluiten", style: .cancel))
        present(alert, animated: true)
    }
}
