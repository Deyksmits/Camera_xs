import UIKit
import AVKit
import Photos

// MARK: - In-App Dashcam Galerij & Speler (Flitsmeister / Dark Cockpit Stijl)
class ClipsGalleryViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var lockedClips: [URL] = []
    private var regularClips: [URL] = []
    
    private let clipsDirectoryName = "DashcamClips"
    private let lockedDirectoryName = "LockedClips"
    
    // Cache voor thumbnails
    private let thumbnailCache = NSCache<NSURL, UIImage>()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadClips()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadClips()
    }
    
    private func setupUI() {
        title = "Dashcam Ritten & Opnames"
        view.backgroundColor = UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1.0)
        
        navigationController?.navigationBar.barTintColor = UIColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1.0)
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 17, weight: .bold)]
        
        let closeBtn = UIBarButtonItem(title: "Gereed", style: .done, target: self, action: #selector(closeTapped))
        closeBtn.tintColor = .systemCyan
        navigationItem.rightBarButtonItem = closeBtn
        
        let refreshBtn = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refreshTapped))
        refreshBtn.tintColor = .systemCyan
        navigationItem.leftBarButtonItem = refreshBtn
        
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.08)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 72
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ClipCell")
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    @objc private func closeTapped() {
        dismiss(animated: true)
    }
    
    @objc private func refreshTapped() {
        loadClips()
    }
    
    private func loadClips() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let clipsDir = docs.appendingPathComponent(clipsDirectoryName)
        let lockedDir = docs.appendingPathComponent(lockedDirectoryName)
        
        // 1. Vergrendelde clips
        if let lockedFiles = try? fm.contentsOfDirectory(at: lockedDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: .skipsHiddenFiles) {
            lockedClips = lockedFiles
                .filter { $0.pathExtension.lowercased() == "mp4" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 10240 }
                .sorted { (u1, u2) -> Bool in
                    let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return d1 > d2
                }
        }
        
        // 2. Reguliere ritten (filter bestanden kleiner dan 10 KB of nog in aanbouw)
        if let regFiles = try? fm.contentsOfDirectory(at: clipsDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: .skipsHiddenFiles) {
            regularClips = regFiles
                .filter { $0.pathExtension.lowercased() == "mp4" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 10240 }
                .sorted { (u1, u2) -> Bool in
                    let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return d1 > d2
                }
        }
        
        tableView.reloadData()
    }
    
    // MARK: - TableView Data Source
    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? lockedClips.count : regularClips.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 {
            return lockedClips.isEmpty ? nil : "🔒 Noodvergrendelde Incidenten (\(lockedClips.count))"
        } else {
            return regularClips.isEmpty ? "Geen afgeronde ritten gevonden" : "📹 Recente Dashcam Ritten (\(regularClips.count))"
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "ClipCell")
        cell.backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 0.95)
        cell.layer.cornerRadius = 12
        cell.clipsToBounds = true
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        cell.detailTextLabel?.textColor = UIColor(red: 0.7, green: 0.75, blue: 0.85, alpha: 1.0)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        cell.accessoryType = .disclosureIndicator
        
        let url = indexPath.section == 0 ? lockedClips[indexPath.row] : regularClips[indexPath.row]
        let name = url.lastPathComponent
        let isRoad = name.contains("_ROAD")
        let isCabin = name.contains("_CABIN")
        
        let icon = isRoad ? "🛣️" : (isCabin ? "🚘" : "📹")
        let cameraLabel = isRoad ? "Wegbeeld (1080p)" : (isCabin ? "Cabine / Interieur" : "Video")
        
        // Formatteer bestandsnaam voor leesbare datum/tijd
        let rawDate = name.replacingOccurrences(of: "SmartDash_", with: "")
                          .replacingOccurrences(of: "_ROAD.mp4", with: "")
                          .replacingOccurrences(of: "_CABIN.mp4", with: "")
                          .replacingOccurrences(of: ".mp4", with: "")
        
        cell.textLabel?.text = "\(icon) \(cameraLabel)"
        
        var sizeMBString = "0 MB"
        var dateString = rawDate
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) {
            if let size = values.fileSize {
                let mb = Double(size) / (1024 * 1024)
                sizeMBString = String(format: "%.1f MB", mb)
            }
            if let date = values.creationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
                dateString = formatter.string(from: date)
            }
        }
        cell.detailTextLabel?.text = "\(dateString) • \(sizeMBString)"
        
        // Laad thumbnail asynchroon
        generateThumbnail(for: url) { image in
            DispatchQueue.main.async {
                if let updateCell = tableView.cellForRow(at: indexPath) {
                    updateCell.imageView?.image = image
                    updateCell.imageView?.layer.cornerRadius = 6
                    updateCell.imageView?.clipsToBounds = true
                    updateCell.setNeedsLayout()
                }
            }
        }
        
        return cell
    }
    
    private func generateThumbnail(for url: URL, completion: @escaping (UIImage?) -> Void) {
        if let cached = thumbnailCache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 120, height: 80)
            
            let time = CMTime(seconds: 1.0, preferredTimescale: 60)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let image = UIImage(cgImage: cgImage)
                self?.thumbnailCache.setObject(image, forKey: url as NSURL)
                completion(image)
            } else {
                completion(nil)
            }
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let url = indexPath.section == 0 ? lockedClips[indexPath.row] : regularClips[indexPath.row]
        
        // Controleer of de companion clip bestaat (bijv. wegbeeld <-> cabinebeeld)
        let companionURL: URL?
        if url.lastPathComponent.contains("_ROAD") {
            companionURL = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: "_ROAD", with: "_CABIN"))
        } else if url.lastPathComponent.contains("_CABIN") {
            companionURL = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: "_CABIN", with: "_ROAD"))
        } else {
            companionURL = nil
        }
        
        let alert = UIAlertController(title: "Opties voor opname", message: url.lastPathComponent, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "▶️ Video Direct Bekijken", style: .default, handler: { [weak self] _ in
            self?.playVideo(url: url)
        }))
        
        if let companion = companionURL, FileManager.default.fileExists(atPath: companion.path) {
            let compName = companion.lastPathComponent.contains("_CABIN") ? "Cabinebeeld" : "Wegbeeld"
            alert.addAction(UIAlertAction(title: "🔄 Bekijk \(compName)", style: .default, handler: { [weak self] _ in
                self?.playVideo(url: companion)
            }))
        }
        
        alert.addAction(UIAlertAction(title: "💾 Opslaan in Foto's (Camerarol)", style: .default, handler: { [weak self] _ in
            self?.saveToPhotos(url: url)
        }))
        
        alert.addAction(UIAlertAction(title: "📤 Delen / Exporteren via AirDrop", style: .default, handler: { [weak self] _ in
            self?.shareVideo(url: url)
        }))
        
        alert.addAction(UIAlertAction(title: "🗑️ Verwijderen", style: .destructive, handler: { [weak self] _ in
            try? FileManager.default.removeItem(at: url)
            if let companion = companionURL, FileManager.default.fileExists(atPath: companion.path) {
                try? FileManager.default.removeItem(at: companion)
            }
            self?.loadClips()
        }))
        
        alert.addAction(UIAlertAction(title: "Annuleren", style: .cancel))
        present(alert, animated: true)
    }
    
    // MARK: - Video Afspelen
    private func playVideo(url: URL) {
        // Zorg dat audio sessie in playback modus staat zodat het hoorbaar is over de speaker
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Playback audio error: \(error)")
        }
        
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.showsPlaybackControls = true
        
        present(playerVC, animated: true) {
            player.play()
        }
    }
    
    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                let title = success ? "Succesvol Opgeslagen" : "Fout bij Opslaan"
                let msg = success ? "De video staat nu in je Foto's app!" : (error?.localizedDescription ?? "Onbekende fout")
                let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }
    
    private func shareVideo(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(activityVC, animated: true)
    }
}
