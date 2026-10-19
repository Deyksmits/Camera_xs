import UIKit
import CoreLocation
import CoreMotion
import AVFoundation

// MARK: - DashViewController (Professioneel Cockpit Dashboard & Dual Dashcam)
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
    private var accelDismissTimer: Timer?
    
    // MARK: - UI Containers
    private let dashboardContainer = UIView()
    
    // Top Bar (Score Board Pill & Quick Controls)
    private let topBarView = UIView()
    private let scoreBoardPill = UIButton(type: .system)
    private let hudMirrorButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    
    // Center Column: Snelheidsmeter (Midden in het scherm, Geen "gps-speed" tekst)
    private let speedCenterContainer = UIView()
    private let speedLabel = UILabel()
    private let speedUnitLabel = UILabel()
    private let speedGaugeBar = UIProgressView(progressViewStyle: .bar)
    private let speedWarningGlow = UIView()
    
    // Left Column: Flitsmeister Radar Alert Card (Vaste Flitspalen & Trajectcontroles)
    private let leftAlertsStack = UIStackView()
    private let radarCard = UIView()
    private let radarLimitSignView = UIView()
    private let radarLimitNumberLabel = UILabel()
    private let radarTypeBadge = UILabel()
    private let radarLocationLabel = UILabel()
    private let radarDistanceLabel = UILabel()
    private let radarProgressBar = UIProgressView(progressViewStyle: .bar)
    private let radarStatusPill = UILabel()
    
    // Left Column: Acceleratie Notificatie Card (bv. 0-70 bij 78 piek)
    private let accelNotificationCard = UIView()
    private let accelHeaderLabel = UILabel()
    private let accelTitleLabel = UILabel()
    private let accelTimeLabel = UILabel()
    private let accelDetailLabel = UILabel()
    private let accelBadge = UILabel()
    
    // Right Column: G-Force Telemetry & Compact Recording Timer
    private let rightTelemetryStack = UIStackView()
    
    // G-Force Meter Card
    private let gforceCard = UIView()
    private let gforceDial = UIView()
    private let gforceCrossX = UIView()
    private let gforceCrossY = UIView()
    private let gforceRingInner = UIView()
    private let gforceRingOuter = UIView()
    private let gforceDot = UIView()
    private let gforceValueLabel = UILabel()
    private let gforceSubLabel = UILabel()
    private let gforceAxesLabel = UILabel()
    
    // Recording Timer & Status Card
    private let recCard = UIView()
    private let recDot = UIView()
    private let recTimerLabel = UILabel()
    private let recResolutionBadge = UILabel()
    private let recLockButton = UIButton(type: .system)
    
    // Noodgeval Schermflits bij botsing / impact
    private let impactFlashView = UIView()
    
    // Dynamic Responsive Constraints
    private var landscapeConstraints: [NSLayoutConstraint] = []
    private var portraitConstraints: [NSLayoutConstraint] = []
    
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
        
        // Start dashcam recorder & sensoren
        recorder.setupAndStartSession()
        recorder.startRecording()
        motionDetector.start()
        
        // Luister naar acceleratie & sprint telemetrie
        setupAccelerationCallbacks()
        
        // Init score board pill
        updateScoreBoardPill()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCircularLayers()
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.updateLayoutForOrientation(isLandscape: size.width > size.height)
        }, completion: { [weak self] _ in
            self?.updateCircularLayers()
        })
    }
    
    private func updateCircularLayers() {
        recDot.layer.cornerRadius = recDot.bounds.width / 2
        gforceDial.layer.cornerRadius = gforceDial.bounds.width / 2
        gforceRingInner.layer.cornerRadius = gforceRingInner.bounds.width / 2
        gforceRingOuter.layer.cornerRadius = gforceRingOuter.bounds.width / 2
        radarLimitSignView.layer.cornerRadius = radarLimitSignView.bounds.width / 2
    }
    
    // MARK: - UI Construction
    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)
        
        // Container voor HUD Spiegeling
        dashboardContainer.translatesAutoresizingMaskIntoConstraints = false
        dashboardContainer.backgroundColor = .clear
        view.addSubview(dashboardContainer)
        
        // Tap gesture om HUD modus snel te verlaten
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleScreenTap))
        view.addGestureRecognizer(tap)
        
        // 1. Top Controls Bar
        setupTopBar()
        
        // 2. Center: Snelheidsmeter
        setupSpeedometerCenter()
        
        // 3. Left: Alerts Stack (Flitsmeister + Acceleratie Notificatie)
        setupLeftAlerts()
        
        // 4. Right: G-Force + Recording Timer
        setupRightTelemetry()
        
        // 5. Impact Flash Overlay
        impactFlashView.translatesAutoresizingMaskIntoConstraints = false
        impactFlashView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.45)
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
        
        buildResponsiveConstraints()
        let isLandscape = view.bounds.width > view.bounds.height
        updateLayoutForOrientation(isLandscape: isLandscape)
    }
    
    // MARK: - 1. Top Bar (Compact Tucked-Away Score Board & Clean Controls)
    private func setupTopBar() {
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        dashboardContainer.addSubview(topBarView)
        
        // Score Board Pill (Klein en netjes weggestopt)
        scoreBoardPill.translatesAutoresizingMaskIntoConstraints = false
        scoreBoardPill.backgroundColor = UIColor(white: 0.12, alpha: 0.85)
        scoreBoardPill.layer.cornerRadius = 15
        scoreBoardPill.layer.borderWidth = 0.8
        scoreBoardPill.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.35).cgColor
        scoreBoardPill.setTitle("🏆 SPRINT SCORES", for: .normal)
        scoreBoardPill.setTitleColor(.white, for: .normal)
        scoreBoardPill.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        scoreBoardPill.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        scoreBoardPill.addTarget(self, action: #selector(openScoreboardSheet), for: .touchUpInside)
        topBarView.addSubview(scoreBoardPill)
        
        // Top Right Controls Stack
        let rightControls = UIStackView()
        rightControls.translatesAutoresizingMaskIntoConstraints = false
        rightControls.axis = .horizontal
        rightControls.spacing = 8
        rightControls.alignment = .center
        topBarView.addSubview(rightControls)
        
        // HUD Mirror Toggle
        hudMirrorButton.translatesAutoresizingMaskIntoConstraints = false
        hudMirrorButton.setTitle("🪞 HUD", for: .normal)
        hudMirrorButton.setTitleColor(.white, for: .normal)
        hudMirrorButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        hudMirrorButton.backgroundColor = UIColor(red: 0.10, green: 0.15, blue: 0.24, alpha: 0.9)
        hudMirrorButton.layer.cornerRadius = 15
        hudMirrorButton.layer.borderWidth = 0.8
        hudMirrorButton.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.3).cgColor
        hudMirrorButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        hudMirrorButton.addTarget(self, action: #selector(toggleHUDMode), for: .touchUpInside)
        rightControls.addArrangedSubview(hudMirrorButton)
        
        // Settings Sheet Button (Alle overige functies netjes verborgen)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setTitle("⚙️", for: .normal)
        settingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        settingsButton.backgroundColor = UIColor(white: 0.14, alpha: 0.9)
        settingsButton.layer.cornerRadius = 15
        settingsButton.layer.borderWidth = 0.8
        settingsButton.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        settingsButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        settingsButton.addTarget(self, action: #selector(openSettingsSheet), for: .touchUpInside)
        rightControls.addArrangedSubview(settingsButton)
        
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: dashboardContainer.safeAreaLayoutGuide.topAnchor, constant: 6),
            topBarView.leadingAnchor.constraint(equalTo: dashboardContainer.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            topBarView.trailingAnchor.constraint(equalTo: dashboardContainer.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            topBarView.heightAnchor.constraint(equalToConstant: 34),
            
            scoreBoardPill.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor),
            scoreBoardPill.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            
            rightControls.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor),
            rightControls.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor)
        ])
    }
    
    // MARK: - 2. Center: Snelheidsmeter (Geen "gps-speed", Alleen Puur Snelheid)
    private func setupSpeedometerCenter() {
        speedCenterContainer.translatesAutoresizingMaskIntoConstraints = false
        dashboardContainer.addSubview(speedCenterContainer)
        
        // Subtiele achtergrond glow bij te hard rijden
        speedWarningGlow.translatesAutoresizingMaskIntoConstraints = false
        speedWarningGlow.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        speedWarningGlow.layer.cornerRadius = 32
        speedWarningGlow.alpha = 0.0
        speedCenterContainer.addSubview(speedWarningGlow)
        
        let speedStack = UIStackView()
        speedStack.translatesAutoresizingMaskIntoConstraints = false
        speedStack.axis = .vertical
        speedStack.alignment = .center
        speedStack.spacing = -8
        speedCenterContainer.addSubview(speedStack)
        
        // Grote, hypermoderne digitale snelheid
        speedLabel.text = "0"
        speedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 118, weight: .black)
        speedLabel.textColor = .white
        speedLabel.textAlignment = .center
        
        // Eenvoudige, strakke eenheid (geen "gps-speed", enkel "KM/H")
        speedUnitLabel.text = "KM/H"
        speedUnitLabel.font = UIFont.systemFont(ofSize: 15, weight: .heavy)
        speedUnitLabel.textColor = UIColor(red: 0.35, green: 0.65, blue: 0.95, alpha: 0.85)
        
        speedStack.addArrangedSubview(speedLabel)
        speedStack.addArrangedSubview(speedUnitLabel)
        
        // Dynamische gauge bar onder de snelheid
        speedGaugeBar.translatesAutoresizingMaskIntoConstraints = false
        speedGaugeBar.progressTintColor = UIColor(red: 0.15, green: 0.75, blue: 0.95, alpha: 1.0)
        speedGaugeBar.trackTintColor = UIColor.white.withAlphaComponent(0.08)
        speedGaugeBar.layer.cornerRadius = 2.5
        speedGaugeBar.clipsToBounds = true
        speedGaugeBar.progress = 0.0
        speedCenterContainer.addSubview(speedGaugeBar)
        
        NSLayoutConstraint.activate([
            speedWarningGlow.topAnchor.constraint(equalTo: speedCenterContainer.topAnchor, constant: -10),
            speedWarningGlow.leadingAnchor.constraint(equalTo: speedCenterContainer.leadingAnchor, constant: -10),
            speedWarningGlow.trailingAnchor.constraint(equalTo: speedCenterContainer.trailingAnchor, constant: 10),
            speedWarningGlow.bottomAnchor.constraint(equalTo: speedCenterContainer.bottomAnchor, constant: 10),
            
            speedStack.centerXAnchor.constraint(equalTo: speedCenterContainer.centerXAnchor),
            speedStack.centerYAnchor.constraint(equalTo: speedCenterContainer.centerYAnchor, constant: -6),
            
            speedGaugeBar.centerXAnchor.constraint(equalTo: speedCenterContainer.centerXAnchor),
            speedGaugeBar.bottomAnchor.constraint(equalTo: speedCenterContainer.bottomAnchor, constant: -4),
            speedGaugeBar.widthAnchor.constraint(equalToConstant: 160),
            speedGaugeBar.heightAnchor.constraint(equalToConstant: 4)
        ])
    }
    
    // MARK: - 3. Left Column: Flitsmeister Radar & Acceleratie Notificatie
    private func setupLeftAlerts() {
        leftAlertsStack.translatesAutoresizingMaskIntoConstraints = false
        leftAlertsStack.axis = .vertical
        leftAlertsStack.spacing = 10
        leftAlertsStack.alignment = .fill
        leftAlertsStack.distribution = .fillProportionally
        dashboardContainer.addSubview(leftAlertsStack)
        
        // A. Flitsmeister Radar Alert Card (Nederlandse Flitsers & Trajectcontroles)
        radarCard.translatesAutoresizingMaskIntoConstraints = false
        radarCard.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.19, alpha: 0.95)
        radarCard.layer.cornerRadius = 18
        radarCard.layer.borderWidth = 1.0
        radarCard.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.4).cgColor
        radarCard.clipsToBounds = true
        radarCard.alpha = 0.0 // Begint verborgen totdat flitser nadert
        leftAlertsStack.addArrangedSubview(radarCard)
        
        let radarContentStack = UIStackView()
        radarContentStack.translatesAutoresizingMaskIntoConstraints = false
        radarContentStack.axis = .horizontal
        radarContentStack.alignment = .center
        radarContentStack.spacing = 10
        radarCard.addSubview(radarContentStack)
        
        // Nederlands Verkeersbord (Witte cirkel met rode rand)
        radarLimitSignView.translatesAutoresizingMaskIntoConstraints = false
        radarLimitSignView.backgroundColor = .white
        radarLimitSignView.layer.borderWidth = 4.0
        radarLimitSignView.layer.borderColor = UIColor.systemRed.cgColor
        radarLimitSignView.clipsToBounds = true
        NSLayoutConstraint.activate([
            radarLimitSignView.widthAnchor.constraint(equalToConstant: 44),
            radarLimitSignView.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        radarLimitNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        radarLimitNumberLabel.text = "100"
        radarLimitNumberLabel.font = UIFont.systemFont(ofSize: 18, weight: .black)
        radarLimitNumberLabel.textColor = .black
        radarLimitNumberLabel.textAlignment = .center
        radarLimitSignView.addSubview(radarLimitNumberLabel)
        
        NSLayoutConstraint.activate([
            radarLimitNumberLabel.centerXAnchor.constraint(equalTo: radarLimitSignView.centerXAnchor),
            radarLimitNumberLabel.centerYAnchor.constraint(equalTo: radarLimitSignView.centerYAnchor)
        ])
        
        let radarTextStack = UIStackView()
        radarTextStack.axis = .vertical
        radarTextStack.spacing = 2
        
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.spacing = 6
        headerRow.alignment = .center
        
        radarTypeBadge.text = "📷 VASTE FLITSPAAL"
        radarTypeBadge.font = UIFont.systemFont(ofSize: 11, weight: .heavy)
        radarTypeBadge.textColor = .systemCyan
        
        radarStatusPill.text = "VEILIG"
        radarStatusPill.font = UIFont.systemFont(ofSize: 9, weight: .bold)
        radarStatusPill.textColor = UIColor(red: 0.2, green: 0.9, blue: 0.5, alpha: 1.0)
        radarStatusPill.backgroundColor = UIColor(red: 0.2, green: 0.9, blue: 0.5, alpha: 0.15)
        radarStatusPill.layer.cornerRadius = 4
        radarStatusPill.clipsToBounds = true
        radarStatusPill.textAlignment = .center
        radarStatusPill.contentMode = .center
        
        headerRow.addArrangedSubview(radarTypeBadge)
        headerRow.addArrangedSubview(radarStatusPill)
        
        radarLocationLabel.text = "A2 Breukelen → Maarssen"
        radarLocationLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        radarLocationLabel.textColor = .white
        radarLocationLabel.lineBreakMode = .byTruncatingTail
        
        radarDistanceLabel.text = "450 m"
        radarDistanceLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .heavy)
        radarDistanceLabel.textColor = .white
        
        radarTextStack.addArrangedSubview(headerRow)
        radarTextStack.addArrangedSubview(radarLocationLabel)
        radarTextStack.addArrangedSubview(radarDistanceLabel)
        
        radarContentStack.addArrangedSubview(radarLimitSignView)
        radarContentStack.addArrangedSubview(radarTextStack)
        
        radarProgressBar.translatesAutoresizingMaskIntoConstraints = false
        radarProgressBar.progressTintColor = .systemCyan
        radarProgressBar.trackTintColor = UIColor.white.withAlphaComponent(0.08)
        radarProgressBar.progress = 1.0
        radarCard.addSubview(radarProgressBar)
        
        NSLayoutConstraint.activate([
            radarContentStack.leadingAnchor.constraint(equalTo: radarCard.leadingAnchor, constant: 12),
            radarContentStack.trailingAnchor.constraint(equalTo: radarCard.trailingAnchor, constant: -12),
            radarContentStack.centerYAnchor.constraint(equalTo: radarCard.centerYAnchor, constant: -2),
            radarContentStack.topAnchor.constraint(greaterThanOrEqualTo: radarCard.topAnchor, constant: 8),
            radarContentStack.bottomAnchor.constraint(lessThanOrEqualTo: radarCard.bottomAnchor, constant: -8),
            
            radarProgressBar.leadingAnchor.constraint(equalTo: radarCard.leadingAnchor),
            radarProgressBar.trailingAnchor.constraint(equalTo: radarCard.trailingAnchor),
            radarProgressBar.bottomAnchor.constraint(equalTo: radarCard.bottomAnchor),
            radarProgressBar.heightAnchor.constraint(equalToConstant: 3)
        ])
        
        // B. Acceleratie Notificatie Card (Flitsend & Netjes)
        accelNotificationCard.translatesAutoresizingMaskIntoConstraints = false
        accelNotificationCard.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 0.95)
        accelNotificationCard.layer.cornerRadius = 18
        accelNotificationCard.layer.borderWidth = 1.0
        accelNotificationCard.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.4).cgColor
        accelNotificationCard.clipsToBounds = true
        accelNotificationCard.alpha = 0.0 // Wordt getoond bij snelle optrek
        
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissAccelCard))
        accelNotificationCard.addGestureRecognizer(dismissTap)
        leftAlertsStack.addArrangedSubview(accelNotificationCard)
        
        let accelStack = UIStackView()
        accelStack.translatesAutoresizingMaskIntoConstraints = false
        accelStack.axis = .vertical
        accelStack.spacing = 3
        accelStack.alignment = .leading
        accelNotificationCard.addSubview(accelStack)
        
        let accelTopRow = UIStackView()
        accelTopRow.axis = .horizontal
        accelTopRow.spacing = 6
        accelTopRow.alignment = .center
        
        accelHeaderLabel.text = "⚡ SPRINT METING"
        accelHeaderLabel.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
        accelHeaderLabel.textColor = .systemYellow
        
        accelBadge.text = "PR"
        accelBadge.font = UIFont.systemFont(ofSize: 9, weight: .heavy)
        accelBadge.textColor = .black
        accelBadge.backgroundColor = .systemYellow
        accelBadge.layer.cornerRadius = 3
        accelBadge.clipsToBounds = true
        accelBadge.textAlignment = .center
        accelBadge.isHidden = true
        
        accelTopRow.addArrangedSubview(accelHeaderLabel)
        accelTopRow.addArrangedSubview(accelBadge)
        
        accelTitleLabel.text = "0 → 70 KM/U"
        accelTitleLabel.font = UIFont.systemFont(ofSize: 16, weight: .black)
        accelTitleLabel.textColor = .white
        
        accelTimeLabel.text = "4.32s"
        accelTimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .heavy)
        accelTimeLabel.textColor = .systemYellow
        
        accelDetailLabel.text = "Piek: 78 km/u • Snelle acceleratie"
        accelDetailLabel.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        accelDetailLabel.textColor = UIColor(white: 0.75, alpha: 1.0)
        
        accelStack.addArrangedSubview(accelTopRow)
        accelStack.addArrangedSubview(accelTitleLabel)
        accelStack.addArrangedSubview(accelTimeLabel)
        accelStack.addArrangedSubview(accelDetailLabel)
        
        NSLayoutConstraint.activate([
            accelStack.leadingAnchor.constraint(equalTo: accelNotificationCard.leadingAnchor, constant: 14),
            accelStack.trailingAnchor.constraint(equalTo: accelNotificationCard.trailingAnchor, constant: -14),
            accelStack.topAnchor.constraint(equalTo: accelNotificationCard.topAnchor, constant: 10),
            accelStack.bottomAnchor.constraint(equalTo: accelNotificationCard.bottomAnchor, constant: -10)
        ])
    }
    
    // MARK: - 4. Right Column: G-Force Meter & Recording Timer
    private func setupRightTelemetry() {
        rightTelemetryStack.translatesAutoresizingMaskIntoConstraints = false
        rightTelemetryStack.axis = .vertical
        rightTelemetryStack.spacing = 10
        rightTelemetryStack.alignment = .fill
        rightTelemetryStack.distribution = .fillProportionally
        dashboardContainer.addSubview(rightTelemetryStack)
        
        // A. G-Force Telemetry Card
        gforceCard.translatesAutoresizingMaskIntoConstraints = false
        gforceCard.backgroundColor = UIColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 0.95)
        gforceCard.layer.cornerRadius = 18
        gforceCard.layer.borderWidth = 1.0
        gforceCard.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        rightTelemetryStack.addArrangedSubview(gforceCard)
        
        let gLayout = UIStackView()
        gLayout.translatesAutoresizingMaskIntoConstraints = false
        gLayout.axis = .horizontal
        gLayout.alignment = .center
        gLayout.spacing = 12
        gforceCard.addSubview(gLayout)
        
        // Precision Telemetry Dial
        gforceDial.translatesAutoresizingMaskIntoConstraints = false
        gforceDial.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0)
        gforceDial.layer.borderWidth = 1.0
        gforceDial.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.3).cgColor
        
        gforceRingOuter.translatesAutoresizingMaskIntoConstraints = false
        gforceRingOuter.layer.borderWidth = 0.5
        gforceRingOuter.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        gforceDial.addSubview(gforceRingOuter)
        
        gforceRingInner.translatesAutoresizingMaskIntoConstraints = false
        gforceRingInner.layer.borderWidth = 0.5
        gforceRingInner.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        gforceDial.addSubview(gforceRingInner)
        
        gforceCrossX.translatesAutoresizingMaskIntoConstraints = false
        gforceCrossX.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        gforceDial.addSubview(gforceCrossX)
        
        gforceCrossY.translatesAutoresizingMaskIntoConstraints = false
        gforceCrossY.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        gforceDial.addSubview(gforceCrossY)
        
        gforceDot.translatesAutoresizingMaskIntoConstraints = false
        gforceDot.backgroundColor = .systemCyan
        gforceDot.layer.cornerRadius = 3.5
        gforceDot.layer.shadowColor = UIColor.systemCyan.cgColor
        gforceDot.layer.shadowRadius = 4
        gforceDot.layer.shadowOpacity = 0.8
        gforceDial.addSubview(gforceDot)
        
        NSLayoutConstraint.activate([
            gforceDial.widthAnchor.constraint(equalToConstant: 54),
            gforceDial.heightAnchor.constraint(equalToConstant: 54),
            
            gforceRingOuter.centerXAnchor.constraint(equalTo: gforceDial.centerXAnchor),
            gforceRingOuter.centerYAnchor.constraint(equalTo: gforceDial.centerYAnchor),
            gforceRingOuter.widthAnchor.constraint(equalToConstant: 38),
            gforceRingOuter.heightAnchor.constraint(equalToConstant: 38),
            
            gforceRingInner.centerXAnchor.constraint(equalTo: gforceDial.centerXAnchor),
            gforceRingInner.centerYAnchor.constraint(equalTo: gforceDial.centerYAnchor),
            gforceRingInner.widthAnchor.constraint(equalToConstant: 20),
            gforceRingInner.heightAnchor.constraint(equalToConstant: 20),
            
            gforceCrossX.centerXAnchor.constraint(equalTo: gforceDial.centerXAnchor),
            gforceCrossX.centerYAnchor.constraint(equalTo: gforceDial.centerYAnchor),
            gforceCrossX.widthAnchor.constraint(equalTo: gforceDial.widthAnchor, constant: -10),
            gforceCrossX.heightAnchor.constraint(equalToConstant: 0.5),
            
            gforceCrossY.centerXAnchor.constraint(equalTo: gforceDial.centerXAnchor),
            gforceCrossY.centerYAnchor.constraint(equalTo: gforceDial.centerYAnchor),
            gforceCrossY.heightAnchor.constraint(equalTo: gforceDial.heightAnchor, constant: -10),
            gforceCrossY.widthAnchor.constraint(equalToConstant: 0.5),
            
            gforceDot.centerXAnchor.constraint(equalTo: gforceDial.centerXAnchor),
            gforceDot.centerYAnchor.constraint(equalTo: gforceDial.centerYAnchor),
            gforceDot.widthAnchor.constraint(equalToConstant: 7),
            gforceDot.heightAnchor.constraint(equalToConstant: 7)
        ])
        
        let gLabelsStack = UIStackView()
        gLabelsStack.axis = .vertical
        gLabelsStack.spacing = 1
        
        gforceSubLabel.text = "G-FORCE"
        gforceSubLabel.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
        gforceSubLabel.textColor = .systemCyan
        
        gforceValueLabel.text = "0.00 G"
        gforceValueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .heavy)
        gforceValueLabel.textColor = .white
        
        gforceAxesLabel.text = "LAT 0.00 • LONG 0.00"
        gforceAxesLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        gforceAxesLabel.textColor = UIColor(white: 0.6, alpha: 1.0)
        
        gLabelsStack.addArrangedSubview(gforceSubLabel)
        gLabelsStack.addArrangedSubview(gforceValueLabel)
        gLabelsStack.addArrangedSubview(gforceAxesLabel)
        
        gLayout.addArrangedSubview(gforceDial)
        gLayout.addArrangedSubview(gLabelsStack)
        
        NSLayoutConstraint.activate([
            gLayout.leadingAnchor.constraint(equalTo: gforceCard.leadingAnchor, constant: 12),
            gLayout.trailingAnchor.constraint(equalTo: gforceCard.trailingAnchor, constant: -12),
            gLayout.topAnchor.constraint(equalTo: gforceCard.topAnchor, constant: 8),
            gLayout.bottomAnchor.constraint(equalTo: gforceCard.bottomAnchor, constant: -8)
        ])
        
        // B. Compact Recording Timer Card
        recCard.translatesAutoresizingMaskIntoConstraints = false
        recCard.backgroundColor = UIColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 0.95)
        recCard.layer.cornerRadius = 18
        recCard.layer.borderWidth = 1.0
        recCard.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        rightTelemetryStack.addArrangedSubview(recCard)
        
        let recStack = UIStackView()
        recStack.translatesAutoresizingMaskIntoConstraints = false
        recStack.axis = .horizontal
        recStack.alignment = .center
        recStack.spacing = 10
        recCard.addSubview(recStack)
        
        recDot.translatesAutoresizingMaskIntoConstraints = false
        recDot.backgroundColor = .systemRed
        NSLayoutConstraint.activate([
            recDot.widthAnchor.constraint(equalToConstant: 10),
            recDot.heightAnchor.constraint(equalToConstant: 10)
        ])
        
        // Pulserende REC dot
        UIView.animate(withDuration: 0.8, delay: 0.0, options: [.repeat, .autoreverse], animations: {
            self.recDot.alpha = 0.2
        }, completion: nil)
        
        let recTextStack = UIStackView()
        recTextStack.axis = .vertical
        recTextStack.spacing = 1
        
        recResolutionBadge.text = "REC • 30 FPS DUAL"
        recResolutionBadge.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
        recResolutionBadge.textColor = .systemRed
        
        recTimerLabel.text = "00:00"
        recTimerLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .heavy)
        recTimerLabel.textColor = .white
        
        recTextStack.addArrangedSubview(recResolutionBadge)
        recTextStack.addArrangedSubview(recTimerLabel)
        
        // Quick Lock Clip Knop
        recLockButton.translatesAutoresizingMaskIntoConstraints = false
        recLockButton.setTitle("🔒", for: .normal)
        recLockButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        recLockButton.backgroundColor = UIColor(red: 0.35, green: 0.10, blue: 0.14, alpha: 0.9)
        recLockButton.layer.cornerRadius = 14
        recLockButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        recLockButton.addTarget(self, action: #selector(lockClipTapped), for: .touchUpInside)
        
        recStack.addArrangedSubview(recDot)
        recStack.addArrangedSubview(recTextStack)
        recStack.addArrangedSubview(recLockButton)
        
        NSLayoutConstraint.activate([
            recStack.leadingAnchor.constraint(equalTo: recCard.leadingAnchor, constant: 12),
            recStack.trailingAnchor.constraint(equalTo: recCard.trailingAnchor, constant: -12),
            recStack.topAnchor.constraint(equalTo: recCard.topAnchor, constant: 8),
            recStack.bottomAnchor.constraint(equalTo: recCard.bottomAnchor, constant: -8)
        ])
    }
    
    // MARK: - Responsive Landscape vs Portrait Constraints
    private func buildResponsiveConstraints() {
        // Landscape: Snelheid Midden, Alerts Links, G-Force + Rec Rechts
        landscapeConstraints = [
            // Center Snelheid
            speedCenterContainer.centerXAnchor.constraint(equalTo: dashboardContainer.centerXAnchor),
            speedCenterContainer.centerYAnchor.constraint(equalTo: dashboardContainer.centerYAnchor, constant: 12),
            speedCenterContainer.widthAnchor.constraint(equalToConstant: 240),
            speedCenterContainer.heightAnchor.constraint(equalToConstant: 180),
            
            // Left Column (Flitsmeister + Acceleratie)
            leftAlertsStack.leadingAnchor.constraint(equalTo: dashboardContainer.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            leftAlertsStack.trailingAnchor.constraint(equalTo: speedCenterContainer.leadingAnchor, constant: -16),
            leftAlertsStack.centerYAnchor.constraint(equalTo: dashboardContainer.centerYAnchor, constant: 14),
            
            // Right Column (G-Force + Timer)
            rightTelemetryStack.leadingAnchor.constraint(equalTo: speedCenterContainer.trailingAnchor, constant: 16),
            rightTelemetryStack.trailingAnchor.constraint(equalTo: dashboardContainer.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            rightTelemetryStack.centerYAnchor.constraint(equalTo: dashboardContainer.centerYAnchor, constant: 14)
        ]
        
        // Portrait: Boven Alerts/Score, Midden Snelheid, Onder G-Force & Timer
        portraitConstraints = [
            // Center Snelheid
            speedCenterContainer.centerXAnchor.constraint(equalTo: dashboardContainer.centerXAnchor),
            speedCenterContainer.topAnchor.constraint(equalTo: topBarView.bottomAnchor, constant: 16),
            speedCenterContainer.widthAnchor.constraint(equalTo: dashboardContainer.widthAnchor, constant: -32),
            speedCenterContainer.heightAnchor.constraint(equalToConstant: 170),
            
            // Left/Center Stack Alerts
            leftAlertsStack.topAnchor.constraint(equalTo: speedCenterContainer.bottomAnchor, constant: 12),
            leftAlertsStack.leadingAnchor.constraint(equalTo: dashboardContainer.leadingAnchor, constant: 16),
            leftAlertsStack.trailingAnchor.constraint(equalTo: dashboardContainer.trailingAnchor, constant: -16),
            
            // Right/Bottom Telemetry Stack
            rightTelemetryStack.topAnchor.constraint(equalTo: leftAlertsStack.bottomAnchor, constant: 12),
            rightTelemetryStack.leadingAnchor.constraint(equalTo: dashboardContainer.leadingAnchor, constant: 16),
            rightTelemetryStack.trailingAnchor.constraint(equalTo: dashboardContainer.trailingAnchor, constant: -16),
            rightTelemetryStack.bottomAnchor.constraint(lessThanOrEqualTo: dashboardContainer.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ]
    }
    
    private func updateLayoutForOrientation(isLandscape: Bool) {
        if isLandscape {
            NSLayoutConstraint.deactivate(portraitConstraints)
            NSLayoutConstraint.activate(landscapeConstraints)
            speedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 114, weight: .black)
        } else {
            NSLayoutConstraint.deactivate(landscapeConstraints)
            NSLayoutConstraint.activate(portraitConstraints)
            speedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 96, weight: .black)
        }
        view.layoutIfNeeded()
    }
    
    // MARK: - Setup Engines
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
    
    // MARK: - Acceleratie & Sprint Callbacks
    private func setupAccelerationCallbacks() {
        // Callback voor elke afgeronde acceleratie (bv. 0-70 bij 78 piek)
        performanceTimer.onAccelerationCompleted = { [weak self] result in
            DispatchQueue.main.async {
                self?.presentAccelerationNotification(result)
                self?.updateScoreBoardPill()
            }
        }
        
        // Status updates tijdens actieve lancering
        performanceTimer.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch status {
                case .ready:
                    break
                case .running(let elapsed, let currentSpeed):
                    // Toon subtiele live acceleratie voortgang
                    if self.accelNotificationCard.alpha == 0.0 && currentSpeed > 30.0 {
                        let tempTarget = Int(currentSpeed / 10.0) * 10
                        self.accelTitleLabel.text = "0 → \(tempTarget)+ KM/U"
                        self.accelTimeLabel.text = String(format: "%.1fs", elapsed)
                        self.accelDetailLabel.text = "Gaspedaal ingetrapt..."
                        self.accelBadge.isHidden = true
                        UIView.animate(withDuration: 0.25) {
                            self.accelNotificationCard.alpha = 1.0
                        }
                    }
                case .completed(let sprintRes):
                    self.updateScoreBoardPill()
                case .completedAcceleration(let accelRes):
                    self.presentAccelerationNotification(accelRes)
                    self.updateScoreBoardPill()
                case .idle:
                    break
                }
            }
        }
    }
    
    private func presentAccelerationNotification(_ result: AccelerationResult) {
        accelTitleLabel.text = result.title
        accelTimeLabel.text = "\(result.formattedTime)s"
        accelDetailLabel.text = String(format: "Piek: %.0f km/u • 0.38G gemiddeld", result.peakSpeed)
        accelBadge.isHidden = !result.isNewPR
        accelBadge.text = result.isNewPR ? "⚡ PR" : "SCORE"
        
        // Geanimeerde binnenkomst
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5, options: [], animations: {
            self.accelNotificationCard.alpha = 1.0
            self.dashboardContainer.layoutIfNeeded()
        }, completion: nil)
        
        // Auto-dismiss na 8 seconden (of tik om direct te sluiten)
        accelDismissTimer?.invalidate()
        accelDismissTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.dismissAccelCard()
        }
    }
    
    @objc private func dismissAccelCard() {
        accelDismissTimer?.invalidate()
        accelDismissTimer = nil
        UIView.animate(withDuration: 0.3) {
            self.accelNotificationCard.alpha = 0.0
        }
    }
    
    private func updateScoreBoardPill() {
        if let best = performanceTimer.personalBestTime {
            scoreBoardPill.setTitle(String(format: "🏆 0-100: %.2fs", best), for: .normal)
        } else if let latest = performanceTimer.recentAccelerations.first {
            scoreBoardPill.setTitle("🏆 \(latest.title): \(latest.formattedTime)s", for: .normal)
        } else {
            scoreBoardPill.setTitle("🏆 SPRINT SCORES", for: .normal)
        }
    }
    
    @objc private func openScoreboardSheet() {
        let sheet = ScoreboardViewController()
        let nav = UINavigationController(rootViewController: sheet)
        if let sheetPresentation = nav.sheetPresentationController {
            sheetPresentation.detents = [.medium(), .large()]
            sheetPresentation.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
    
    @objc private func openSettingsSheet() {
        let settingsVC = DashSettingsViewController(recorder: recorder,
                                                    speedCameraManager: speedCameraManager,
                                                    performanceTimer: performanceTimer,
                                                    isHUDMirrored: isHUDMirrored)
        settingsVC.onToggleHUD = { [weak self] in
            self?.toggleHUDMode()
        }
        settingsVC.onOpenGallery = { [weak self] in
            self?.galleryTapped()
        }
        
        let nav = UINavigationController(rootViewController: settingsVC)
        if let sheetPresentation = nav.sheetPresentationController {
            sheetPresentation.detents = [.large()]
            sheetPresentation.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
    
    // MARK: - Windshield HUD Mirror Mode (Voorruit Projectie)
    @objc private func toggleHUDMode() {
        isHUDMirrored = !isHUDMirrored
        
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5, options: [], animations: {
            if self.isHUDMirrored {
                // Spiegel horizontaal zodat reflectie op de autoruit correct leesbaar is
                self.dashboardContainer.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                self.previousBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 1.0
                self.hudMirrorButton.setTitle("📱 Scherm", for: .normal)
                self.hudMirrorButton.backgroundColor = .systemCyan
            } else {
                self.dashboardContainer.transform = .identity
                UIScreen.main.brightness = self.previousBrightness
                self.hudMirrorButton.setTitle("🪞 HUD", for: .normal)
                self.hudMirrorButton.backgroundColor = UIColor(red: 0.10, green: 0.15, blue: 0.24, alpha: 0.9)
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
            updateRecordingUI()
        } else if !isPlugged && recorder.isRecording {
            print("SmartDash: Stroom uit -> Sluit dashcam opname af.")
            recorder.stopRecording { [weak self] in
                self?.updateRecordingUI()
            }
        }
    }
    
    // MARK: - CLLocationManager Delegate (Snelheid & Flitsers)
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        let rawSpeed = location.speed
        let speed = rawSpeed > 0 ? (rawSpeed * 3.6) : 0.0
        currentSpeedKmh = speed
        
        // Update snelheidsmeter
        speedLabel.text = "\(Int(speed))"
        let speedProgress = Float(speed / 160.0)
        speedGaugeBar.setProgress(min(1.0, speedProgress), animated: true)
        
        // Evalueer acceleratie & sprint
        performanceTimer.updateSpeed(kmh: speed)
        
        // Evalueer Flitsers
        speedCameraManager.evaluate(location: location, speedKmh: speed, course: location.course)
    }
    
    // MARK: - SpeedCameraManager Delegate (Flitsmeister Radar Alerts)
    func speedCameraManager(_ manager: SpeedCameraManager, didDetectAlert alert: SpeedCameraAlert) {
        radarTypeBadge.text = "\(alert.camera.type.icon) \(alert.camera.type.rawValue.uppercased())"
        radarLocationLabel.text = alert.camera.name
        radarDistanceLabel.text = alert.formattedDistance.uppercased()
        radarLimitNumberLabel.text = "\(alert.camera.speedLimit)"
        
        let progress = Float(alert.distanceMeters / manager.warningDistanceMeters)
        radarProgressBar.setProgress(max(0.05, min(1.0, progress)), animated: true)
        
        if alert.isSpeeding {
            radarCard.backgroundColor = UIColor(red: 0.28, green: 0.06, blue: 0.08, alpha: 0.98)
            radarCard.layer.borderColor = UIColor.systemRed.cgColor
            radarProgressBar.progressTintColor = .systemRed
            radarStatusPill.text = "⚠️ TE SNEL"
            radarStatusPill.textColor = .systemRed
            radarStatusPill.backgroundColor = UIColor.systemRed.withAlphaComponent(0.2)
            
            speedLabel.textColor = .systemRed
            speedWarningGlow.alpha = 1.0
        } else {
            radarCard.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.19, alpha: 0.98)
            radarCard.layer.borderColor = UIColor.systemCyan.cgColor
            radarProgressBar.progressTintColor = .systemCyan
            radarStatusPill.text = "✓ VEILIG"
            radarStatusPill.textColor = UIColor(red: 0.2, green: 0.9, blue: 0.5, alpha: 1.0)
            radarStatusPill.backgroundColor = UIColor(red: 0.2, green: 0.9, blue: 0.5, alpha: 0.15)
            
            speedLabel.textColor = .white
            speedWarningGlow.alpha = 0.0
        }
        
        if radarCard.alpha == 0.0 {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.6, options: [], animations: {
                self.radarCard.alpha = 1.0
                self.dashboardContainer.layoutIfNeeded()
            }, completion: nil)
        }
    }
    
    func speedCameraManagerDidClearAlert(_ manager: SpeedCameraManager) {
        UIView.animate(withDuration: 0.3, animations: {
            self.radarCard.alpha = 0.0
            self.speedLabel.textColor = .white
            self.speedWarningGlow.alpha = 0.0
            self.dashboardContainer.layoutIfNeeded()
        })
    }
    
    // MARK: - MotionGForceDetector Delegate
    func motionDetector(_ detector: MotionGForceDetector, didUpdateGForce lateral: Double, longitudinal: Double, total: Double) {
        gforceValueLabel.text = String(format: "%.2f G", total)
        gforceAxesLabel.text = String(format: "L/R: %+.2fG • F/B: %+.2fG", lateral, longitudinal)
        
        let maxOffset: CGFloat = 18.0
        let x = CGFloat(lateral) * maxOffset
        let y = CGFloat(-longitudinal) * maxOffset
        
        gforceDot.transform = CGAffineTransform(translationX: min(maxOffset, max(-maxOffset, x)),
                                                y: min(maxOffset, max(-maxOffset, y)))
    }
    
    func motionDetector(_ detector: MotionGForceDetector, didDetectImpact gForce: Double) {
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
        recTimerLabel.text = String(format: "%02d:%02d", mins, secs)
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didCompleteSegment roadURL: URL, cabinURL: URL?) {
        print("SmartDash: Ritsegment voltooid: \(roadURL.lastPathComponent)")
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didLockSegment url: URL) {
        let toast = UIAlertController(title: "🔒 Rit Beveiligd", message: "De huidige video is opgeslagen in Noodclips.", preferredStyle: .alert)
        present(toast, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            toast.dismiss(animated: true)
        }
    }
    
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didUpdateStorageUsage bytesUsed: Int64, maxBytes: Int64) {
        // Stilzwijgend beheerd door loop buffer
    }
    
    // MARK: - Actions
    @objc private func lockClipTapped() {
        recorder.lockCurrentSegment(reason: "Handmatig beveiligd")
    }
    
    @objc private func galleryTapped() {
        let galleryVC = ClipsGalleryViewController()
        let nav = UINavigationController(rootViewController: galleryVC)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    
    private func updateRecordingUI() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let isRec = self.recorder.isRecording
            self.recDot.isHidden = !isRec
            self.recResolutionBadge.text = isRec ? "REC • 30 FPS DUAL" : "PAUZE"
        }
    }
}

