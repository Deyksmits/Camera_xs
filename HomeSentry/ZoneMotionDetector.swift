import Foundation
import CoreGraphics
import CoreVideo
import UIKit

// MARK: - Intelligente Trap & Voordeur Bewegingsdetector
public class ZoneMotionDetector {
    private var backgroundGrid: [Float]?
    private var lastGrid: [UInt8]?
    private var signGrid: [Int8]?
    private var oscillationScore: [Float]?
    private var lastCols = 36
    private var lastRows = 64
    private var consecutiveMotionFrames = 0
    private let requiredConsecutiveFrames = 3
    public var isNightMode: Bool = false
    
    private var pixelDeltaThreshold: Float {
        return isNightMode ? 14.0 : 20.0
    }
    
    public init() {}
    
    public func reset() {
        backgroundGrid = nil
        lastGrid = nil
        signGrid = nil
        oscillationScore = nil
        consecutiveMotionFrames = 0
    }
    
    public func processFrame(pixelBuffer: CVPixelBuffer, polygon: [CGPoint]) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return false }
        
        let isPortrait = height >= width
        let cols = isPortrait ? 36 : 64
        let rows = isPortrait ? 64 : 36
        
        var currentGrid = [UInt8](repeating: 0, count: cols * rows)
        let stepX = width / cols
        let stepY = height / rows
        
        if CVPixelBufferIsPlanar(pixelBuffer) {
            guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return false }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
            
            for r in 0..<rows {
                let py = min(r * stepY, height - 1)
                let rowOffset = py * bytesPerRow
                for c in 0..<cols {
                    let px = min(c * stepX, width - 1)
                    currentGrid[r * cols + c] = ptr[rowOffset + px]
                }
            }
        } else {
            guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
            
            for r in 0..<rows {
                let py = min(r * stepY, height - 1)
                let rowOffset = py * bytesPerRow
                for c in 0..<cols {
                    let px = min(c * stepX, width - 1)
                    let pOffset = rowOffset + (px * 4)
                    let b = Int(ptr[pOffset])
                    let g = Int(ptr[pOffset + 1])
                    let rVal = Int(ptr[pOffset + 2])
                    currentGrid[r * cols + c] = UInt8((rVal * 77 + g * 150 + b * 29) >> 8)
                }
            }
        }
        
        if backgroundGrid == nil || lastGrid == nil || signGrid == nil || oscillationScore == nil || lastCols != cols || lastRows != rows {
            backgroundGrid = currentGrid.map { Float($0) }
            lastGrid = currentGrid
            signGrid = [Int8](repeating: 0, count: cols * rows)
            oscillationScore = [Float](repeating: 0.0, count: cols * rows)
            lastCols = cols
            lastRows = rows
            return false
        }
        
        guard let prevGrid = lastGrid, var bgGrid = backgroundGrid, var signs = signGrid, var osc = oscillationScore else { return false }
        
        var totalZoneCells = 0
        var changedCells = 0
        var sumDeltas: Float = 0.0
        var minCol = cols, maxCol = 0
        var minRow = rows, maxRow = 0
        
        let hasPolygon = polygon.count >= 3
        var polygonPath: UIBezierPath?
        if hasPolygon {
            let path = UIBezierPath()
            path.move(to: polygon[0])
            for pt in polygon.dropFirst() { path.addLine(to: pt) }
            path.close()
            polygonPath = path
        }
        
        for r in 0..<rows {
            let normY = (CGFloat(r) + 0.5) / CGFloat(rows)
            for c in 0..<cols {
                let normX = (CGFloat(c) + 0.5) / CGFloat(cols)
                let point = CGPoint(x: normX, y: normY)
                
                let inZone = polygonPath?.contains(point) ?? true
                if !inZone { continue }
                
                totalZoneCells += 1
                let idx = r * cols + c
                let cur = Float(currentGrid[idx])
                let prev = Float(prevGrid[idx])
                let bg = bgGrid[idx]
                
                let diffFromBg = abs(cur - bg)
                let diffFromPrev = cur - prev
                
                // Richting-omkering detectie (flikkerend licht of reflectie door voordeurglas)
                let currentSign: Int8 = diffFromPrev > 3.0 ? 1 : (diffFromPrev < -3.0 ? -1 : 0)
                if currentSign != 0 && signs[idx] != 0 && currentSign != signs[idx] {
                    osc[idx] = min(8.0, osc[idx] + 2.0)
                } else {
                    osc[idx] = max(0.0, osc[idx] - 0.4)
                }
                signs[idx] = currentSign
                
                let isOscillating = osc[idx] >= 2.8
                
                if isOscillating {
                    bgGrid[idx] = bg * 0.82 + cur * 0.18
                } else if diffFromBg <= pixelDeltaThreshold {
                    bgGrid[idx] = bg * 0.92 + cur * 0.08
                } else {
                    bgGrid[idx] = bg * 0.995 + cur * 0.005
                }
                
                if diffFromBg > pixelDeltaThreshold && !isOscillating {
                    changedCells += 1
                    sumDeltas += diffFromBg
                    minCol = min(minCol, c)
                    maxCol = max(maxCol, c)
                    minRow = min(minRow, r)
                    maxRow = max(maxRow, r)
                }
            }
        }
        
        backgroundGrid = bgGrid
        signGrid = signs
        oscillationScore = osc
        lastGrid = currentGrid
        
        guard totalZoneCells > 0 else { return false }
        
        // Hallway Light Switch filter (wanneer iemand het ganglicht aandoet, verandert 80% van het beeld)
        let changeRatio = Double(changedCells) / Double(totalZoneCells)
        let avgDelta = changedCells > 0 ? (sumDeltas / Float(changedCells)) : 0.0
        if changeRatio > 0.55 && avgDelta < 40.0 {
            // Globale lichtsprong in de hal -> achtergrond absorbeert dit direct
            consecutiveMotionFrames = 0
            return false
        }
        
        let spanCols = max(0, maxCol - minCol + 1)
        let spanRows = max(0, maxRow - minRow + 1)
        let spanArea = spanCols * spanRows
        let fillRatio = spanArea > 0 ? (Double(changedCells) / Double(spanArea)) : 0.0
        
        let minRequiredCells = max(16, Int(Double(totalZoneCells) * 0.03))
        let isSignificantMotion = (changedCells >= minRequiredCells) &&
                                  (spanArea >= 14) &&
                                  (spanCols >= 3 && spanRows >= 3) &&
                                  (fillRatio >= 0.18)
        
        if isSignificantMotion {
            consecutiveMotionFrames += 1
        } else {
            consecutiveMotionFrames = 0
        }
        
        return consecutiveMotionFrames >= requiredConsecutiveFrames
    }
}
