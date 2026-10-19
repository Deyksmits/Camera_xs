import Foundation
import Vision
import CoreMedia
import AudioToolbox
import QuartzCore

// MARK: - TrafficSignDetector Delegate
protocol TrafficSignDetectorDelegate: AnyObject {
    func trafficSignDetector(_ detector: TrafficSignDetector, didDetectSpeedLimit speedLimit: Int)
}

// MARK: - TrafficSignDetector (Vision Bordherkenning)
class TrafficSignDetector {
    weak var delegate: TrafficSignDetectorDelegate?
    
    private var lastProcessTime: TimeInterval = 0
    private let processInterval: TimeInterval = 0.5 // 2 FPS analyse op de wegcamera
    private let visionQueue = DispatchQueue(label: "com.smartdash.visionsigns", qos: .userInitiated)
    
    // Geldige Nederlandse RVV snelheidslimieten
    private let validSpeedLimits: Set<Int> = [15, 30, 50, 60, 70, 80, 90, 100, 110, 120, 130]
    
    private var currentConfirmedLimit: Int?
    private var candidateLimit: Int?
    private var candidateDetectionsCount: Int = 0
    private let requiredConfirmations: Int = 2
    
    func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastProcessTime >= processInterval else { return }
        lastProcessTime = currentTime
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        visionQueue.async { [weak self] in
            self?.performTextRecognition(on: pixelBuffer)
        }
    }
    
    private func performTextRecognition(on pixelBuffer: CVPixelBuffer) {
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self, error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            self.analyzeTextObservations(observations)
        }
        
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["nl", "en"]
        
        // Verwerk voornamelijk de bovenste en rechter helft van het beeld (waar verkeersborden boven en langs de weg staan)
        request.regionOfInterest = CGRect(x: 0.15, y: 0.20, width: 0.85, height: 0.70)
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("Vision request fout: \(error)")
        }
    }
    
    private func analyzeTextObservations(_ observations: [VNRecognizedTextObservation]) {
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Controleer of de tekst puur een getal is
            if let number = Int(text), validSpeedLimits.contains(number) {
                // Controleer bounding box aspect ratio: een rond verkeersbord heeft ongeveer een 1:1 aspect ratio
                let box = observation.boundingBox
                let aspectRatio = box.width / max(0.01, box.height)
                
                // Als het aspect ratio relatief compact is (tussen 0.5 en 2.0)
                if aspectRatio >= 0.4 && aspectRatio <= 2.2 {
                    handleDetectedSpeedLimit(number)
                    return
                }
            }
        }
    }
    
    private func handleDetectedSpeedLimit(_ limit: Int) {
        if limit == candidateLimit {
            candidateDetectionsCount += 1
        } else {
            candidateLimit = limit
            candidateDetectionsCount = 1
        }
        
        // Zodra het bord 2 opeenvolgende keren is herkend
        if candidateDetectionsCount >= requiredConfirmations && limit != currentConfirmedLimit {
            currentConfirmedLimit = limit
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Subtiel attendatiegeluid bij een nieuw bord
                AudioServicesPlaySystemSound(1052)
                self.delegate?.trafficSignDetector(self, didDetectSpeedLimit: limit)
            }
        }
    }
    
    func reset() {
        currentConfirmedLimit = nil
        candidateLimit = nil
        candidateDetectionsCount = 0
    }
}
