import CoreGraphics
import Foundation
import RealityKit
import simd
import Testing
@testable import SplaLintRoller

struct RecoveryAndOcclusionTests {
    private let original = CGRect(x: 0.15, y: 0.2, width: 0.2, height: 0.25)

    private func scene(objects: [CGRect], brightness: Float = 0) -> GrayImage {
        let width = 160, height = 120
        var pixels = [Float](repeating: 0.18 + brightness, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(width),
                                    y: (CGFloat(y) + 0.5) / CGFloat(height))
                for box in objects where box.contains(point) {
                    let u = Float((point.x - box.minX) / box.width)
                    let v = Float((point.y - box.minY) / box.height)
                    pixels[y * width + x] = 0.55 + 0.18 * sin(u * 6.28)
                        + 0.12 * cos(v * 9.42) + 0.07 * sin((u + v) * 12.56) + brightness
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    @Test func rediscoversObjectAfterLeavingItsOldPosition() throws {
        let template = try #require(TemplateRecovery(image: scene(objects: [original]), objectBox: original))
        let moved = CGRect(x: 0.6, y: 0.52, width: original.width, height: original.height)
        let match = try #require(template.find(in: scene(objects: [moved], brightness: 0.08),
                                                near: original, visibleRect: TrackingGeometry.unitRect))
        #expect(TemplateRecovery.overlap(match.box, moved) > 0.75)
        #expect(match.score >= 0.84)
    }

    @Test func rediscoversObjectAtDifferentScale() throws {
        let template = try #require(TemplateRecovery(image: scene(objects: [original]), objectBox: original))
        let moved = CGRect(x: 0.55, y: 0.42, width: original.width * 1.3, height: original.height * 1.3)
        let match = try #require(template.find(in: scene(objects: [moved]), near: original,
                                                visibleRect: TrackingGeometry.unitRect))
        #expect(TemplateRecovery.overlap(match.box, moved) > 0.7)
    }

    @Test func doesNotRecoverWhenObjectIsAbsentOrOutsideViewport() throws {
        let template = try #require(TemplateRecovery(image: scene(objects: [original]), objectBox: original))
        #expect(template.find(in: scene(objects: []), near: original,
                              visibleRect: TrackingGeometry.unitRect) == nil)
        let hidden = CGRect(x: 0.6, y: 0.52, width: original.width, height: original.height)
        #expect(template.find(in: scene(objects: [hidden]), near: original,
                              visibleRect: CGRect(x: 0, y: 0, width: 0.4, height: 1)) == nil)
    }

    @Test func rejectsTwoIndistinguishableCandidates() throws {
        let template = try #require(TemplateRecovery(image: scene(objects: [original]), objectBox: original))
        let duplicate = original.offsetBy(dx: 0.5, dy: 0.3)
        #expect(template.find(in: scene(objects: [original, duplicate]), near: original,
                              visibleRect: TrackingGeometry.unitRect) == nil)
    }

    @Test func featurelessTemplateIsNotUsedForRecovery() {
        let blank = GrayImage(width: 160, height: 120, pixels: Array(repeating: 0.9, count: 160 * 120))
        #expect(TemplateRecovery(image: blank, objectBox: original) == nil)
    }

    @Test func recoveryRequiresConsecutiveDistinctFrames() {
        let match = RecoveryMatch(box: original, score: 0.95)
        var confirmation = RecoveryConfirmation()
        let observed1 = confirmation.observe(match, at: 0)
        #expect(!observed1)
        let observed2 = confirmation.observe(match, at: 0)
        #expect(!observed2)
        let observed3 = confirmation.observe(match, at: 0.25)
        #expect(!observed3)
        let observed4 = confirmation.observe(match, at: 0.5)
        #expect(observed4)
        confirmation.reset()
        let observed5 = confirmation.observe(match, at: 1)
        #expect(!observed5)
        let observed6 = confirmation.observe(nil, at: 1.25)
        #expect(!observed6)
        let observed7 = confirmation.observe(match, at: 1.5)
        #expect(!observed7)
        #expect(confirmation.count == 1)
    }

    @Test func candidateJumpOrLongGapRestartsConfirmation() {
        var confirmation = RecoveryConfirmation()
        let match = RecoveryMatch(box: original, score: 0.95)
        _ = confirmation.observe(match, at: 0)
        _ = confirmation.observe(match, at: 0.25)
        let other = RecoveryMatch(box: original.offsetBy(dx: 0.5, dy: 0), score: 0.95)
        let observed8 = confirmation.observe(other, at: 0.5)
        #expect(!observed8)
        #expect(confirmation.count == 1)
        let observed9 = confirmation.observe(other, at: 2)
        #expect(!observed9)
        #expect(confirmation.count == 1)
    }

    @Test func floorDoesNotOccludeInkButRaisedObjectsDo() {
        let vertices: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0.01, 0), SIMD3(0, 0, 1),
                                        SIMD3(0, 0.5, 0), SIMD3(1, 0.5, 0), SIMD3(0, 0.5, 1)]
        let indices: [UInt32] = [0, 2, 1, 3, 5, 4]
        #expect(OcclusionGeometry.filteredIndices(vertices: vertices, triangles: indices,
                                                  floorFaces: [], meshToFloor: matrix_identity_float4x4) == [3, 5, 4])
        // ARKit's floor classification also suppresses a noisy floor above the tolerance.
        #expect(OcclusionGeometry.filteredIndices(vertices: vertices, triangles: indices,
                                                  floorFaces: [true, true], meshToFloor: nil).isEmpty)
    }

    @Test func floorFilteringUsesSelectedFloorCoordinates() {
        let vertices: [SIMD3<Float>] = [SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 1)]
        var meshToFloor = matrix_identity_float4x4
        meshToFloor.columns.3.y = -1
        #expect(OcclusionGeometry.filteredIndices(vertices: vertices, triangles: [0, 2, 1],
                                                  floorFaces: [], meshToFloor: meshToFloor).isEmpty)
        #expect(OcclusionGeometry.filteredIndices(vertices: vertices, triangles: [0, 2, 99],
                                                  floorFaces: [], meshToFloor: nil).isEmpty)
    }

    @MainActor
    @Test func depthOnlyMeshCanBeCreatedWithoutLightingNormals() throws {
        var descriptor = MeshDescriptor(name: "Occlusion test")
        descriptor.positions = MeshBuffers.Positions([SIMD3<Float>(0, 0.5, 0), SIMD3(1, 0.5, 0), SIMD3(0, 0.5, 1)])
        descriptor.primitives = .triangles([0, 2, 1])
        let mesh = try MeshResource.generate(from: [descriptor])
        let entity = ModelEntity(mesh: mesh, materials: [OcclusionMaterial()])
        #expect(entity.model?.materials.count == 1)
    }
}
