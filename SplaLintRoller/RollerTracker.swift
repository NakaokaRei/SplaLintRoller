import ARKit
import Vision

nonisolated struct RollerObservation: Sendable {
    let box: CGRect
    let confidence: Float
}

/// Vision state belongs exclusively to this actor. The UI permits one frame in
/// flight and skips incoming frames while it is busy. No appearance search runs.
actor RollerTracker {
    private var sequence = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?

    func seed(frame: ARFrame, box: CGRect) throws {
        sequence = VNSequenceRequestHandler()
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
        request.trackingLevel = .accurate
        self.request = request
        try sequence.perform([request], on: frame.capturedImage, orientation: .up)
        guard let result = request.results?.first as? VNDetectedObjectObservation else { throw TrackingError.noObservation }
        request.inputObservation = result
    }

    func track(frame: ARFrame) throws -> RollerObservation {
        guard let request else { throw TrackingError.noObservation }
        try sequence.perform([request], on: frame.capturedImage, orientation: .up)
        guard let result = request.results?.first as? VNDetectedObjectObservation else { throw TrackingError.noObservation }
        // Do not feed an unreliable box back as the next requested location.
        if result.confidence >= TrackingTolerance.minimumConfidence {
            request.inputObservation = result
        }
        return RollerObservation(box: result.boundingBox, confidence: result.confidence)
    }

    enum TrackingError: Error { case noObservation }
}
