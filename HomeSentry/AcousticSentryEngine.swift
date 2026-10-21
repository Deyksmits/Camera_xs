import Foundation
import AVFoundation
import SoundAnalysis

// MARK: - Akoestische Event Categorieën
public enum AcousticEventType: String, Codable, CaseIterable {
    case glassBreak = "glass_break"
    case smokeAlarm = "smoke_alarm"
    case waterLeak = "water_leak"
    case doorKnock = "door_knock"
    case dogBark = "dog_bark"
    case loudNoise = "loud_noise"
    
    public var displayName: String {
        switch self {
        case .glassBreak: return "Glasbreuk"
        case .smokeAlarm: return "Rookmelder / Brandalarm"
        case .waterLeak: return "Waterlekkage / Druppels"
        case .doorKnock: return "Kloppen op Voordeur / Bel"
        case .dogBark: return "Hondengeblaf"
        case .loudNoise: return "Harde Knal / Impact"
        }
    }
    
    public var emoji: String {
        switch self {
        case .glassBreak: return "🚨"
        case .smokeAlarm: return "🔥"
        case .waterLeak: return "💧"
        case .doorKnock: return "🚪"
        case .dogBark: return "🐕"
        case .loudNoise: return "💥"
        }
    }
    
    public var isEmergency: Bool {
        switch self {
        case .glassBreak, .smokeAlarm, .waterLeak:
            return true
        default:
            return false
        }
    }
}

// MARK: - Akoestisch Event Model
public struct AcousticLogEntry: Codable, Identifiable {
    public let id: String
    public let type: AcousticEventType
    public let confidence: Float
    public let decibels: Float
    public let timestamp: Date
    
    public init(type: AcousticEventType, confidence: Float, decibels: Float, timestamp: Date = Date()) {
        self.id = UUID().uuidString
        self.type = type
        self.confidence = confidence
        self.decibels = decibels
        self.timestamp = timestamp
    }
    
    public var timeString: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: timestamp)
    }
    
    public var emoji: String {
        return type.emoji
    }
    
    public var displayName: String {
        return type.displayName
    }
}

// MARK: - Akoestische Sensor & Geluidsclassificatie Engine
public final class AcousticSentryEngine: NSObject, SNResultsObserving {
    public static let shared = AcousticSentryEngine()
    
    private let audioEngine = AVAudioEngine()
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.homesentry.acoustic.queue", qos: .userInitiated)
    
    // Telemetrie
    public private(set) var isRunning: Bool = false
    public private(set) var currentDecibels: Float = 0.0
    public private(set) var peakDecibels: Float = 0.0
    public private(set) var recentEvents: [AcousticLogEntry] = []
    
    // Cooldown trackers om notificatiespam te voorkomen
    private var lastEventTime: [AcousticEventType: Date] = [:]
    private let eventCooldownSeconds: TimeInterval = 6.0
    
    // Dedicated 3.1 kHz Rookmelder T3 Piep-accumulator
    private var consecutiveSmokeToneFrames: Int = 0
    
    // Callbacks
    public var onAcousticEvent: ((AcousticLogEntry) -> Void)?
    public var onEmergencyAlert: ((AcousticLogEntry) -> Void)?
    
    private override init() {
        super.init()
    }
    
    public func start() {
        guard !isRunning else { return }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                print("❌ [AcousticEngine] Ongeldig audio input formaat")
                return
            }
            
            streamAnalyzer = SNAudioStreamAnalyzer(format: inputFormat)
            
            // Start Apple SoundAnalysis AI Classifier
            do {
                let classifyRequest = try SNClassifySoundRequest(classifierIdentifier: .version1)
                classifyRequest.windowDuration = CMTimeMakeWithSeconds(1.0, preferredTimescale: 44100)
                classifyRequest.overlapFactor = 0.5
                try streamAnalyzer?.add(classifyRequest, withObserver: self)
                print("🧠 [AcousticEngine] Apple SoundAnalysis AI classifier geladen")
            } catch {
                print("⚠️ [AcousticEngine] Kon SoundAnalysis classifier niet laden: \(error)")
            }
            
            // Audio tap opnemen voor decibelberekening en spectrale analyse
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, time in
                guard let self = self else { return }
                
                // Decibels berekenen
                self.calculateDecibels(buffer: buffer)
                
                // Hardware 3.1 kHz Rookmelder detector
                self.analyzeSmokeTone(buffer: buffer)
                
