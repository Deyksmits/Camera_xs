import Foundation

// MARK: - Blocklist Manager (Beheer van Advertentie-, Tracker- & Telemetrielijsten)
class BlocklistManager {
    static let shared = BlocklistManager()
    
    // Snelle O(1) in-memory lookup sets
    private var blockedDomains: Set<String> = []
    private var customBlacklist: Set<String> = []
    private var customWhitelist: Set<String> = []
    
    private let queue = DispatchQueue(label: "com.netshield.blocklist", attributes: .concurrent)
    
    // Bestandsopslag locaties
    private var blocklistFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("netshield_blocklist.txt")
    }
    
    private var customBlacklistURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("custom_blacklist.json")
    }
    
    private var customWhitelistURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("custom_whitelist.json")
    }
    
    // Status
    var totalRulesCount: Int {
        return queue.sync { blockedDomains.count + customBlacklist.count }
    }
    
    var lastUpdatedDate: Date? {
        let attr = try? FileManager.default.attributesOfItem(atPath: blocklistFileURL.path)
        return attr?[.modificationDate] as? Date
    }
    
    init() {
        loadCustomLists()
        loadBlocklistFromDiskOrDefaults()
    }
    
    // MARK: - Snelle Domein Controle (Inclusief Subdomeinen)
    func isDomainBlocked(_ domain: String) -> Bool {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return false }
        
        return queue.sync {
            // 1. Heiligdom: Controleer eerst of het domein gewhitelist is door de gebruiker
            if isDomainInSet(clean, set: customWhitelist) {
                return false
            }
            
            // 2. Handmatige Blacklist van de gebruiker
            if isDomainInSet(clean, set: customBlacklist) {
                return true
            }
            
            // 3. Centrale Adblock / Tracker Database
            return isDomainInSet(clean, set: blockedDomains)
        }
    }
    
    private func isDomainInSet(_ domain: String, set: Set<String>) -> Bool {
        if set.contains(domain) { return true }
        
        // Controleer alle bovenliggende subdomeinen (bv. ad.track.google.com -> track.google.com -> google.com)
        var parts = domain.split(separator: ".")
        while parts.count > 1 {
            parts.removeFirst()
            let parent = parts.joined(separator: ".")
            if set.contains(parent) {
                return true
            }
        }
        return false
    }
    
    // MARK: - Laden & Opslaan van Lijsten
    private func loadBlocklistFromDiskOrDefaults() {
        if FileManager.default.fileExists(atPath: blocklistFileURL.path),
           let content = try? String(contentsOf: blocklistFileURL, encoding: .utf8) {
            parseAndSetDomains(from: content)
            print("NetShield: \(blockedDomains.count) adblock domeinen geladen vanaf schijf.")
        } else {
            // Laad een rijke ingebouwde offline basislijst met alle bekende advertentie- en trackerbedrijven
            let embedded = defaultEmbeddedAdDomains
            queue.async(flags: .barrier) {
                self.blockedDomains = Set(embedded)
            }
            saveDomainsToDisk(embedded.joined(separator: "\n"))
            print("NetShield: Geïnitialiseerd met \(embedded.count) ingebouwde ad/tracker domeinen.")
        }
    }
    
    private func parseAndSetDomains(from rawText: String) {
        var parsed: Set<String> = []
        parsed.reserveCapacity(80000)
        
        rawText.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("!") {
                return
            }
            
            // Ondersteun zowel '0.0.0.0 domain.com', '127.0.0.1 domain.com' als platte domeinlijsten
            let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if tokens.count >= 2 && (tokens[0] == "0.0.0.0" || tokens[0] == "127.0.0.1") {
                let dom = tokens[1].lowercased()
                if dom != "localhost" && dom != "broadcasthost" {
                    parsed.insert(dom)
                }
            } else if let first = tokens.first {
                let dom = first.lowercased()
                if !dom.contains("/") && !dom.contains(":") && dom.contains(".") {
                    parsed.insert(dom)
                }
            }
        }
        
        queue.async(flags: .barrier) {
            self.blockedDomains = parsed
        }
    }
    
    private func saveDomainsToDisk(_ text: String) {
        try? text.write(to: blocklistFileURL, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Online Synchronisatie van Nieuwe Adblock Lijsten
    func updateBlocklistsOnline(sourceURL: URL? = nil, completion: @escaping (Bool, Int) -> Void) {
        // Standaard bron: StevenBlack Unified Ad & Tracking Hosts (meest gerespecteerde en geteste lijst ter wereld)
        let url = sourceURL ?? URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil,
                  let text = String(data: data, encoding: .utf8) else {
                completion(false, 0)
                return
            }
            
            self.parseAndSetDomains(from: text)
            self.saveDomainsToDisk(text)
            
            let count = self.totalRulesCount
            completion(true, count)
        }.resume()
    }
    
    // MARK: - Handmatige Whitelist & Blacklist Beheer
    func addCustomWhitelist(domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        queue.async(flags: .barrier) {
            self.customWhitelist.insert(clean)
            self.customBlacklist.remove(clean)
            self.saveCustomLists()
        }
    }
    
    func removeCustomWhitelist(domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        queue.async(flags: .barrier) {
            self.customWhitelist.remove(clean)
            self.saveCustomLists()
        }
    }
    
    func addCustomBlacklist(domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        queue.async(flags: .barrier) {
            self.customBlacklist.insert(clean)
            self.customWhitelist.remove(clean)
            self.saveCustomLists()
        }
    }
    
    func removeCustomBlacklist(domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        queue.async(flags: .barrier) {
            self.customBlacklist.remove(clean)
            self.saveCustomLists()
        }
    }
    
    func getCustomLists() -> (whitelist: [String], blacklist: [String]) {
        return queue.sync {
            (Array(customWhitelist).sorted(), Array(customBlacklist).sorted())
        }
    }
    
    private func saveCustomLists() {
        let wl = Array(customWhitelist)
        let bl = Array(customBlacklist)
        if let wlData = try? JSONEncoder().encode(wl) {
            try? wlData.write(to: customWhitelistURL)
        }
        if let blData = try? JSONEncoder().encode(bl) {
            try? blData.write(to: customBlacklistURL)
        }
    }
    
    private func loadCustomLists() {
        if let wlData = try? Data(contentsOf: customWhitelistURL),
           let wl = try? JSONDecoder().decode([String].self, from: wlData) {
            customWhitelist = Set(wl)
        }
        if let blData = try? Data(contentsOf: customBlacklistURL),
           let bl = try? JSONDecoder().decode([String].self, from: blData) {
            customBlacklist = Set(bl)
        }
    }
    
    // MARK: - Uitgebreide Ingebouwde Ad & Tracker Basislijst
    private var defaultEmbeddedAdDomains: [String] {
        return [
            // Google Ads, DoubleClick & Telemetrie
            "doubleclick.net", "ad.doubleclick.net", "googleads.g.doubleclick.net",
            "pagead2.googlesyndication.com", "pagead.googlesyndication.com",
            "adservice.google.com", "adservice.google.nl", "ads.google.com",
            "adwords.google.com", "googleadservices.com", "www.googleadservices.com",
            "googletagmanager.com", "www.googletagmanager.com", "googletagservices.com",
            "google-analytics.com", "ssl.google-analytics.com", "www.google-analytics.com",
            "analytics.google.com", "app-measurement.com", "firebaselogging.googleapis.com",
            
            // Meta / Facebook Ads & Tracking Pixels
            "an.facebook.com", "pixel.facebook.com", "graph.facebook.com",
            "connect.facebook.net", "ad.atdmt.com", "ads.facebook.com",
            
            // ByteDance / TikTok Ads & Telemetrie
            "analytics.tiktok.com", "ads.tiktok.com", "log.byteoversea.com",
            "mon.musical.ly", "toblog.ctobsnssdk.com",
            
            // Microsoft & Windows Telemetrie
            "telemetry.microsoft.com", "v10.events.data.microsoft.com",
            "v20.events.data.microsoft.com", "watson.telemetry.microsoft.com",
            "activity.windows.com", "diagnostics.support.microsoft.com",
            
            // Smart TV & Hardware Telemetrie (Samsung, LG, Philips, Xiaomi)
            "samsungcloudsolution.com", "samsungcloudsolution.net", "sre.samsungcloudplatform.com",
            "config.samsungads.com", "gpm.samsungqbe.com", "log-config.samsungacr.com",
            "ad.lgsmartad.com", "ngfts.lge.com", "rdx.lgtvcommon.com", "ibis.lgappstv.com",
            "tracking.miui.com", "data.mistat.xiaomi.com", "adv.sec.miui.com",
            
            // Grote Advertentienetwerken & Trackers
            "criteo.com", "static.criteo.net", "bidder.criteo.com",
            "outbrain.com", "images.outbrain.com", "log.outbrain.com",
            "taboola.com", "cdn.taboola.com", "trc.taboola.com",
            "pubmatic.com", "ads.pubmatic.com", "rubiconproject.com",
            "openx.net", "cas.criteo.com", "smartadserver.com",
            "applovin.com", "d.applovin.com", "a.applovin.com",
            "unityads.unity3d.com", "ads.unity3d.com", "ironsrc.mobi",
            "chartboost.com", "vungle.com", "inmobi.com", "adcolony.com",
            "branch.io", "api.branch.io", "appsflyer.com", "app.appsflyer.com",
            "adjust.com", "app.adjust.com", "scorecardresearch.com",
            "quantserve.com", "quantcount.com", "moatads.com",
            
            // Amazon Ads
            "aax.amazon-adsystem.com", "c.amazon-adsystem.com", "fls-na.amazon.com",
            "device-metrics-us.amazon.com", "device-metrics-us-2.amazon.com",
            
            // Veelvoorkomende Malafide Popup & Redirect Domeinen
            "popcash.net", "popads.net", "adsterra.com", "exoclick.com",
            "propellerads.com", "trafficjunky.com", "juicyads.com",
            "clickadu.com", "zeroredirect1.com", "revenuehits.com"
        ]
    }
}
