import RealityKit
import ARKit
import UIKit

@MainActor
final class InkRenderer {
    private var anchor: AnchorEntity?
    private let ink = Entity()
    private let marker = ModelEntity(mesh: .generateSphere(radius: 0.012),
                                     materials: [UnlitMaterial(color: .yellow)])
    private(set) var segmentCount = 0
    private let maxSegments = 12_000
    private var vertices: [SIMD3<Float>] = []
    private var indices: [UInt32] = []
    private var currentBatch: ModelEntity?
    private let segmentsPerBatch = 128
    private let material = UnlitMaterial(color: UIColor(red: 1, green: 0.16, blue: 0.48, alpha: 0.72))

    func attach(to view: ARView, floor: ARPlaneAnchor) {
        remove()
        // All points are floor-local so ARKit refinements move ink with the floor.
        let anchor = AnchorEntity(anchor: floor)
        anchor.addChild(ink)
        anchor.addChild(marker)
        marker.isEnabled = false
        view.scene.addAnchor(anchor)
        self.anchor = anchor
    }

    func showContact(_ point: SIMD3<Float>?) {
        marker.isEnabled = point != nil
        if let point { marker.position = point + SIMD3(0, 0.012, 0) }
    }

    enum InkError: Error { case capacityReached }

    func append(_ segments: [StrokeSegment], width: Float) throws {
        guard segmentCount + segments.count <= maxSegments else { throw InkError.capacityReached }
        for segment in segments {
            if vertices.count == segmentsPerBatch * 4 {
                try updateBatch()
                vertices.removeAll(keepingCapacity: true)
                indices.removeAll(keepingCapacity: true)
                currentBatch = nil
            }
            let delta = segment.end - segment.start
            let side = simd_normalize(SIMD3(delta.z, 0, -delta.x)) * width / 2
            let offset = SIMD3<Float>(0, 0.003, 0)
            let base = UInt32(vertices.count)
            vertices += [segment.start - side + offset, segment.start + side + offset,
                         segment.end - side + offset, segment.end + side + offset]
            indices += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
            segmentCount += 1
        }
        if !segments.isEmpty { try updateBatch() }
    }

    private func updateBatch() throws {
        var descriptor = MeshDescriptor(name: "Ink strip")
        descriptor.positions = MeshBuffers.Positions(vertices)
        descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0, 1, 0), count: vertices.count))
        descriptor.primitives = .triangles(indices)
        let mesh = try MeshResource.generate(from: [descriptor])
        if let currentBatch {
            currentBatch.model = ModelComponent(mesh: mesh, materials: [material])
        } else {
            let entity = ModelEntity(mesh: mesh, materials: [material])
            ink.addChild(entity)
            currentBatch = entity
        }
    }

    func clear() {
        ink.children.removeAll()
        segmentCount = 0
        vertices.removeAll()
        indices.removeAll()
        currentBatch = nil
    }

    func remove() {
        clear()
        ink.removeFromParent()
        marker.removeFromParent()
        anchor?.removeFromParent()
        anchor = nil
    }
}
