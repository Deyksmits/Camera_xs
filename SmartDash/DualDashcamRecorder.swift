import Foundation
import AVFoundation
import UIKit

// MARK: - DualDashcamRecorder Delegate
protocol DualDashcamRecorderDelegate: AnyObject {
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didUpdateRecordingDuration duration: TimeInterval)
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didCompleteSegment roadURL: URL, cabinURL: URL?)
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didLockSegment url: URL)
    func dashcamRecorder(_ recorder: DualDashcamRecorder, didUpdateStorageUsage bytesUsed: Int64, maxBytes: Int64)
}

// MARK: - DualDashcamRecorder (30 FPS Weg + Selfie Camera)
class DualDashcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    weak var delegate: DualDashcamRecorderDelegate?
    
    // AVCapture Sessions
    private var captureSession: AVCaptureSession?
    private var isMultiCamActive = false
    
    // Outputs
    private let roadVideoOutput = AVCaptureVideoDataOutput()
    private let cabinVideoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    
    // Dedicated Queues
    private let sessionQueue = DispatchQueue(label: "com.smartdash.sessionqueue")
    private let roadQueue = DispatchQueue(label: "com.smartdash.roadqueue")
    private let cabinQueue = DispatchQueue(label: "com.smartdash.cabinqueue")
    private let audioQueue = DispatchQueue(label: "com.smartdash.audioqueue")
    
    // Opname Status & Writers
    private(set) var isRecording = false
    private var segmentStartTime: Date?
    private var currentSegmentIndex = 0
    private let segmentDuration: TimeInterval = 180.0 // 3 minuten per loop segment
    var maxStorageBytes: Int64 = 10 * 1024 * 1024 * 1024 // 10 GB opslaglimiet
    
    // Actieve Writers
    private var roadAssetWriter: AVAssetWriter?
    private var roadVideoInput: AVAssetWriterInput?
    private var roadAudioInput: AVAssetWriterInput?
    private(set) var roadCurrentURL: URL?
    private var roadSessionStarted = false
    
    private var cabinAssetWriter: AVAssetWriter?
    private var cabinVideoInput: AVAssetWriterInput?
    private(set) var cabinCurrentURL: URL?
    private var cabinSessionStarted = false
    
    // Mappen
    private let clipsDirectoryName = "DashcamClips"
    private let lockedDirectoryName = "LockedClips"
    
    private var timer: Timer?
    
    override init() {
        super.init()
        createDirectoriesIfNeeded()
    }
    
    // MARK: - Directory Beheer
    var clipsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(clipsDirectoryName, isDirectory: true)
    }
    
    var lockedDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(lockedDirectoryName, isDirectory: true)
    }
    
    private func createDirectoriesIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Setup Capture Session
    func setupAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if AVCaptureMultiCamSession.isMultiCamSupported {
                self.setupMultiCamSession()
            } else {
                self.setupStandardSession()
            }
        }
    }
    
    // MARK: - Dual Camera Setup (iPhone XS A12 Bionic)
    private func setupMultiCamSession() {
        let multiSession = AVCaptureMultiCamSession()
        multiSession.beginConfiguration()
        
        // 1. Weg Camera (Achterkant)
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let backInput = try? AVCaptureDeviceInput(device: backCamera) else {
            print("SmartDash: Kon achtercamera niet initialiseren")
            multiSession.commitConfiguration()
            setupStandardSession()
            return
        }
        
        // Configureer 30 FPS en Autofocus
        do {
            try backCamera.lockForConfiguration()
            backCamera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            backCamera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            if backCamera.isFocusModeSupported(.continuousAutoFocus) {
                backCamera.focusMode = .continuousAutoFocus
            }
            if backCamera.isExposureModeSupported(.continuousAutoExposure) {
                backCamera.exposureMode = .continuousAutoExposure
            }
            backCamera.unlockForConfiguration()
        } catch {
            print("SmartDash: Fout bij configureren achtercamera: \(error)")
        }
        
        if multiSession.canAddInput(backInput) {
            multiSession.addInputWithNoConnections(backInput)
        }
        
        roadVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        roadVideoOutput.setSampleBufferDelegate(self, queue: roadQueue)
        if multiSession.canAddOutput(roadVideoOutput) {
            multiSession.addOutputWithNoConnections(roadVideoOutput)
        }
        
        if let backPort = backInput.ports(for: .video, sourceDeviceType: backCamera.deviceType, sourceDevicePosition: .back).first {
            let roadConn = AVCaptureConnection(inputPorts: [backPort], output: roadVideoOutput)
            if roadConn.isVideoOrientationSupported {
                roadConn.videoOrientation = .landscapeRight
            }
            if multiSession.canAddConnection(roadConn) {
                multiSession.addConnection(roadConn)
            }
        }
        
        // 2. Cabine Camera (Selfie camera)
        if let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let frontInput = try? AVCaptureDeviceInput(device: frontCamera) {
            
            do {
                try frontCamera.lockForConfiguration()
                frontCamera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                frontCamera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                frontCamera.unlockForConfiguration()
            } catch {
                print("SmartDash: Fout bij configureren frontcamera: \(error)")
            }
            
            if multiSession.canAddInput(frontInput) {
                multiSession.addInputWithNoConnections(frontInput)
            }
            
            cabinVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            cabinVideoOutput.setSampleBufferDelegate(self, queue: cabinQueue)
            if multiSession.canAddOutput(cabinVideoOutput) {
                multiSession.addOutputWithNoConnections(cabinVideoOutput)
            }
            
            if let frontPort = frontInput.ports(for: .video, sourceDeviceType: frontCamera.deviceType, sourceDevicePosition: .front).first {
                let cabinConn = AVCaptureConnection(inputPorts: [frontPort], output: cabinVideoOutput)
                if cabinConn.isVideoOrientationSupported {
                    cabinConn.videoOrientation = .landscapeRight
                }
                if multiSession.canAddConnection(cabinConn) {
                    multiSession.addConnection(cabinConn)
                }
            }
        }
        
        // 3. Audio Microfoon
        if let micDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: micDevice) {
            if multiSession.canAddInput(audioInput) {
                multiSession.addInput(audioInput)
            }
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if multiSession.canAddOutput(audioOutput) {
                multiSession.addOutput(audioOutput)
            }
        }
        
        multiSession.commitConfiguration()
        self.captureSession = multiSession
        self.isMultiCamActive = true
        multiSession.startRunning()
        print("SmartDash: Dual Multi-Cam sessie actief op 30 FPS!")
    }
    
    // MARK: - Standaard Fallback Session
    private func setupStandardSession() {
        let singleSession = AVCaptureSession()
        singleSession.beginConfiguration()
        singleSession.sessionPreset = .hd1920x1080
        
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let backInput = try? AVCaptureDeviceInput(device: backCamera) else {
            singleSession.commitConfiguration()
            return
        }
        
        do {
            try backCamera.lockForConfiguration()
            backCamera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            backCamera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            backCamera.unlockForConfiguration()
        } catch { }
        
        if singleSession.canAddInput(backInput) {
            singleSession.addInput(backInput)
        }
        
        roadVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        roadVideoOutput.setSampleBufferDelegate(self, queue: roadQueue)
        if singleSession.canAddOutput(roadVideoOutput) {
            singleSession.addOutput(roadVideoOutput)
        }
        
        if let mic = AVCaptureDevice.default(for: .audio),
           let audioIn = try? AVCaptureDeviceInput(device: mic) {
            if singleSession.canAddInput(audioIn) { singleSession.addInput(audioIn) }
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if singleSession.canAddOutput(audioOutput) { singleSession.addOutput(audioOutput) }
        }
        
        singleSession.commitConfiguration()
        self.captureSession = singleSession
        self.isMultiCamActive = false
        singleSession.startRunning()
        print("SmartDash: Single camera sessie actief op 30 FPS.")
    }
    
    // MARK: - Opname Starten / Stoppen
    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.isRecording else { return }
            self.startNewSegment()
            
            DispatchQueue.main.async {
                self.isRecording = true
                self.startDurationTimer()
            }
        }
    }
    
    func stopRecording(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self = self, self.isRecording else {
                DispatchQueue.main.async { completion?() }
                return
            }
            self.finishCurrentSegment {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.timer?.invalidate()
                    self.timer = nil
                    self.delegate?.dashcamRecorder(self, didUpdateRecordingDuration: 0)
                    completion?()
                }
            }
        }
    }
    
    // MARK: - Segment Loop Beheer
    private func startNewSegment() {
        finishCurrentSegment(completion: nil)
        
        currentSegmentIndex += 1
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        
        let roadURL = clipsDirectory.appendingPathComponent("SmartDash_\(timestamp)_ROAD.mp4")
        let cabinURL = clipsDirectory.appendingPathComponent("SmartDash_\(timestamp)_CABIN.mp4")
        
        self.roadCurrentURL = roadURL
        self.cabinCurrentURL = cabinURL
        self.roadSessionStarted = false
        self.cabinSessionStarted = false
        
        // 1. Initialiseer Road Writer (1080p H.264 @ 30 FPS)
        do {
            let rWriter = try AVAssetWriter(outputURL: roadURL, fileType: .mp4)
            rWriter.shouldOptimizeForNetworkUse = true
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30
                ]
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            if rWriter.canAdd(vInput) {
                rWriter.add(vInput)
            }
            
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: 64000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if rWriter.canAdd(aInput) {
                rWriter.add(aInput)
            }
            
            rWriter.startWriting()
            self.roadAssetWriter = rWriter
            self.roadVideoInput = vInput
            self.roadAudioInput = aInput
        } catch {
            print("SmartDash: Kon roadAssetWriter niet maken: \(error)")
        }
        
        // 2. Initialiseer Cabin Writer (indien MultiCam actief)
        if isMultiCamActive {
            do {
                let cWriter = try AVAssetWriter(outputURL: cabinURL, fileType: .mp4)
                cWriter.shouldOptimizeForNetworkUse = true
                
                let cabinSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 1280,
                    AVVideoHeightKey: 720,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 3_500_000,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                        AVVideoExpectedSourceFrameRateKey: 30
                    ]
                ]
                let cInput = AVAssetWriterInput(mediaType: .video, outputSettings: cabinSettings)
                cInput.expectsMediaDataInRealTime = true
                if cWriter.canAdd(cInput) {
                    cWriter.add(cInput)
                }
                cWriter.startWriting()
                self.cabinAssetWriter = cWriter
                self.cabinVideoInput = cInput
            } catch {
                print("SmartDash: Kon cabinAssetWriter niet maken: \(error)")
            }
        }
        
        self.segmentStartTime = Date()
        pruneStorageIfNeeded()
    }
    
    private func finishCurrentSegment(completion: (() -> Void)?) {
        let rWriter = self.roadAssetWriter
        let rInput = self.roadVideoInput
        let aInput = self.roadAudioInput
        let cWriter = self.cabinAssetWriter
        let cInput = self.cabinVideoInput
        let finishedRoadURL = self.roadCurrentURL
        let finishedCabinURL = self.cabinCurrentURL
        
        self.roadAssetWriter = nil
        self.roadVideoInput = nil
        self.roadAudioInput = nil
        self.cabinAssetWriter = nil
        self.cabinVideoInput = nil
        self.roadCurrentURL = nil
        self.cabinCurrentURL = nil
        
        rInput?.markAsFinished()
        aInput?.markAsFinished()
        cInput?.markAsFinished()
        
        let group = DispatchGroup()
        
        if let rWriter = rWriter, rWriter.status == .writing {
            group.enter()
            rWriter.finishWriting {
                if let rURL = finishedRoadURL {
                    print("SmartDash: Wegsegment succesvol afgerond: \(rURL.lastPathComponent)")
                }
                group.leave()
            }
        }
        
        if let cWriter = cWriter, cWriter.status == .writing {
            group.enter()
            cWriter.finishWriting {
                if let cURL = finishedCabinURL {
                    print("SmartDash: Cabinesegment succesvol afgerond: \(cURL.lastPathComponent)")
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            if let rURL = finishedRoadURL {
                self.delegate?.dashcamRecorder(self, didCompleteSegment: rURL, cabinURL: finishedCabinURL)
            }
            completion?()
        }
    }
    
    // MARK: - AVCapture Video & Audio Callbacks (30 FPS)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if output == roadVideoOutput {
            guard let writer = roadAssetWriter, writer.status == .writing, let input = roadVideoInput, input.isReadyForMoreMediaData else { return }
            
            if !roadSessionStarted {
                writer.startSession(atSourceTime: timestamp)
                roadSessionStarted = true
            }
            input.append(sampleBuffer)
            
        } else if output == cabinVideoOutput {
            guard let writer = cabinAssetWriter, writer.status == .writing, let input = cabinVideoInput, input.isReadyForMoreMediaData else { return }
            
            if !cabinSessionStarted {
                writer.startSession(atSourceTime: timestamp)
                cabinSessionStarted = true
            }
            input.append(sampleBuffer)
            
        } else if output == audioOutput {
            // Audio pas appenden nadat de videosessie gestart is om corruptie te voorkomen
            guard roadSessionStarted, let writer = roadAssetWriter, writer.status == .writing,
                  let input = roadAudioInput, input.isReadyForMoreMediaData else { return }
            input.append(sampleBuffer)
        }
    }
    
    // MARK: - Loop Timer & Duur
    private func startDurationTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording, let start = self.segmentStartTime else { return }
            
            let elapsed = Date().timeIntervalSince(start)
            self.delegate?.dashcamRecorder(self, didUpdateRecordingDuration: elapsed)
            
            // Controleer of segment van 3 minuten voorbij is
            if elapsed >= self.segmentDuration {
                self.sessionQueue.async {
                    self.startNewSegment()
                }
            }
        }
    }
    
    // MARK: - Noodvergrendeling / Botsingsbescherming
    func lockCurrentSegment(reason: String = "Handmatig vergrendeld") {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let fm = FileManager.default
            if let roadURL = self.roadCurrentURL {
                let lockedRoad = self.lockedDirectory.appendingPathComponent(roadURL.lastPathComponent)
                try? fm.copyItem(at: roadURL, to: lockedRoad)
                DispatchQueue.main.async {
                    self.delegate?.dashcamRecorder(self, didLockSegment: lockedRoad)
                }
            }
            if let cabinURL = self.cabinCurrentURL {
                let lockedCabin = self.lockedDirectory.appendingPathComponent(cabinURL.lastPathComponent)
                try? fm.copyItem(at: cabinURL, to: lockedCabin)
            }
            print("SmartDash: Incident clip beveiligd! Reden: \(reason)")
        }
    }
    
    // MARK: - Storage Cleanup (Rolling Buffer)
    private func pruneStorageIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey], options: .skipsHiddenFiles) else { return }
        
        var totalBytes: Int64 = 0
        var fileList: [(url: URL, date: Date, size: Int64)] = []
        
        for file in files where file.pathExtension.lowercased() == "mp4" {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.creationDate ?? Date.distantPast
            totalBytes += size
            fileList.append((file, date, size))
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.dashcamRecorder(self, didUpdateStorageUsage: totalBytes, maxBytes: self.maxStorageBytes)
        }
        
        // Als totale opslag de limiet overschrijdt, verwijder oudste bestanden tot onder 80% van de limiet
        if totalBytes > maxStorageBytes {
            fileList.sort { $0.date < $1.date }
            
            for item in fileList {
                if item.url == roadCurrentURL || item.url == cabinCurrentURL { continue }
                
                try? fm.removeItem(at: item.url)
                totalBytes -= item.size
                print("SmartDash: Oude clip gerecycled: \(item.url.lastPathComponent)")
                if totalBytes < Int64(Double(maxStorageBytes) * 0.80) {
                    break
                }
            }
        }
    }
}
