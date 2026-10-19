import UIKit
import AVKit
import Photos

// MARK: - In-App Dashcam Galerij & Speler
class ClipsGalleryViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var lockedClips: [URL] = []
    private var regularClips: [URL] = []
    
    private let clipsDirectoryName = "DashcamClips"
    private let lockedDirectoryName = "LockedClips"
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadClips()
    }
    
    private func setupUI() {
        title = "Dashcam Opnames"
        view.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
        
        navigationController?.navigationBar.barTintColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        
        let closeBtn = UIBarButtonItem(title: "Sluiten", style: .done, target: self, action: #selector(closeTapped))
        closeBtn.tintColor = .systemCyan
        navigationItem.rightBarButtonItem = closeBtn
        
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
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
    
    private func loadClips() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let clipsDir = docs.appendingPathComponent(clipsDirectoryName)
        let lockedDir = docs.appendingPathComponent(lockedDirectoryName)
        
        if let lockedFiles = try? fm.contentsOfDirectory(at: lockedDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) {
            lockedClips = lockedFiles.filter { $0.pathExtension.lowercased() == "mp4" }
                .sorted { (u1, u2) -> Bool in
                    let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return d1 > d2
                }
        }
        
        if let regFiles = try? fm.contentsOfDirectory(at: clipsDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) {
            regularClips = regFiles.filter { $0.pathExtension.lowercased() == "mp4" }
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
            return lockedClips.isEmpty ? nil : "🔒 Vergrendelde Incident Clips (\(lockedClips.count))"
        } else {
            return regularClips.isEmpty ? "Geen recente ritten gevonden" : "📹 Recente Dashcam Ritten (\(regularClips.count))"
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "ClipCell")
        cell.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
        cell.textLabel?.textColor = .white
        cell.detailTextLabel?.textColor = .lightGray
        cell.accessoryType = .disclosureIndicator
        
        let url = indexPath.section == 0 ? lockedClips[indexPath.row] : regularClips[indexPath.row]
        let name = url.lastPathComponent
        let isRoad = name.contains("_ROAD")
        let isCabin = name.contains("_CABIN")
        
        let icon = isRoad ? "🛣️" : (isCabin ? "🚘" : "📹")
        let badge = isRoad ? "[Weg]" : (isCabin ? "[Cabine]" : "")
        cell.textLabel?.text = "\(icon) \(name.replacingOccurrences(of: "SmartDash_", with: "").replacingOccurrences(of: ".mp4", with: "")) \(badge)"
        
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
           let size = values.fileSize,
           let date = values.creationDate {
            let mb = Double(size) / (1024 * 1024)
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            cell.detailTextLabel?.text = "\(formatter.string(from: date)) • \(String(format: "%.1f MB", mb))"
        }
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let url = indexPath.section == 0 ? lockedClips[indexPath.row] : regularClips[indexPath.row]
        
        // Controleer of de tegenhanger (bijv. CABIN bij ROAD) ook bestaat
        let companionURL: URL?
        if url.lastPathComponent.contains("_ROAD") {
            companionURL = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: "_ROAD", with: "_CABIN"))
        } else if url.lastPathComponent.contains("_CABIN") {
            companionURL = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: "_CABIN", with: "_ROAD"))
        } else {
            companionURL = nil
        }
        
        let alert = UIAlertController(title: "Opties voor opname", message: url.lastPathComponent, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "▶️ Video Afspelen", style: .default, handler: { [weak self] _ in
            self?.playVideo(url: url)
        }))
        
        if let companion = companionURL, FileManager.default.fileExists(atPath: companion.path) {
            let compName = companion.lastPathComponent.contains("_CABIN") ? "Cabinebeeld" : "Wegbeeld"
            alert.addAction(UIAlertAction(title: "🔄 Bekijk \(compName)", style: .default, handler: { [weak self] _ in
                self?.playVideo(url: companion)
            }))
        }
        
        alert.addAction(UIAlertAction(title: "💾 Opslaan in Foto's", style: .default, handler: { [weak self] _ in
            self?.saveToPhotos(url: url)
        }))
        
        alert.addAction(UIAlertAction(title: "📤 Delen / Exporteren", style: .default, handler: { [weak self] _ in
            self?.shareVideo(url: url)
        }))
        
        alert.addAction(UIAlertAction(title: "🗑️ Verwijderen", style: .destructive, handler: { [weak self] _ in
            try? FileManager.default.removeItem(at: url)
            self?.loadClips()
        }))
        
        alert.addAction(UIAlertAction(title: "Annuleren", style: .cancel))
        present(alert, animated: true)
    }
    
    private func playVideo(url: URL) {
        let player = AVPlayer(url: url)
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        present(playerVC, animated: true) {
            player.play()
        }
    }
    
    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                let msg = success ? "Video succesvol opgeslagen in je camerarol!" : "Fout bij opslaan: \(error?.localizedDescription ?? "Onbekend")"
                let feedback = UIAlertController(title: success ? "Opgeslagen" : "Fout", message: msg, preferredStyle: .alert)
                feedback.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(feedback, animated: true)
            }
        }
    }
    
    private func shareVideo(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(activityVC, animated: true)
    }
}