// MARK: - ScoreboardViewController (Compacte Geschiedenis van Acceleratiemetingen)
class ScoreboardViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let performanceTimer = PerformanceTimer.shared
    private var runs: [AccelerationResult] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sprint & Acceleratie Telemetrie"
        view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0)
        
        runs = performanceTimer.recentAccelerations
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Sluiten", style: .done, target: self, action: #selector(closeTapped))
        
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ScoreCell")
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    @objc private func closeTapped() {
        dismiss(animated: true)
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return 1 // Persoonlijk Record
        } else {
            return runs.isEmpty ? 1 : runs.count
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "Persoonlijk Record (0 - 100 KM/U)" : "Recente Optrekmomenten (Afgerond op tientallen)"
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "ScoreCell")
        cell.backgroundColor = UIColor(red: 0.10, green: 0.13, blue: 0.19, alpha: 0.95)
        cell.textLabel?.textColor = .white
        cell.detailTextLabel?.textColor = .systemYellow
        
        if indexPath.section == 0 {
            if let pr = performanceTimer.personalBestTime {
                cell.textLabel?.text = "⚡ 0 → 100 KM/U PR"
                cell.detailTextLabel?.text = String(format: "%.2f sec", pr)
            } else {
                cell.textLabel?.text = "Nog geen 0-100 geregistreerd"
                cell.detailTextLabel?.text = "--"
            }
        } else {
            if runs.isEmpty {
                cell.textLabel?.text = "Geen recente acceleraties gemeten"
                cell.detailTextLabel?.text = ""
            } else {
                let run = runs[indexPath.row]
                let dateStr = DateFormatter.localizedString(from: run.date, dateStyle: .none, timeStyle: .short)
                cell.textLabel?.text = "\(run.title) (piek: \(Int(run.peakSpeed)) km/u)"
                cell.detailTextLabel?.text = "\(run.formattedTime)s  [\(dateStr)]"
            }
        }
        return cell
    }
}

