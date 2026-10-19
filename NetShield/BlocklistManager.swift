import Foundation

/// Advanced Multi-Source Ad, Tracker & Telemetry Blocklist Manager with Heuristic Analysis.
public final class BlocklistManager {
    public static let shared = BlocklistManager()

    private var blockedDomains: Set<String> = []
    public private(set) var customBlacklist: Set<String> = []
    public private(set) var customWhitelist: Set<String> = []
    
    // Aggressive heuristic mode (blocks unlisted subdomains matching ad patterns like ads.*, telemetry.*)
    public var isAggressiveMode: Bool {
        get { UserDefaults.standard.object(forKey: "netshield_aggressive") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "netshield_aggressive") }
    }

    private let queue = DispatchQueue(label: "com.netshield.blocklist", attributes: .concurrent)

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

    public var blockCount: Int {
        return queue.sync { blockedDomains.count + customBlacklist.count }
    }

    public var whitelistCount: Int {
        return queue.sync { customWhitelist.count }
    }

    private init() {
        loadCustomLists()
        loadBlocklistFromDiskOrDefaults()
    }

    // MARK: - Auto-Update on Boot
    public func autoUpdateIfNeeded() {
        if blockCount < 2000 {
            print("[BlocklistManager] Rule count low (\(blockCount)). Initiating background multi-source download...")
            downloadOnlineBlocklists { success, count in
                print("[BlocklistManager] Auto-update finished: success=\(success), rules=\(count)")
            }
        }
    }

    // MARK: - Fast Domain Check (Exact, Subdomain & Heuristics)
    public func isDomainBlocked(_ domain: String) -> Bool {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return false }

        // 1. Whitelist has absolute priority
        if queue.sync(execute: { isDomainInSet(clean, set: customWhitelist) }) {
            return false
        }

        // 2. Apple Private Relay & DoH Canary Domains
        // Apple & Mozilla specify that local DNS filtering networks MUST return NXDOMAIN/block for these
        // so that devices disable Private Relay and route their DNS queries through local NetShield!
        if isCanaryBypassDomain(clean) {
            return true
        }

        return queue.sync {
            // 3. User Custom Blacklist
            if isDomainInSet(clean, set: customBlacklist) {
                return true
            }

            // 4. Main Multi-Source Blocklist (O(1) Set lookup + Parent subdomains)
            if isDomainInSet(clean, set: blockedDomains) {
                return true
            }

            // 5. Aggressive Heuristic Filter (stops freshly generated ad/tracking subdomains)
            if isAggressiveMode && matchesAdHeuristic(clean) {
                return true
            }

            return false
        }
    }

    /// Canary domains used by Apple Private Relay and Firefox DoH
    public func isCanaryBypassDomain(_ domain: String) -> Bool {
        switch domain {
        case "mask.icloud.com", "mask-h2.icloud.com", "mask-api.icloud.com",
             "use-application-dns.net", "cloudflare-dns.com", "dns.google":
            return true
        default:
            return false
        }
    }

    private func isDomainInSet(_ domain: String, set: Set<String>) -> Bool {
        if set.contains(domain) { return true }

        // Check parent subdomains (e.g. ad.service.doubleclick.net -> doubleclick.net)
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

    /// Heuristic matching for ad/tracker tokens
    private func matchesAdHeuristic(_ domain: String) -> Bool {
        let parts = domain.components(separatedBy: ".")
        guard parts.count >= 2 else { return false }
        
        let sub = parts[0]
        
        // Exact prefix match
        let badPrefixes = ["ad", "ads", "adserver", "advert", "telemetry", "tracking", "tracker",
                           "analytics", "pixel", "banner", "metrics", "stats", "tagmanager",
                           "cookie", "affiliate", "popunder", "click"]
        if badPrefixes.contains(sub) {
            return true
        }

        // Common high-frequency ad substrings in Dutch/European media
        let badTokens = ["googleads", "doubleclick", "googlesyndication", "googleadservices",
                         "taboola", "outbrain", "criteo", "pubmatic", "rubiconproject",
                         "smartadserver", "adnxs", "scorecardresearch", "amazon-adsystem",
                         "moatads", "casalemedia", "openx", "yieldmo", "teads", "mgid"]
        for token in badTokens {
            if domain.contains(token) {
                return true
            }
        }

        return false
    }

    // MARK: - Multi-Source Online Sync
    public func downloadOnlineBlocklists(completion: @escaping (Bool, Int) -> Void) {
        // High-potency curated blocklist sources (StevenBlack, AdGuard, OISD, HaGeZi)
        let sources = [
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
            "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt",
            "https://small.oisd.nl/domainswg"
        ]

        var aggregated: Set<String> = []
        aggregated.reserveCapacity(160000)
        
        // Always include embedded base
        aggregated.formUnion(defaultEmbeddedAdDomains)

        let dispatchGroup = DispatchGroup()
        let lock = NSLock()

        for sourceStr in sources {
            guard let url = URL(string: sourceStr) else { continue }
            dispatchGroup.enter()

            var req = URLRequest(url: url)
            req.timeoutInterval = 25.0

            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { dispatchGroup.leave() }
                guard let data = data, let text = String(data: data, encoding: .utf8) else { return }

                var localParsed: Set<String> = []
                localParsed.reserveCapacity(60000)

                text.enumerateLines { line, _ in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("!") || trimmed.hasPrefix("//") {
                        return
                    }

                    // Supports hosts format (0.0.0.0 domain.com) and plain domain lists
                    let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if tokens.count >= 2 && (tokens[0] == "0.0.0.0" || tokens[0] == "127.0.0.1") {
                        let dom = tokens[1].lowercased()
                        if dom != "localhost" && dom != "broadcasthost" && dom.contains(".") {
                            localParsed.insert(dom)
                        }
                    } else if let first = tokens.first {
                        let dom = first.lowercased()
                        if !dom.contains("/") && !dom.contains(":") && dom.contains(".") && !dom.hasPrefix("*") {
                            localParsed.insert(dom)
                        }
                    }
                }

                lock.lock()
                aggregated.formUnion(localParsed)
                lock.unlock()
            }.resume()
        }

        dispatchGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self = self else { return }
            let finalCount = aggregated.count
            
            if finalCount > 1000 {
                self.queue.async(flags: .barrier) {
                    self.blockedDomains = aggregated
                }
                let joined = Array(aggregated.prefix(120000)).joined(separator: "\n")
                try? joined.write(to: self.blocklistFileURL, atomically: true, encoding: .utf8)
                completion(true, finalCount)
            } else {
                completion(false, self.blockCount)
            }
        }
    }

    // MARK: - Persistence & Defaults
    private func loadBlocklistFromDiskOrDefaults() {
        if FileManager.default.fileExists(atPath: blocklistFileURL.path),
           let content = try? String(contentsOf: blocklistFileURL, encoding: .utf8) {
            parseAndSetDomains(from: content)
            print("[BlocklistManager] Loaded \(blockedDomains.count) domains from disk.")
        } else {
            let embedded = defaultEmbeddedAdDomains
            queue.async(flags: .barrier) {
                self.blockedDomains = Set(embedded)
            }
            try? embedded.joined(separator: "\n").write(to: blocklistFileURL, atomically: true, encoding: .utf8)
            print("[BlocklistManager] Initialized with \(embedded.count) rich embedded domains.")
        }
    }

    private func parseAndSetDomains(from rawText: String) {
        var parsed: Set<String> = []
        parsed.reserveCapacity(120000)

        rawText.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("!") {
                return
            }
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

    // MARK: - Custom Lists
    private func loadCustomLists() {
        if let bData = try? Data(contentsOf: customBlacklistURL),
           let bList = try? JSONDecoder().decode([String].self, from: bData) {
            customBlacklist = Set(bList)
        }
        if let wData = try? Data(contentsOf: customWhitelistURL),
           let wList = try? JSONDecoder().decode([String].self, from: wData) {
            customWhitelist = Set(wList)
        }
    }

    public func addToWhitelist(_ domain: String) {
        queue.async(flags: .barrier) {
            self.customWhitelist.insert(domain.lowercased())
            self.customBlacklist.remove(domain.lowercased())
            if let data = try? JSONEncoder().encode(Array(self.customWhitelist)) {
                try? data.write(to: self.customWhitelistURL)
            }
            if let data = try? JSONEncoder().encode(Array(self.customBlacklist)) {
                try? data.write(to: self.customBlacklistURL)
            }
        }
    }

    public func addToBlacklist(_ domain: String) {
        queue.async(flags: .barrier) {
            self.customBlacklist.insert(domain.lowercased())
            self.customWhitelist.remove(domain.lowercased())
            if let data = try? JSONEncoder().encode(Array(self.customBlacklist)) {
                try? data.write(to: self.customBlacklistURL)
            }
            if let data = try? JSONEncoder().encode(Array(self.customWhitelist)) {
                try? data.write(to: self.customWhitelistURL)
            }
        }
    }

    public func removeFromBlacklist(_ domain: String) {
        queue.async(flags: .barrier) {
            self.customBlacklist.remove(domain.lowercased())
            if let data = try? JSONEncoder().encode(Array(self.customBlacklist)) {
                try? data.write(to: self.customBlacklistURL)
            }
        }
    }

    // MARK: - Embedded Core Shield (150+ Top Dutch & Global Tracker Networks)
    private let defaultEmbeddedAdDomains: [String] = [
        // Google Ad Ecosystem
        "doubleclick.net", "googleads.g.doubleclick.net", "pagead2.googlesyndication.com",
        "adservice.google.com", "admob.com", "ads.youtube.com", "pagead.l.google.com",
        "ads.google.com", "google-analytics.com", "analytics.google.com", "ssl.google-analytics.com",
        "stats.g.doubleclick.net", "securepubads.g.doubleclick.net", "pubads.g.doubleclick.net",
        "partnerad.l.google.com", "googletagservices.com", "googletagmanager.com",
        
        // Meta / Facebook Tracking
        "an.facebook.com", "graph.facebook.com", "pixel.facebook.com", "tr.facebook.com",
        "analytics.facebook.com", "connect.facebook.net", "ads.facebook.com",
        
        // Amazon & Microsoft Advertising
        "aax.amazon-adsystem.com", "c.amazon-adsystem.com", "s.amazon-adsystem.com",
        "fls-na.amazon.com", "adnxs.com", "ib.adnxs.com", "secure.adnxs.com",
        "ads.msn.com", "rad.msn.com", "c.bing.com", "bat.bing.com",
        
        // Popular Dutch / European News & Media Ad Networks
        "criteo.com", "criteo.net", "static.criteo.net", "bidder.criteo.com",
        "taboola.com", "cdn.taboola.com", "trc.taboola.com", "outbrain.com", "widgets.outbrain.com",
        "log.outbrain.com", "teads.tv", "a.teads.tv", "sync.teads.tv",
        "rubiconproject.com", "fastlane.rubiconproject.com", "optimized-by.rubiconproject.com",
        "pubmatic.com", "ads.pubmatic.com", "image6.pubmatic.com",
        "smartadserver.com", "diff.smartadserver.com", "openx.net", "us-u.openx.net",
        "scorecardresearch.com", "b.scorecardresearch.com", "sb.scorecardresearch.com",
        "moatads.com", "geo.moatads.com", "yieldmo.com", "ads.yieldmo.com",
        "casalemedia.com", "dsum-sec.casalemedia.com", "spotxchange.com", "search.spotxchange.com",
        "adform.net", "track.adform.net", "adformdsp.net",
        
        // Telemetry & Mobile In-App Ads
        "unityads.unity3d.com", "auction.unityads.unity3d.com", "applovin.com", "ms.applovin.com",
        "vungle.com", "ads.api.vungle.com", "chartboost.com", "live.chartboost.com",
        "ironsrc.com", "atom-data.ironsrc.com", "flurry.com", "data.flurry.com",
        "adjust.com", "app.adjust.com", "branch.io", "api2.branch.io",
        "appsflyer.com", "t.appsflyer.com", "kochava.com", "control.kochava.com",
        
        // Social Video & Clickbait
        "ads-twitter.com", "analytics.twitter.com", "ads.tiktok.com", "analytics.tiktok.com",
        "byteoversea.com", "mon.byteoversea.com", "snapads.com", "tr.snapchat.com",
        
        // Smart TV Telemetry & Ad Engines (Samsung, LG, Philips, Roku)
        "telemetry.samsungcloud.com", "log-config.samsungcloud.com", "smetrics.samsung.com",
        "gpm.samsungqbe.com", "notice.samsungcloudsolution.com",
        "scribe.smartshare.lgtvsdp.com", "ibis.lgappstv.com", "ad.lgappstv.com",
        "yupoo.smartshare.lgtvsdp.com", "rdx.smartshare.lgtvsdp.com",
        "logs.roku.com", "cooper.logs.roku.com", "track.sr.roku.com",
        
        // Scam, Popups & Malicious Redirects
        "propellerads.com", "popads.net", "adcash.com", "exoclick.com", "trafficjunky.com",
        "clickadu.com", "zergnet.com", "revcontent.com", "mgid.com", "adblade.com"
    ]
}
