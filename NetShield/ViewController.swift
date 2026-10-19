import UIKit
import SafariServices

/// Main Dashboard Controller for NetShield.
/// Displays live server status, telemetry cards, IP address with 1-tap copy, query stream, and navigation to router guide.
public final class ViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    // MARK: - UI Components
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    
    // Top Card
    private let headerCard = UIView()
    private let logoImageView = UIImageView()
    private let titleLabel = UILabel()
    private let statusSubtitleLabel = UILabel()
    private let serverSwitch = UISwitch()
    
    // IP Card
    private let ipCard = UIView()
    private let ipTitleLabel = UILabel()
    private let ipValueLabel = UILabel()
    private let copyIPButton = UIButton(type: .system)
    private let webDashboardButton = UIButton(type: .system)
    
    // Metrics Grid
    private let metricsStackView = UIStackView()
    private let topMetricsRow = UIStackView()
    private let bottomMetricsRow = UIStackView()
    
    private let totalCard = MetricCardView(title: "TOTAAL QUERIES", accentColor: UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1.0))
    private let blockedCard = MetricCardView(title: "GEBLOKKEERD", accentColor: UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1.0))
    private let rateCard = MetricCardView(title: "PERCENTAGE", accentColor: UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1.0))
    private let rulesCard = MetricCardView(title: "ACTIEVE REGELS", accentColor: UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1.0))
    
    // Quick Actions
    private let actionsStackView = UIStackView()
    private let routerGuideButton = UIButton(type: .system)
    private let updateRulesButton = UIButton(type: .system)
    
    // Recent Queries Table
    private let querySectionCard = UIView()
    private let queryHeaderLabel = UILabel()
    private let tableView = UITableView()
    
    // State
    private var recentQueries: [DNSQueryLogEntry] = []
    private var updateTimer: Timer?

    // MARK: - Lifecycle
    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupLayout()
        startDataPolling()
    }
    
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshData()
    }
    
    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Setup UI
    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1.0)
        
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        
        // Header Card
        headerCard.backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1.0)
        headerCard.layer.cornerRadius = 16
        headerCard.layer.borderWidth = 1
        headerCard.layer.borderColor = UIColor(white: 0.2, alpha: 1.0).cgColor
        
        titleLabel.text = "NetShield DNS"
        titleLabel.font = .systemFont(ofSize: 20, weight: .heavy)
        titleLabel.textColor = .white
        
        statusSubtitleLabel.text = "24/7 AdBlocker actief op poort 53"
        statusSubtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusSubtitleLabel.textColor = UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1.0)
        
        serverSwitch.isOn = DNSEngine.shared.isServerActive
        serverSwitch.onTintColor = UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1.0)
        serverSwitch.addTarget(self, action: #selector(serverSwitchToggled(_:)), for: .valueChanged)
        
        // IP Card
        ipCard.backgroundColor = UIColor(red: 0.09, green: 0.13, blue: 0.20, alpha: 1.0)
        ipCard.layer.cornerRadius = 16
        ipCard.layer.borderWidth = 1
        ipCard.layer.borderColor = UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 0.4).cgColor
        
        ipTitleLabel.text = "LOKAAL DNS SERVER ADRES (WI-FI)"
        ipTitleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        ipTitleLabel.textColor = UIColor(white: 0.6, alpha: 1.0)
        
        let wifiIP = DNSEngine.shared.getWifiIPAddress() ?? "Verbind met Wi-Fi"
        ipValueLabel.text = wifiIP
        ipValueLabel.font = .monospacedSystemFont(ofSize: 26, weight: .black)
        ipValueLabel.textColor = UIColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1.0)
        
        copyIPButton.setTitle("📋 Kopieer IP", for: .normal)
        copyIPButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        copyIPButton.backgroundColor = UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1.0)
        copyIPButton.setTitleColor(.black, for: .normal)
        copyIPButton.layer.cornerRadius = 10
        copyIPButton.addTarget(self, action: #selector(copyIPAddress), for: .touchUpInside)
        
        webDashboardButton.setTitle("🌐 Web Dashboard", for: .normal)
        webDashboardButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        webDashboardButton.backgroundColor = UIColor(red: 0.2, green: 0.25, blue: 0.35, alpha: 1.0)
        webDashboardButton.setTitleColor(.white, for: .normal)
        webDashboardButton.layer.cornerRadius = 10
        webDashboardButton.addTarget(self, action: #selector(openWebDashboard), for: .touchUpInside)
        
        // Metrics Rows
        metricsStackView.axis = .vertical
        metricsStackView.spacing = 12
        metricsStackView.distribution = .fillEqually
        
        topMetricsRow.axis = .horizontal
        topMetricsRow.spacing = 12
        topMetricsRow.distribution = .fillEqually
        topMetricsRow.addArrangedSubview(totalCard)
        topMetricsRow.addArrangedSubview(blockedCard)
        
        bottomMetricsRow.axis = .horizontal
        bottomMetricsRow.spacing = 12
        bottomMetricsRow.distribution = .fillEqually
        bottomMetricsRow.addArrangedSubview(rateCard)
        bottomMetricsRow.addArrangedSubview(rulesCard)
        
        metricsStackView.addArrangedSubview(topMetricsRow)
        metricsStackView.addArrangedSubview(bottomMetricsRow)
        
        // Actions
        actionsStackView.axis = .horizontal
        actionsStackView.spacing = 12
        actionsStackView.distribution = .fillEqually
        
        routerGuideButton.setTitle("📖 Router Stappenplan", for: .normal)
        routerGuideButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        routerGuideButton.backgroundColor = UIColor(red: 0.16, green: 0.22, blue: 0.32, alpha: 1.0)
        routerGuideButton.setTitleColor(.white, for: .normal)
        routerGuideButton.layer.cornerRadius = 12
        routerGuideButton.layer.borderWidth = 1
        routerGuideButton.layer.borderColor = UIColor(white: 0.25, alpha: 1.0).cgColor
        routerGuideButton.addTarget(self, action: #selector(openRouterGuide), for: .touchUpInside)
        
        updateRulesButton.setTitle("🔄 Filterlijsten Updaten", for: .normal)
        updateRulesButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        updateRulesButton.backgroundColor = UIColor(red: 0.16, green: 0.22, blue: 0.32, alpha: 1.0)
        updateRulesButton.setTitleColor(.white, for: .normal)
        updateRulesButton.layer.cornerRadius = 12
        updateRulesButton.layer.borderWidth = 1
        updateRulesButton.layer.borderColor = UIColor(white: 0.25, alpha: 1.0).cgColor
        updateRulesButton.addTarget(self, action: #selector(updateFilterRules), for: .touchUpInside)
        
        actionsStackView.addArrangedSubview(routerGuideButton)
        actionsStackView.addArrangedSubview(updateRulesButton)
        
        // Table View Card
        querySectionCard.backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1.0)
        querySectionCard.layer.cornerRadius = 16
        querySectionCard.layer.borderWidth = 1
        querySectionCard.layer.borderColor = UIColor(white: 0.2, alpha: 1.0).cgColor
        
        queryHeaderLabel.text = "Recente DNS Verzoeken"
        queryHeaderLabel.font = .systemFont(ofSize: 16, weight: .bold)
        queryHeaderLabel.textColor = .white
        
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.2, alpha: 1.0)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(DNSQueryCell.self, forCellReuseIdentifier: "DNSQueryCell")
        tableView.isScrollEnabled = false
    }

    // MARK: - Setup Layout
    private func setupLayout() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
        
        [headerCard, ipCard, metricsStackView, actionsStackView, querySectionCard].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        
        // Header
        [titleLabel, statusSubtitleLabel, serverSwitch].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            headerCard.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            headerCard.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            headerCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            headerCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            titleLabel.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 16),
            
            statusSubtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusSubtitleLabel.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 16),
            statusSubtitleLabel.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -16),
            
            serverSwitch.centerYAnchor.constraint(equalTo: headerCard.centerYAnchor),
            serverSwitch.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -16)
        ])
        
        // IP Card
        let buttonStack = UIStackView(arrangedSubviews: [copyIPButton, webDashboardButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        
        [ipTitleLabel, ipValueLabel, buttonStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            ipCard.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            ipCard.topAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: 14),
            ipCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            ipCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            ipTitleLabel.topAnchor.constraint(equalTo: ipCard.topAnchor, constant: 16),
            ipTitleLabel.leadingAnchor.constraint(equalTo: ipCard.leadingAnchor, constant: 16),
            ipTitleLabel.trailingAnchor.constraint(equalTo: ipCard.trailingAnchor, constant: -16),
            
            ipValueLabel.topAnchor.constraint(equalTo: ipTitleLabel.bottomAnchor, constant: 6),
            ipValueLabel.leadingAnchor.constraint(equalTo: ipCard.leadingAnchor, constant: 16),
            ipValueLabel.trailingAnchor.constraint(equalTo: ipCard.trailingAnchor, constant: -16),
            
            buttonStack.topAnchor.constraint(equalTo: ipValueLabel.bottomAnchor, constant: 14),
            buttonStack.leadingAnchor.constraint(equalTo: ipCard.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: ipCard.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: ipCard.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 42)
        ])
        
        // Metrics Stack
        NSLayoutConstraint.activate([
            metricsStackView.topAnchor.constraint(equalTo: ipCard.bottomAnchor, constant: 14),
            metricsStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            metricsStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            metricsStackView.heightAnchor.constraint(equalToConstant: 180)
        ])
        
        // Actions
        NSLayoutConstraint.activate([
            actionsStackView.topAnchor.constraint(equalTo: metricsStackView.bottomAnchor, constant: 14),
            actionsStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            actionsStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            actionsStackView.heightAnchor.constraint(equalToConstant: 46)
        ])
        
        // Queries Card
        [queryHeaderLabel, tableView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            querySectionCard.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            querySectionCard.topAnchor.constraint(equalTo: actionsStackView.bottomAnchor, constant: 14),
            querySectionCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            querySectionCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            querySectionCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            
            queryHeaderLabel.topAnchor.constraint(equalTo: querySectionCard.topAnchor, constant: 16),
            queryHeaderLabel.leadingAnchor.constraint(equalTo: querySectionCard.leadingAnchor, constant: 16),
            queryHeaderLabel.trailingAnchor.constraint(equalTo: querySectionCard.trailingAnchor, constant: -16),
            
            tableView.topAnchor.constraint(equalTo: queryHeaderLabel.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: querySectionCard.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: querySectionCard.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: querySectionCard.bottomAnchor, constant: -8),
            tableView.heightAnchor.constraint(equalToConstant: 450)
        ])
    }

    // MARK: - Actions
    @objc private func serverSwitchToggled(_ sender: UISwitch) {
        if sender.isOn {
            DNSEngine.shared.start()
            statusSubtitleLabel.text = "24/7 AdBlocker actief op poort 53"
            statusSubtitleLabel.textColor = UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1.0)
        } else {
            DNSEngine.shared.stop()
            statusSubtitleLabel.text = "Gepauzeerd"
            statusSubtitleLabel.textColor = UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1.0)
        }
    }

    @objc private func copyIPAddress() {
        if let ip = DNSEngine.shared.getWifiIPAddress() {
            UIPasteboard.general.string = ip
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
            let alert = UIAlertController(title: "IP Gekopieerd!", message: "IP-adres \(ip) is gekopieerd naar je klembord.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    @objc private func openWebDashboard() {
        guard let ip = DNSEngine.shared.getWifiIPAddress(),
              let url = URL(string: "http://\(ip):8080") else {
            return
        }
        let safariVC = SFSafariViewController(url: url)
        present(safariVC, animated: true)
    }

    @objc private func openRouterGuide() {
        let guideVC = RouterGuideViewController()
        let nav = UINavigationController(rootViewController: guideVC)
        present(nav, animated: true)
    }

    @objc private func updateFilterRules() {
        let alert = UIAlertController(title: "Filterlijsten Updaten", message: "De nieuwste lijsten (StevenBlack) worden nu gedownload...", preferredStyle: .alert)
        present(alert, animated: true)
        
        BlocklistManager.shared.downloadOnlineBlocklists { [weak self] success, count in
            DispatchQueue.main.async {
                alert.dismiss(animated: true) {
                    let doneAlert = UIAlertController(
                        title: success ? "Succesvol Bijgewerkt!" : "Download Mislukt",
                        message: success ? "Er zijn nu \(count) advertentiedomeinen actief." : "Kon de online lijst niet ophalen. Lokale regels blijven actief.",
                        preferredStyle: .alert
                    )
                    doneAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(doneAlert, animated: true)
                    self?.refreshData()
                }
            }
        }
    }

    // MARK: - Data Polling
    private func startDataPolling() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    private func refreshData() {
        let stats = DNSEngine.shared.getStats()
        let total = stats.totalQueries
        let blocked = stats.blockedQueries
        let rate = total > 0 ? (Double(blocked) / Double(total) * 100.0) : 0.0
        
        totalCard.setValue("\(total)")
        blockedCard.setValue("\(blocked)")
        rateCard.setValue(String(format: "%.1f%%", rate))
        rulesCard.setValue("\(BlocklistManager.shared.blockCount)")
        
        recentQueries = DNSEngine.shared.getRecentLogs(limit: 15)
        tableView.reloadData()
        
        if let ip = DNSEngine.shared.getWifiIPAddress() {
            ipValueLabel.text = ip
        }
    }

    // MARK: - UITableView
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return recentQueries.count
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 54
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "DNSQueryCell", for: indexPath) as? DNSQueryCell else {
            return UITableViewCell()
        }
        let query = recentQueries[indexPath.row]
        cell.configure(with: query)
        return cell
    }
}