                // Doorsturen naar SoundAnalysis analyzer
                self.analysisQueue.async {
                    self.streamAnalyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
                }
            }
            
            try audioEngine.start()
            isRunning = true
            print("🎙️ [AcousticEngine] Akoestische 24/7 monitor actief")
        } catch {
            print("❌ [AcousticEngine] Fout bij starten audio engine: \(error)")
            isRunning = false
        }
    }
    
    public func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        streamAnalyzer?.removeAllRequests()
        streamAnalyzer = nil
        isRunning = false
        print("🛑 [AcousticEngine] Akoestische monitor gestopt")
    }
    
    // MARK: - Decibel Berekening (RMS)
    private func calculateDecibels(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        
        var sum: Float = 0.0
        for i in 0..<frames {
            let sample = channelData[i]
            sum += sample * sample
        }
        
        let rms = sqrt(sum / Float(frames))
        // Omrekenen naar dBFS en kalibreren naar geschatte dB SPL (30dB - 110dB)
        let dbFS = 20 * log10(max(rms, 0.00001))
        let dbSPL = max(28.0, min(115.0, dbFS + 98.0))
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentDecibels = self.currentDecibels * 0.7 + dbSPL * 0.3
            self.peakDecibels = max(self.peakDecibels * 0.98, self.currentDecibels)
        }
    }
    
    // MARK: - 3.1 kHz Piep-Detectie voor Standaard Rookmelders
    private func analyzeSmokeTone(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames >= 512 else { return }
        
        let sampleRate = Float(buffer.format.sampleRate)
        guard sampleRate > 8000 else { return }
        
        // Goertzel filter afgestemd op 3100 Hz (Europese rookmeldertoon)
        let targetFreq: Float = 3100.0
        let k = Int(0.5 + Float(frames) * targetFreq / sampleRate)
        let omega = (2.0 * Float.pi * Float(k)) / Float(frames)
        let coeff = 2.0 * cos(omega)
        
        var q0: Float = 0.0
        var q1: Float = 0.0
        var q2: Float = 0.0
        var totalPower: Float = 0.0
        
        for i in 0..<frames {
            let x = channelData[i]
            totalPower += x * x
            q0 = coeff * q1 - q2 + x
            q2 = q1
            q1 = q0
        }
        
        let tonePower = q1 * q1 + q2 * q2 - q1 * q2 * coeff
        
        // Als > 35% van alle audio-energie in de 3.1 kHz piepband zit bij > 72 dB SPL
        if totalPower > 0.005 && (tonePower / (totalPower * Float(frames))) > 0.35 && currentDecibels > 70.0 {
            consecutiveSmokeToneFrames += 1
            if consecutiveSmokeToneFrames >= 4 { // Aanhoudende T3 piep
                consecutiveSmokeToneFrames = 0
                emitAcousticEvent(type: .smokeAlarm, confidence: 0.94, decibels: currentDecibels)
            }
        } else {
            consecutiveSmokeToneFrames = max(0, consecutiveSmokeToneFrames - 1)
        }
    }
    
    // MARK: - SNResultsObserving (Apple SoundAnalysis)
    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        
        // Inspecteer top classificaties
        for obs in classification.classifications.prefix(15) where obs.confidence > 0.38 {
            let id = obs.identifier.lowercased()
            let conf = Float(obs.confidence)
            
            var matchedType: AcousticEventType?
            
            // 1. Glasbreuk
            if id.contains("glass_breaking") || id.contains("glass") || id.contains("shatter") || id.contains("smash") {
                matchedType = .glassBreak
            }
            // 2. Rookmelder / Alarm
            else if id.contains("smoke_detector") || id.contains("fire_alarm") || id.contains("smoke_alarm") ||
                    id.contains("siren") || id.contains("beeping") || id.contains("alarm") {
                matchedType = .smokeAlarm
            }
            // 3. Waterlekkage / Druppels
            else if id.contains("water_tap") || id.contains("trickle") || id.contains("drip") ||
                    id.contains("dripping") || id.contains("pour") || id.contains("gush") {
                matchedType = .waterLeak
            }
            // 4. Kloppen / Deurbel
            else if id.contains("door_knock") || id.contains("knock") || id.contains("doorbell") || id.contains("bell") {
                matchedType = .doorKnock
            }
            // 5. Hondengeblaf
            else if id.contains("dog_bark") || id.contains("bark") || id.contains("dog") || id.contains("howl") {
                matchedType = .dogBark
            }
            // 6. Harde Knal / Schreeuw
            else if id.contains("screaming") || id.contains("shout") || id.contains("explosion") || id.contains("gunshot") {
                matchedType = .loudNoise
            }
            
            if let type = matchedType {
                emitAcousticEvent(type: type, confidence: conf, decibels: currentDecibels)
                break
            }
        }
    }
    
    public func request(_ request: SNRequest, didFailWithError error: Error) {
        print("⚠️ [AcousticEngine] SoundAnalysis verzoek fout: \(error)")
    }
    
    public func requestDidComplete(_ request: SNRequest) {
        // Voltooid
    }
    
    // MARK: - Event Uitzenden & Cooldown Filter
    private func emitAcousticEvent(type: AcousticEventType, confidence: Float, decibels: Float) {
        let now = Date()
        if let last = lastEventTime[type], now.timeIntervalSince(last) < eventCooldownSeconds {
            return // Binnen cooldown
        }
        lastEventTime[type] = now
        
        let entry = AcousticLogEntry(type: type, confidence: confidence, decibels: decibels, timestamp: now)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recentEvents.insert(entry, at: 0)
            if self.recentEvents.count > 50 {
                self.recentEvents.removeLast()
            }
            
            print("🔊 [AcousticEngine] \(type.emoji) \(type.displayName) gedetecteerd (\(Int(confidence * 100))% zekerheid, \(Int(decibels)) dB)")
            
            self.onAcousticEvent?(entry)
            if type.isEmergency {
                self.onEmergencyAlert?(entry)
            }
        }
    }
}
