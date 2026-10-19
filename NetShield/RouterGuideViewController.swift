import UIKit

/// Interactive Step-by-Step Router Configuration Guide.
/// Contains detailed, provider-specific walkthroughs for Ziggo, KPN, Odido, Fritz!Box, TP-Link, Asus, and UniFi.
public final class RouterGuideViewController: UIViewController {
    
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    
    private let headerLabel = UILabel()
    private let subheaderLabel = UILabel()
    private let currentIPBanner = UIView()
    private let currentIPLabel = UILabel()
    private let copyIPButton = UIButton(type: .system)
    
    private let segmentedControl = UISegmentedControl(items: ["Ziggo", "KPN", "Odido", "Fritz!Box", "TP-Link", "Anderen"])
    private let guideContentCard = UIView()
    private let guideTitleLabel = UILabel()
    private let guideBodyLabel = UILabel()
    
    private let tipsCard = UIView()
    private let tipsTitleLabel = UILabel()
    private let tipsBodyLabel = UILabel()

    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateGuideContent(index: 0)
    }

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1.0)
        title = "Router Stappenplan"
        
        // Navigation close button
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissGuide))
        
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        
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
        
        // Header
        headerLabel.text = "Thuisnetwerk Beschermen"
        headerLabel.font = .systemFont(ofSize: 24, weight: .bold)
        headerLabel.textColor = .white
        
        subheaderLabel.text = "Stel deze iPhone in als de primaire DNS server op je router om automatisch alle apparaten in huis (telefoons, tv's, laptops, tablets) reclamevrij te maken."
        subheaderLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subheaderLabel.textColor = UIColor(white: 0.7, alpha: 1.0)
        subheaderLabel.numberOfLines = 0
        
        // Current IP Banner
        currentIPBanner.backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1.0)
        currentIPBanner.layer.cornerRadius = 14
        currentIPBanner.layer.borderWidth = 1
        currentIPBanner.layer.borderColor = UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 0.4).cgColor
        
        let ip = DNSEngine.shared.getWifiIPAddress() ?? "Verbind met Wi-Fi"
        currentIPLabel.text = "DNS IP van deze iPhone:\n\(ip)"
        currentIPLabel.font = .systemFont(ofSize: 16, weight: .bold)
        currentIPLabel.textColor = UIColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1.0)
        currentIPLabel.numberOfLines = 2
        
        copyIPButton.setTitle("Kopieer IP", for: .normal)
        copyIPButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        copyIPButton.backgroundColor = UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1.0)
        copyIPButton.setTitleColor(.black, for: .normal)
        copyIPButton.layer.cornerRadius = 8
        copyIPButton.addTarget(self, action: #selector(copyIP), for: .touchUpInside)
        
        // Segmented Control
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1.0)
        segmentedControl.selectedSegmentTintColor = UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1.0)
        segmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        segmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.black, .font: UIFont.systemFont(ofSize: 13, weight: .bold)], for: .selected)
        segmentedControl.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        
        // Guide Card
        guideContentCard.backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1.0)
        guideContentCard.layer.cornerRadius = 16
        guideContentCard.layer.borderWidth = 1
        guideContentCard.layer.borderColor = UIColor(white: 0.2, alpha: 1.0).cgColor
        
        guideTitleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        guideTitleLabel.textColor = .white
        
        guideBodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        guideBodyLabel.textColor = UIColor(white: 0.85, alpha: 1.0)
        guideBodyLabel.numberOfLines = 0
        
        // Tips Card
        tipsCard.backgroundColor = UIColor(red: 0.1, green: 0.13, blue: 0.2, alpha: 1.0)
        tipsCard.layer.cornerRadius = 14
        tipsCard.layer.borderWidth = 1
        tipsCard.layer.borderColor = UIColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 0.3).cgColor
        
        tipsTitleLabel.text = "💡 Belangrijke Tips voor 24/7 Gebruik"
        tipsTitleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        tipsTitleLabel.textColor = UIColor(red: 0.98, green: 0.75, blue: 0.2, alpha: 1.0)
        
        tipsBodyLabel.text = """
        1. Vaste IP Toewijzing (DHCP Reservering):
        Geef deze iPhone XS in je router een 'vast lokaal IP-adres' (DHCP reservation) gebaseerd op zijn MAC-adres. Zo verandert het IP-adres nooit na een herstart.

        2. Continu aan de lader:
        Plaats deze iPhone op een laaddock of kabel bij je router. NetShield bevat een actieve audio-loop die voorkomt dat iOS in slaapstand gaat.

        3. Secundaire DNS fallback:
        Voer in je router als Secundaire DNS 1.1.1.1 (Cloudflare) of 9.9.9.9 (Quad9) in. Mocht de iPhone ooit leeg raken, blijft internet altijd werken.
        """
        tipsBodyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        tipsBodyLabel.textColor = UIColor(white: 0.8, alpha: 1.0)
        tipsBodyLabel.numberOfLines = 0
        
        // Layout
        [headerLabel, subheaderLabel, currentIPBanner, segmentedControl, guideContentCard, tipsCard].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        
        [currentIPLabel, copyIPButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            currentIPBanner.addSubview($0)
        }
        
        [guideTitleLabel, guideBodyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            guideContentCard.addSubview($0)
        }
        
        [tipsTitleLabel, tipsBodyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            tipsCard.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            headerLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            subheaderLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            subheaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            subheaderLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            // Current IP Banner
            currentIPBanner.topAnchor.constraint(equalTo: subheaderLabel.bottomAnchor, constant: 18),
            currentIPBanner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            currentIPBanner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            currentIPLabel.topAnchor.constraint(equalTo: currentIPBanner.topAnchor, constant: 14),
            currentIPLabel.leadingAnchor.constraint(equalTo: currentIPBanner.leadingAnchor, constant: 16),
            currentIPLabel.bottomAnchor.constraint(equalTo: currentIPBanner.bottomAnchor, constant: -14),
            
            copyIPButton.centerYAnchor.constraint(equalTo: currentIPBanner.centerYAnchor),
            copyIPButton.trailingAnchor.constraint(equalTo: currentIPBanner.trailingAnchor, constant: -16),
            copyIPButton.widthAnchor.constraint(equalToConstant: 100),
            copyIPButton.heightAnchor.constraint(equalToConstant: 38),
            
            // Segmented Control
            segmentedControl.topAnchor.constraint(equalTo: currentIPBanner.bottomAnchor, constant: 22),
            segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            segmentedControl.heightAnchor.constraint(equalToConstant: 36),
            
            // Guide Card
            guideContentCard.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 18),
            guideContentCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            guideContentCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            guideTitleLabel.topAnchor.constraint(equalTo: guideContentCard.topAnchor, constant: 18),
            guideTitleLabel.leadingAnchor.constraint(equalTo: guideContentCard.leadingAnchor, constant: 18),
            guideTitleLabel.trailingAnchor.constraint(equalTo: guideContentCard.trailingAnchor, constant: -18),
            
            guideBodyLabel.topAnchor.constraint(equalTo: guideTitleLabel.bottomAnchor, constant: 12),
            guideBodyLabel.leadingAnchor.constraint(equalTo: guideContentCard.leadingAnchor, constant: 18),
            guideBodyLabel.trailingAnchor.constraint(equalTo: guideContentCard.trailingAnchor, constant: -18),
            guideBodyLabel.bottomAnchor.constraint(equalTo: guideContentCard.bottomAnchor, constant: -18),
            
            // Tips Card
            tipsCard.topAnchor.constraint(equalTo: guideContentCard.bottomAnchor, constant: 20),
            tipsCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tipsCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tipsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -30),
            
            tipsTitleLabel.topAnchor.constraint(equalTo: tipsCard.topAnchor, constant: 16),
            tipsTitleLabel.leadingAnchor.constraint(equalTo: tipsCard.leadingAnchor, constant: 16),
            tipsTitleLabel.trailingAnchor.constraint(equalTo: tipsCard.trailingAnchor, constant: -16),
            
            tipsBodyLabel.topAnchor.constraint(equalTo: tipsTitleLabel.bottomAnchor, constant: 10),
            tipsBodyLabel.leadingAnchor.constraint(equalTo: tipsCard.leadingAnchor, constant: 16),
            tipsBodyLabel.trailingAnchor.constraint(equalTo: tipsCard.trailingAnchor, constant: -16),
            tipsBodyLabel.bottomAnchor.constraint(equalTo: tipsCard.bottomAnchor, constant: -16)
        ])
    }

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        updateGuideContent(index: sender.selectedSegmentIndex)
    }

    @objc private func copyIP() {
        if let ip = DNSEngine.shared.getWifiIPAddress() {
            UIPasteboard.general.string = ip
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
            let alert = UIAlertController(title: "Gekopieerd!", message: "IP-adres \(ip) is gekopieerd naar je klembord.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    @objc private func dismissGuide() {
        dismiss(animated: true)
    }

    private func updateGuideContent(index: Int) {
        let ip = DNSEngine.shared.getWifiIPAddress() ?? "192.168.178.50"
        
        switch index {
        case 0: // Ziggo
            guideTitleLabel.text = "Ziggo Connectbox & SmartWifi Modem"
            guideBodyLabel.text = """
            Stappen voor Ziggo Connectbox:
            1. Open een browser en ga naar http://192.168.178.1
            2. Log in met het wachtwoord op de sticker onderop je modem.
            3. Ga in het menu naar 'Geavanceerde instellingen' ➔ 'DHCP'.
            4. Zoek het veld 'Primaire DNS'.
            5. Verander dit naar het IP van deze iPhone: \(ip)
            6. Stel als Secundaire DNS: 1.1.1.1 in (als veilige back-up).
            7. Klik op 'Wijzigingen toepassen'.
            8. (Optioneel) Herstart je apparaten of zet Wi-Fi even uit en aan om direct advertentievrij te zijn!
            """
            
        case 1: // KPN
            guideTitleLabel.text = "KPN Box 12 & Experia Box v10"
            guideBodyLabel.text = """
            Stappen voor KPN Box:
            1. Ga in je browser naar http://192.168.2.254 (of http://mijnmodem.kpn)
            2. Log in met je beheerdersaccount.
            3. Navigeer naar 'Netwerk' ➔ 'LAN' ➔ 'DHCP Server'.
            4. Bij 'DNS Server Handmatig' vink je dit aan.
            5. Voer bij Primaire DNS in: \(ip)
            6. Voer bij Secundaire DNS in: 9.9.9.9
            7. Klik op 'Opslaan / Toepassen'.
            
            Let op: Bij sommige KPN firmware-versies is DNS vergrendeld. Je kunt dan een eigen router achter de Experia Box zetten, of het DNS-adres handmatig invullen op individuele pc's, tv's en telefoons.
            """
            
        case 2: // Odido
            guideTitleLabel.text = "Odido / T-Mobile (Zyxel T-54 / T-56)"
            guideBodyLabel.text = """
            Stappen voor Odido Zyxel modems:
            1. Open http://192.168.1.1 in je browser.
            2. Log in met de 'admin' gegevens van de achterkant van het modem.
            3. Klik op het menu icoon (drie streepjes rechtsboven).
            4. Ga naar 'Netwerkinstellingen' ➔ 'Thuisnetwerk' ➔ tabblad 'LAN Setup'.
            5. Zoek 'DNS Serverwaarden' en selecteer 'Door gebruiker gedefinieerd'.
            6. DNS Server 1: \(ip)
            7. DNS Server 2: 1.1.1.1
            8. Klik onderaan op 'Toepassen'.
            """
            
        case 3: // Fritz!Box
            guideTitleLabel.text = "AVM FRITZ!Box (7590, 7530, 6660)"
            guideBodyLabel.text = """
            Stappen voor FRITZ!Box:
            1. Ga naar http://fritz.box in je browser en meld je aan.
            2. Klik in het linkermenu op 'Thuisnetwerk' ➔ 'Netwerk'.
            3. Klik op het tabblad 'Netwerkinstellingen'.
            4. Klik op 'IPv4-configuratie'.
            5. Scroll naar 'Lokale DNS-server' en vul hier in: \(ip)
            6. Klik op 'OK'.
            
            FRITZ!Box zal nu automatisch alle aangesloten telefoons, consoles en smart-tv's via NetShield laten lopen!
            """
            
        case 4: // TP-Link
            guideTitleLabel.text = "TP-Link Archer & Deco Mesh"
            guideBodyLabel.text = """
            Stappen voor TP-Link Archer / Deco:
            
            Voor Archer Router:
            1. Ga naar http://tplinkwifi.net of 192.168.0.1
            2. Ga naar 'Advanced' ➔ 'Network' ➔ 'DHCP Server'.
            3. Primaire DNS: \(ip)
            4. Secundaire DNS: 1.1.1.1
            5. Klik op 'Save'.
            
            Voor Deco Mesh App:
            1. Open de 'Deco' app op je telefoon.
            2. Ga naar 'Meer' ➔ 'Geavanceerd' ➔ 'IPv4'.
            3. Tik op 'Internetverbinding type' of 'DNS'.
            4. Selecteer 'Handmatig' en voer \(ip) in als Primaire DNS.
            """
            
        case 5: // Anderen & Handmatige apparaten
            guideTitleLabel.text = "Andere Routers & Individuele Apparaten"
            guideBodyLabel.text = """
            Algemene Router Instructie:
            Zoek in je routermenu naar 'LAN', 'DHCP' of 'Local Network'. Verander 'Primary DNS' naar \(ip).
            
            Handmatig instellen per apparaat:
            - iPhone / iPad: Ga naar Instellingen ➔ Wi-Fi ➔ tik op (i) naast je netwerk ➔ Configureer DNS ➔ Handmatig ➔ Voeg server toe: \(ip)
            - Mac: Systeeminstellingen ➔ Netwerk ➔ Wi-Fi ➔ Details ➔ DNS ➔ '+' ➔ \(ip)
            - Windows 10/11: Instellingen ➔ Netwerk en internet ➔ Wi-Fi ➔ Eigenschappen van hardware ➔ DNS-servertoewijzing: Bewerken ➔ Handmatig ➔ IPv4: Aan ➔ Voorkeurs-DNS: \(ip)
            - Android: Instellingen ➔ Wi-Fi ➔ Netwerk bewerken ➔ Geavanceerd ➔ IP-instellingen: Statisch ➔ DNS 1: \(ip)
            - Smart TV / Apple TV: Netwerkinstellingen ➔ Handmatige DNS ➔ \(ip)
            """
            
        default:
            break
        }
    }
}
