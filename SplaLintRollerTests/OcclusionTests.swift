import RealityKit
import simd
import Testing
@testable import SplaLintRoller

struct OcclusionTests {
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
