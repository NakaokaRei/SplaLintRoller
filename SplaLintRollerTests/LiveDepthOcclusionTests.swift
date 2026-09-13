import CoreGraphics
import RealityKit
import simd
import Testing
@testable import SplaLintRoller

struct LiveDepthOcclusionTests {
    private let intrinsics = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(500, 500, 1)))

    /// Camera one metre above the selected floor, looking straight down.
    private var cameraToFloor: simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0),
                                SIMD4(0, 1, 0, 0), SIMD4(0, 1, 0, 1)))
    }

    private func mesh(depths: [Float], width: Int = 4, height: Int = 4,
                      confidence: [UInt8]? = nil) -> DepthOcclusionMesh {
        let grid = DepthGrid(width: width, height: height, depths: depths,
                             confidence: confidence ?? Array(repeating: 2, count: depths.count))
        return DepthOcclusionGeometry.makeMesh(grid: grid, imageSize: CGSize(width: 1000, height: 1000),
                                               intrinsics: intrinsics, cameraToFloor: cameraToFloor, step: 1)
    }

    @Test func measuredFloorDoesNotCoverTheInk() {
        #expect(mesh(depths: Array(repeating: 1, count: 16)).indices.isEmpty)
        #expect(mesh(depths: Array(repeating: 0.99, count: 16)).indices.isEmpty)
        #expect(mesh(depths: Array(repeating: 1.05, count: 16)).indices.isEmpty)
    }

    @Test func fourCentimetreRollerSurfaceCreatesOcclusion() {
        let result = mesh(depths: Array(repeating: 0.96, count: 16))
        #expect(result.positions.count == 16)
        #expect(result.indices.count == 54)
        #expect(result.positions.allSatisfy { abs($0.z + 0.96) < 0.00001 })
        #expect(result.indices.allSatisfy { Int($0) < result.positions.count })
    }

    @Test func depthUsesFullResolutionCameraIntrinsicsAndAxialDistance() throws {
        let point = try #require(mesh(depths: Array(repeating: 0.96, count: 16)).positions.first)
        #expect(simd_distance(point, SIMD3(-0.36, 0.36, -0.96)) < 0.00001)
        let floorPoint = cameraToFloor * SIMD4(point.x, point.y, point.z, 1)
        #expect(abs(floorPoint.y - 0.04) < 0.00001)
    }

    @Test func trianglesFaceTheCamera() throws {
        let result = mesh(depths: Array(repeating: 0.96, count: 16))
        let a = result.positions[Int(result.indices[0])]
        let b = result.positions[Int(result.indices[1])]
        let c = result.positions[Int(result.indices[2])]
        #expect(simd_cross(b - a, c - a).z > 0)
    }

    @Test func uncertainDepthDoesNotProduceAnOccluder() {
        #expect(mesh(depths: Array(repeating: 0.96, count: 16),
                     confidence: Array(repeating: 0, count: 16)).indices.isEmpty)
        var confidence: [UInt8] = Array(repeating: 2, count: 16)
        confidence[5] = 0
        let result = mesh(depths: Array(repeating: 0.96, count: 16), confidence: confidence)
        #expect(result.positions.count == 15)
        #expect(result.indices.count == 30)
    }

    @Test func depthDiscontinuityDoesNotBridgeSeparateSurfaces() {
        #expect(mesh(depths: [0.7, 0.9, 0.7, 0.9], width: 2, height: 2).indices.isEmpty)
    }

    @Test func invalidDepthAndMismatchedBuffersAreIgnored() {
        #expect(mesh(depths: [.nan, -1, 0, 4], width: 2, height: 2).positions.isEmpty)
        #expect(mesh(depths: [0.96], width: 4, height: 4).indices.isEmpty)
        #expect(mesh(depths: Array(repeating: 0.96, count: 16), confidence: []).indices.isEmpty)
    }

    @Test func oldDepthCannotLeaveAGhostOverTheFloor() {
        #expect(DepthOcclusionGeometry.isFresh(sampleTime: 1, now: 1.1))
        #expect(!DepthOcclusionGeometry.isFresh(sampleTime: 1, now: 1.2))
        #expect(!DepthOcclusionGeometry.isFresh(sampleTime: 2, now: 1))
        #expect(!DepthOcclusionGeometry.isFresh(sampleTime: -.infinity, now: 1))
    }

    @MainActor
    @Test func liveDepthMeshIsAcceptedByRealityKit() throws {
        let result = mesh(depths: Array(repeating: 0.96, count: 16))
        var descriptor = MeshDescriptor(name: "Moving roller occlusion test")
        descriptor.positions = MeshBuffers.Positions(result.positions)
        descriptor.primitives = .triangles(result.indices)
        let resource = try MeshResource.generate(from: [descriptor])
        let entity = ModelEntity(mesh: resource, materials: [OcclusionMaterial()])
        #expect(entity.model != nil)
    }
}
