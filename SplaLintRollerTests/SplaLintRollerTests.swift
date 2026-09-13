import CoreGraphics
import Foundation
import simd
import Testing
@testable import SplaLintRoller

struct SplaLintRollerTests {
    @MainActor
    @Test func inkMeshesBuildAcrossBatchesAndClear() throws {
        let renderer = InkRenderer()
        let segments = (0..<130).map { index in
            StrokeSegment(start: SIMD3(Float(index) * 0.015, 0, 0),
                          end: SIMD3(Float(index + 1) * 0.015, 0, 0))
        }
        // Exercise actual RealityKit mesh validation, including a new batch.
        try renderer.append(segments, width: 0.16)
        #expect(renderer.segmentCount == 130)
        do {
            try renderer.append(Array(repeating: segments[0], count: 12_001), width: 0.16)
            Issue.record("Capacity overflow should stop rendering before adding ink")
        } catch InkRenderer.InkError.capacityReached {
            #expect(renderer.segmentCount == 130)
        }
        renderer.clear()
        #expect(renderer.segmentCount == 0)
        try renderer.append([segments[0]], width: 0.05)
        #expect(renderer.segmentCount == 1)
    }

    @Test func visionTopLeftConversion() {
        let box = CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.1)
        let screen = TrackingGeometry.screenRect(visionRect: box, displayTransform: .identity)
        #expect(abs(screen.minY - 0.6) < 0.00001)
        let contact = TrackingGeometry.contactImagePoint(screenRect: screen, displayTransform: .identity)
        #expect(abs(contact.x - 0.3) < 0.00001)
        #expect(abs(contact.y - 0.7) < 0.00001)
    }

    @Test func portraitRotationAndAspectFillRoundTrip() {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        let crop = CGAffineTransform(a: 1.2, b: 0, c: 0, d: 1, tx: -0.1, ty: 0)
        let transform = rotation.concatenating(crop)
        let box = CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.1)
        let screen = TrackingGeometry.screenRect(visionRect: box, displayTransform: transform)
        let roundTrip = TrackingGeometry.visionRect(screenRect: screen, displayTransform: transform)
        #expect(abs(roundTrip.minX - box.minX) < 0.00001)
        #expect(abs(roundTrip.minY - box.minY) < 0.00001)
        #expect(abs(roundTrip.width - box.width) < 0.00001)
        #expect(abs(roundTrip.height - box.height) < 0.00001)
        let contact = TrackingGeometry.contactImagePoint(screenRect: screen, displayTransform: transform)
        // Screen-bottom is raw-image right when the sensor is rotated for portrait.
        #expect(abs(contact.x - 0.4) < 0.00001)
        #expect(abs(contact.y - 0.65) < 0.00001)
    }

    @Test func reversedSelectionClampsToViewport() {
        let rect = TrackingGeometry.selection(from: CGPoint(x: 120, y: 180),
                                               to: CGPoint(x: -10, y: 40),
                                               in: CGSize(width: 100, height: 200))
        #expect(rect.minX == 0)
        #expect(rect.maxX == 1)
        #expect(abs(rect.minY - 0.2) < 0.00001)
        #expect(abs(rect.maxY - 0.9) < 0.00001)
        #expect(TrackingGeometry.selection(from: .zero, to: .zero, in: .zero) == .zero)
    }

    @Test func rayUsesCameraOrientationAndIgnoresTranslation() {
        let intrinsics = simd_float3x3(columns: (SIMD3(100, 0, 0), SIMD3(0, 100, 0), SIMD3(50, 50, 1)))
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4(4, 2, 6, 1)
        let ray = TrackingGeometry.worldRay(imagePoint: CGPoint(x: 0.5, y: 0.5),
                                           imageSize: CGSize(width: 100, height: 100),
                                           intrinsics: intrinsics, cameraTransform: camera)
        #expect(simd_distance(ray, SIMD3(0, 0, -1)) < 0.00001)
        let rotation = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        let rotated = TrackingGeometry.worldRay(imagePoint: CGPoint(x: 0.5, y: 0.5),
                                               imageSize: CGSize(width: 100, height: 100),
                                               intrinsics: intrinsics, cameraTransform: rotation)
        #expect(simd_distance(rotated, SIMD3(-1, 0, 0)) < 0.00001)
    }

    @Test func strokeInterpolatesWithoutGaps() throws {
        var stroke = StrokeBuilder()
        _ = stroke.append(.zero, at: 0)
        let end = SIMD3<Float>(0.1, 0, 0)
        guard case .accepted(let segments) = stroke.append(end, at: 0.1) else {
            Issue.record("Valid slow motion should be accepted")
            return
        }
        #expect(segments.count == 7)
        #expect(segments.first?.start == .zero)
        #expect(segments.last?.end == end)
        for pair in zip(segments, segments.dropFirst()) {
            #expect(pair.0.end == pair.1.start)
            #expect(simd_distance(pair.0.start, pair.0.end) <= stroke.spacing + 0.00001)
        }
    }

    @Test func pauseDoesNotBridgeStrokes() {
        var stroke = StrokeBuilder()
        _ = stroke.append(.zero, at: 0)
        _ = stroke.append(SIMD3(0.1, 0, 0), at: 0.1)
        stroke.breakStroke()
        guard case .accepted(let segments) = stroke.append(SIMD3(2, 0, 1), at: 4) else {
            Issue.record("First sample after a pause should start a new stroke")
            return
        }
        #expect(segments.isEmpty)
    }

    @Test func jumpGapAndOutOfOrderSamplesBreakStroke() {
        for (point, time) in [(SIMD3<Float>(1, 0, 0), 0.1),
                              (SIMD3<Float>(0.01, 0, 0), 0.6),
                              (SIMD3<Float>(0.01, 0, 0), 0.0),
                              (SIMD3<Float>(0.15, 0, 0), 0.01)] {
            var stroke = StrokeBuilder()
            _ = stroke.append(.zero, at: 0)
            if case .discontinuity = stroke.append(point, at: time) {
                #expect(stroke.previous == nil)
            } else {
                Issue.record("Unsafe sample must break the stroke")
            }
        }
    }

    @Test func stationaryJitterDoesNotGenerateInk() {
        var stroke = StrokeBuilder()
        _ = stroke.append(.zero, at: 0)
        for index in 1...20 {
            guard case .accepted(let segments) = stroke.append(SIMD3(0.002, 0, 0), at: Double(index) * 0.1) else {
                Issue.record("Stationary tracking should stay valid")
                return
            }
            #expect(segments.isEmpty)
        }
    }

    @Test func invalidCoordinatesAreRejected() {
        var stroke = StrokeBuilder()
        _ = stroke.append(.zero, at: 0)
        if case .discontinuity = stroke.append(SIMD3(.nan, 0, 0), at: 0.1) {
            #expect(stroke.previous == nil)
        } else {
            Issue.record("Non-finite coordinates must never reach rendering")
        }
    }

    @Test func reversalKeepsAContinuousPath() {
        var stroke = StrokeBuilder()
        _ = stroke.append(.zero, at: 0)
        _ = stroke.append(SIMD3(0.1, 0, 0), at: 0.1)
        guard case .accepted(let segments) = stroke.append(.zero, at: 0.2) else {
            Issue.record("Slow reversal should be accepted")
            return
        }
        #expect(segments.first?.start == SIMD3(0.1, 0, 0))
        #expect(segments.last?.end == .zero)
    }
}
