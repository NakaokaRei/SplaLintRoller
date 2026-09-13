import CoreGraphics
import Foundation

/// Tolerate brief interruptions in the same Vision sequence. This does not
/// search for or re-identify an object after tracking has been declared lost.
nonisolated struct TrackingTolerance {
    static let minimumConfidence: Float = 0.45
    static let maximumResultAge: TimeInterval = 0.5
    static let gracePeriod: TimeInterval = 0.75
    private(set) var lastGoodTime: TimeInterval?

    mutating func reset() { lastGoodTime = nil }
    mutating func begin(at time: TimeInterval) { lastGoodTime = time }

    func hasExpired(at time: TimeInterval) -> Bool {
        guard let lastGoodTime else { return false }
        return !time.isFinite || time - lastGoodTime > Self.gracePeriod
    }

    mutating func accept(at time: TimeInterval) {
        lastGoodTime = time
    }

    static func isFresh(sampleTime: TimeInterval, currentTime: TimeInterval) -> Bool {
        let age = currentTime - sampleTime
        return age.isFinite && age >= 0 && age <= maximumResultAge
    }

    static func isUsable(confidence: Float, screenRect rect: CGRect) -> Bool {
        guard confidence.isFinite, confidence >= minimumConfidence,
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0.01, rect.height > 0.01 else { return false }
        let visible = rect.intersection(TrackingGeometry.unitRect)
        guard !visible.isNull,
              visible.width * visible.height / (rect.width * rect.height) >= 0.8 else { return false }
        // The box may touch or slightly cross the screen edge, but the estimated
        // contact point must remain visible to cast a meaningful floor ray.
        return rect.midX >= 0 && rect.midX <= 1 && rect.maxY >= 0 && rect.maxY <= 1
    }
}
