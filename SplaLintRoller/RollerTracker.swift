import ARKit
import Vision

nonisolated struct RollerObservation: Sendable {
    let box: CGRect
    let confidence: Float
}

/// Vision and recovery state belong exclusively to this actor. The UI allows
/// only one frame in flight, and matching runs only during recovery (at most 4 Hz).
actor RollerTracker {
    private var sequence = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private var template: TemplateRecovery?
    private var lastBox = CGRect.zero
    private var confirmation = RecoveryConfirmation()
    private var recoveryGeneration: Int?

    /// Returns whether the initial image has enough contrast for rediscovery.
    func seed(frame: ARFrame, box: CGRect) throws -> Bool {
        let image = try luminance(frame.capturedImage)
        lastBox = TrackingGeometry.flipY(box)
        template = TemplateRecovery(image: image, objectBox: lastBox)
        confirmation.reset()
        recoveryGeneration = nil
        try startSequence(frame: frame, box: box)
        return template != nil
    }

    private func startSequence(frame: ARFrame, box: CGRect) throws {
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
        request.inputObservation = result
        return RollerObservation(box: result.boundingBox, confidence: result.confidence)
    }

    /// Called only after the UI validates confidence, floor projection, and movement.
    func accept(_ observation: RollerObservation) {
        lastBox = TrackingGeometry.flipY(observation.box)
    }

    func recover(frame: ARFrame, visibleRect: CGRect, generation: Int) throws -> RollerObservation? {
        if recoveryGeneration != generation {
            recoveryGeneration = generation
            confirmation.reset()
        }
        guard let template else { return nil }
        let match = template.find(in: try luminance(frame.capturedImage), near: lastBox, visibleRect: visibleRect)
        guard confirmation.observe(match, at: frame.timestamp), let match else { return nil }
        let box = TrackingGeometry.flipY(match.box)
        try startSequence(frame: frame, box: box)
        confirmation.reset()
        return RollerObservation(box: box, confidence: match.score)
    }

    private func luminance(_ buffer: CVPixelBuffer) throws -> GrayImage {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { throw TrackingError.unsupportedImage }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { throw TrackingError.unsupportedImage }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = min(192, sourceWidth)
        let height = max(1, sourceHeight * width / sourceWidth)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, (2 * y + 1) * sourceHeight / (2 * height))
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, (2 * x + 1) * sourceWidth / (2 * width))
                pixels[y * width + x] = Float(bytes[sourceY * stride + sourceX]) / 255
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    enum TrackingError: Error { case noObservation, unsupportedImage }
}