// MARK: - DashSettingsViewController (Alle functies netjes overzichtelijk verborgen)
class DashSettingsViewController: UIViewController {
    
    private let recorder: DualDashcamRecorder
    private let speedCameraManager: SpeedCameraManager
    private let performanceTimer: PerformanceTimer
    private let isHUDMirrored: Bool
    
    var onToggleHUD: (() -> Void)?
    var onOpenGallery: (() -> Void)?
    
    init(recorder: DualDashcamRecorder,
         speedCameraManager: SpeedCameraManager,
         performanceTimer: PerformanceTimer,
         isHUDMirrored: Bool) {
        self.recorder = recorder
        self.speedCameraManager = speedCameraManager
        self.performanceTimer = performanceTimer
        self.isHUDMirrored = isHUDMirrored
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SmartDash Cockpit Instellingen"
        view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0)
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klaar", style: .done, target: self, action: #selector(doneTapped))
        
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        
        let contentStack = UIStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        scrollView.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32)
        ])
        
        // 1. Dashcam Opname Bediening
        contentStack.addArrangedSubview(createSectionHeader("📹 DASHCAM & OPNAMES"))
        let recBox = createSectionCard()
        
        let recStatusLabel = UILabel()
        recStatusLabel.text = recorder.isRecording ? "● Actief opnemen (Voor 1080p + Cabine 720p)" : "⏸ Gepauzeerd"
        recStatusLabel.textColor = recorder.isRecording ? UIColor.systemGreen : .lightGray
        recStatusLabel.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        recBox.addArrangedSubview(recStatusLabel)
        
        let recToggleBtn = createStyledButton(title: recorder.isRecording ? "⏹ Pauzeer Opname" : "▶ Start Opname",
                                             bg: UIColor(red: 0.15, green: 0.20, blue: 0.30, alpha: 1.0))
        recToggleBtn.addTarget(self, action: #selector(toggleRecordingTapped), for: .touchUpInside)
        recBox.addArrangedSubview(recToggleBtn)
        
        let lockBtn = createStyledButton(title: "🔒 Beveilig Huidige Rit (Noodclip)",
                                         bg: UIColor(red: 0.38, green: 0.12, blue: 0.16, alpha: 1.0))
        lockBtn.addTarget(self, action: #selector(lockClipTapped), for: .touchUpInside)
        recBox.addArrangedSubview(lockBtn)
        
        let galleryBtn = createStyledButton(title: "📁 Bekijk Opgeslagen Ritten & Galerij",
                                            bg: UIColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 1.0))
        galleryBtn.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
        recBox.addArrangedSubview(galleryBtn)
        
        contentStack.addArrangedSubview(recBox)
        
        // 2. Voorruit HUD Modus
        contentStack.addArrangedSubview(createSectionHeader("🪞 VOORRUIT HUD SPIEGEL MODUS"))
        let hudBox = createSectionCard()
        
        let hudDesc = UILabel()
        hudDesc.text = "Spiegelt het dashboard horizontaal en zet helderheid op 100%. Leg je iPhone plat onder de autoruit om een futuristisch Head-Up Display te zien!"
        hudDesc.textColor = UIColor(white: 0.75, alpha: 1.0)
        hudDesc.font = UIFont.systemFont(ofSize: 12)
        hudDesc.numberOfLines = 0
        hudBox.addArrangedSubview(hudDesc)
        
        let hudToggleBtn = createStyledButton(title: isHUDMirrored ? "📱 Terug naar Normaal Scherm" : "🪞 Activeer Voorruit HUD",
                                              bg: UIColor.systemCyan.withAlphaComponent(0.35))
        hudToggleBtn.addTarget(self, action: #selector(hudToggleTapped), for: .touchUpInside)
        hudBox.addArrangedSubview(hudToggleBtn)
        
        contentStack.addArrangedSubview(hudBox)
        
        // 3. Flitsers & Trajectcontroles
        contentStack.addArrangedSubview(createSectionHeader("🚨 FLITSERS & TRAJECTCONTROLE"))
        let flitsBox = createSectionCard()
        
        let flitsDesc = UILabel()
        flitsDesc.text = "Offline database met alle vaste flitspalen en trajectcontroles in Nederland & België. Waarschuwingsafstand staat op \(Int(speedCameraManager.warningDistanceMeters)) meter."
        flitsDesc.textColor = UIColor(white: 0.75, alpha: 1.0)
        flitsDesc.font = UIFont.systemFont(ofSize: 12)
        flitsDesc.numberOfLines = 0
        flitsBox.addArrangedSubview(flitsDesc)
        
        let distSeg = UISegmentedControl(items: ["500m", "750m", "1000m"])
        distSeg.selectedSegmentIndex = speedCameraManager.warningDistanceMeters == 500 ? 0 : (speedCameraManager.warningDistanceMeters == 1000 ? 2 : 1)
        distSeg.addTarget(self, action: #selector(distanceChanged(_:)), for: .valueChanged)
        flitsBox.addArrangedSubview(distSeg)
        
        contentStack.addArrangedSubview(flitsBox)
        
        // 4. Sprint & Telemetrie
        contentStack.addArrangedSubview(createSectionHeader("⚡ SPRINT & PERSOONLIJK RECORD"))
        let sprintBox = createSectionCard()
        
        let prLabel = UILabel()
        if let pr = performanceTimer.personalBestTime {
            prLabel.text = String(format: "Huidig 0-100 PR: %.2f seconde", pr)
        } else {
            prLabel.text = "Nog geen 0-100 PR geregistreerd."
        }
        prLabel.textColor = .white
        prLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        sprintBox.addArrangedSubview(prLabel)
        
        let resetPRBtn = createStyledButton(title: "🗑 Reset Persoonlijk Record & Geschiedenis",
                                            bg: UIColor.systemRed.withAlphaComponent(0.2))
        resetPRBtn.addTarget(self, action: #selector(resetPRTapped), for: .touchUpInside)
        sprintBox.addArrangedSubview(resetPRBtn)
        
        contentStack.addArrangedSubview(sprintBox)
    }
    
    @objc private func doneTapped() {
        dismiss(animated: true)
    }
    
    @objc private func toggleRecordingTapped() {
        if recorder.isRecording {
            recorder.stopRecording { [weak self] in
                self?.dismiss(animated: true)
            }
        } else {
            recorder.startRecording()
            dismiss(animated: true)
        }
    }
    
    @objc private func lockClipTapped() {
        recorder.lockCurrentSegment(reason: "Handmatig beveiligd via Instellingen")
        dismiss(animated: true)
    }
    
    @objc private func galleryTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onOpenGallery?()
        }
    }
    
    @objc private func hudToggleTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onToggleHUD?()
        }
    }
    
    @objc private func distanceChanged(_ seg: UISegmentedControl) {
        let dists: [Double] = [500, 750, 1000]
        speedCameraManager.warningDistanceMeters = dists[seg.selectedSegmentIndex]
    }
    
    @objc private func resetPRTapped() {
        performanceTimer.resetPR()
        dismiss(animated: true)
    }
    
    private func createSectionHeader(_ title: String) -> UILabel {
        let lbl = UILabel()
        lbl.text = title
        lbl.font = UIFont.systemFont(ofSize: 12, weight: .heavy)
        lbl.textColor = UIColor.systemCyan
        return lbl
    }
    
    private func createSectionCard() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.backgroundColor = UIColor(red: 0.10, green: 0.13, blue: 0.19, alpha: 0.95)
        stack.layer.cornerRadius = 14
        stack.layer.borderWidth = 1.0
        stack.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return stack
    }
    
    private func createStyledButton(title: String, bg: UIColor) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        btn.backgroundColor = bg
        btn.layer.cornerRadius = 10
        btn.clipsToBounds = true
        btn.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return btn
    }
}
