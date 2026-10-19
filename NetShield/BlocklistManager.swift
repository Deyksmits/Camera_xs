import Foundation

/// Manages Ad, Tracker, and Telemetry domain lists with O(1) in-memory lookup.
public final class BlocklistManager {
    public static let shared = BlocklistManager()

    private var blockedDomains: Set<String> = []
    public private(set) var customBlacklist: Set<String> = []
    public private(set) var customWhitelist: Set<String> = []

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

    // MARK: - Fast Domain Check (Subdomain Matching)
    public func isDomainBlocked(_ domain: String) -> Bool {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return false }

        return queue.sync {
            // 1. Whitelist has priority
            if isDomainInSet(clean, set: customWhitelist) {
                return false
            }

            // 2. Custom Blacklist
            if isDomainInSet(clean, set: customBlacklist) {
                return true
            }

            // 3. Main Adblock Database
            return isDomainInSet(clean, set: blockedDomains)
        }
    }

    private func isDomainInSet(_ domain: String, set: Set<String>) -> Bool {
        if set.contains(domain) { return true }

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

    // MARK: - Persistence & Defaults
    private func loadBlocklistFromDiskOrDefaults() {
        if FileManager.default.fileExists(atPath: blocklistFileURL.path),
           let content = try? String(contentsOf: blocklistFileURL, encoding: .utf8) {
            parseAndSetDomains(from: content)
        } else {
            let embedded = defaultEmbeddedAdDomains
            queue.async(flags: .barrier) {
                self.blockedDomains = Set(embedded)
            }
            try? embedded.joined(separator: "\n").write(to: blocklistFileURL, atomically: true, encoding: .utf8)
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

    // MARK: - Online Sync
    public func downloadOnlineBlocklists(completion: @escaping (Bool, Int) -> Void) {
        let url = URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30.0

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil,
                  let text = String(data: data, encoding: .utf8) else {
                completion(false, self?.blockCount ?? 0)
                return
            }

            self.parseAndSetDomains(from: text)
            try? text.write(to: self.blocklistFileURL, atomically: true, encoding: .utf8)
            completion(true, self.blockCount)
        }.resume()
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
            if let data = try? JSONEncoder().encode(Array(self.customWhitelist)) {
                try? data.write(to: self.customWhitelistURL)
            }
        }
    }

    public func addToBlacklist(_ domain: String) {
        queue.async(flags: .barrier) {
            self.customBlacklist.insert(domain.lowercased())
            if let data = try? JSONEncoder().encode(Array(self.customBlacklist)) {
                try? data.write(to: self.customBlacklistURL)
            }
        }
    }

    // Embedded defaults
    private let defaultEmbeddedAdDomains: [String] = [
        "doubleclick.net", "googleads.g.doubleclick.net", "pagead2.googlesyndication.com",
        "adservice.google.com", "admob.com", "ads.youtube.com", "pagead.l.google.com",
        "ads.google.com", "an.facebook.com", "graph.facebook.com", "pixel.facebook.com",
        "ads-twitter.com", "analytics.twitter.com", "ads.tiktok.com", "analytics.tiktok.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "adnxs.com", "rubiconproject.com",
        "scorecardresearch.com", "pubmatic.com", "openx.net", "smartadserver.com",
        "adcolony.com", "unityads.unity3d.com", "appl运vin.com", "applovin.com", "vungle.com",
        "chartboost.com", "ironsrc.com", "flurry.com", "adjust.com", "branch.io", "appsflyer.com",
        "telemetry.samsungcloud.com", "log-config.samsungcloud.com", "smetrics.samsung.com",
        "scribe.smartshare.lgtvsdp.com", "ibis.lgappstv.com", "ad.lgappstv.com"
    ]
}
