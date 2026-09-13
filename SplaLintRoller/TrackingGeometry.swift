import CoreGraphics
import Foundation
import simd

/// Vision uses raw-image, bottom-left coordinates. ARKit's display transform
/// maps raw-image, top-left coordinates into the aspect-filled camera viewport.
nonisolated enum TrackingGeometry {
    static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func flipY(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    static func screenRect(visionRect: CGRect, displayTransform: CGAffineTransform) -> CGRect {
        flipY(visionRect).applying(displayTransform)
    }

    static func visionRect(screenRect: CGRect, displayTransform: CGAffineTransform) -> CGRect {
        flipY(screenRect.applying(displayTransform.inverted())).intersection(unitRect)
    }

    static func contactImagePoint(screenRect: CGRect, displayTransform: CGAffineTransform) -> CGPoint {
        CGPoint(x: screenRect.midX, y: screenRect.maxY).applying(displayTransform.inverted())
    }

    static func worldRay(imagePoint: CGPoint, imageSize: CGSize,
                         intrinsics: simd_float3x3, cameraTransform: simd_float4x4) -> SIMD3<Float> {
        let x = (Float(imagePoint.x * imageSize.width) - intrinsics[2][0]) / intrinsics[0][0]
        let y = (Float(imagePoint.y * imageSize.height) - intrinsics[2][1]) / intrinsics[1][1]
        let world = cameraTransform * SIMD4<Float>(x, -y, -1, 0)
        return simd_normalize(SIMD3<Float>(world.x, world.y, world.z))
    }

    static func selection(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let clipped = CGRect(x: min(start.x, end.x) / size.width,
                      y: min(start.y, end.y) / size.height,
                      width: abs(end.x - start.x) / size.width,
                      height: abs(end.y - start.y) / size.height).intersection(unitRect)
        return clipped.isNull ? .zero : clipped
    }
}

nonisolated struct StrokeSegment: Equatable, Sendable {
    let start: SIMD3<Float>
    let end: SIMD3<Float>
}

/// One continuous stroke only. Call breakStroke on *every* pause or invalid sample.
nonisolated struct StrokeBuilder {
    enum Sample {
        case accepted([StrokeSegment])
        case discontinuity
    }

    private(set) var previous: SIMD3<Float>?
    private var lastPosition: SIMD3<Float>?
    private var lastTime: TimeInterval?
    let spacing: Float = 0.015

    mutating func breakStroke() {
        previous = nil
        lastPosition = nil
        lastTime = nil
    }

    mutating func append(_ point: SIMD3<Float>, at time: TimeInterval) -> Sample {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite, time.isFinite else {
            breakStroke()
            return .discontinuity
        }
        if let lastPosition, let lastTime {
            let elapsed = time - lastTime
            let distance = simd_distance(point, lastPosition)
            // Initial conservative limits for slow, handheld cleaning; tune on device.
            guard elapsed > 0, elapsed <= 0.5, distance <= 0.25,
                  distance <= Float(elapsed) * 1.5 + 0.025 else {
                breakStroke()
                return .discontinuity
            }
        }
        lastPosition = point
        lastTime = time
        guard let previous else {
            self.previous = point
            return .accepted([])
        }
        let distance = simd_distance(previous, point)
        guard distance >= spacing else { return .accepted([]) }
        let count = Int(ceil(distance / spacing))
        var segments: [StrokeSegment] = []
        for index in 0..<count {
            let start = simd_mix(previous, point, SIMD3(repeating: Float(index) / Float(count)))
            let end = simd_mix(previous, point, SIMD3(repeating: Float(index + 1) / Float(count)))
            segments.append(StrokeSegment(start: start, end: end))
        }
        self.previous = point
        return .accepted(segments)
    }
}