// MARK: - MetricCardView
final class MetricCardView: UIView {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    init(title: String, accentColor: UIColor) {
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1.0)
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.2, alpha: 1.0).cgColor
        
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = UIColor(white: 0.6, alpha: 1.0)
        
        valueLabel.text = "0"
        valueLabel.font = .systemFont(ofSize: 22, weight: .black)
        valueLabel.textColor = accentColor
        
        [titleLabel, valueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setValue(_ value: String) {
        valueLabel.text = value
    }
}

// MARK: - DNSQueryCell
final class DNSQueryCell: UITableViewCell {
    private let domainLabel = UILabel()
    private let clientLabel = UILabel()
    private let statusBadge = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        
        domainLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        domainLabel.textColor = .white
        domainLabel.lineBreakMode = .byTruncatingMiddle
        
        clientLabel.font = .systemFont(ofSize: 12, weight: .regular)
        clientLabel.textColor = UIColor(white: 0.5, alpha: 1.0)
        
        statusBadge.font = .systemFont(ofSize: 11, weight: .bold)
        statusBadge.textAlignment = .center
        statusBadge.layer.cornerRadius = 6
        statusBadge.clipsToBounds = true
        
        [domainLabel, clientLabel, statusBadge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            domainLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            domainLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            domainLabel.trailingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: -10),
            
            clientLabel.topAnchor.constraint(equalTo: domainLabel.bottomAnchor, constant: 2),
            clientLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            clientLabel.trailingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: -10),
            
            statusBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusBadge.widthAnchor.constraint(equalToConstant: 80),
            statusBadge.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with entry: DNSQueryLogEntry) {
        domainLabel.text = entry.domain
        clientLabel.text = "\(entry.formattedTime) • \(entry.clientIP) • \(entry.queryType)"
        
        switch entry.status {
        case .blocked:
            statusBadge.text = "BLOCKED"
            statusBadge.textColor = UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1.0)
            statusBadge.backgroundColor = UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.15)
        case .forwarded:
            statusBadge.text = "PASSED"
            statusBadge.textColor = UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1.0)
            statusBadge.backgroundColor = UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 0.15)
        case .cached:
            statusBadge.text = "CACHED"
            statusBadge.textColor = UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1.0)
            statusBadge.backgroundColor = UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 0.15)
        }
    }
}
