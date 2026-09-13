import ARKit
import Metal
import RealityKit
import simd

nonisolated enum OcclusionGeometry {
    /// Do not let the reconstructed floor hide ink that sits just above that floor.
    static func filteredIndices(vertices: [SIMD3<Float>], triangles: [UInt32],
                                floorFaces: [Bool], meshToFloor: simd_float4x4?) -> [UInt32] {
        var result: [UInt32] = []
        for face in 0..<(triangles.count / 3) {
            let indices = Array(triangles[(face * 3)..<(face * 3 + 3)])
            guard indices.allSatisfy({ Int($0) < vertices.count }) else { continue }
            if face < floorFaces.count, floorFaces[face] { continue }
            if let meshToFloor {
                let onFloor = indices.allSatisfy { index in
                    let vertex = vertices[Int(index)]
                    let local = meshToFloor * SIMD4(vertex.x, vertex.y, vertex.z, 1)
                    return abs(local.y) <= 0.025
                }
                if onFloor { continue }
            }
            result += indices
        }
        return result
    }
}

/// Scene reconstruction is useful for furniture, but its noisy floor can cover
/// thin ink. Render only non-floor faces as depth-only occluders. ARKit handles
/// moving people separately with personSegmentationWithDepth.
@MainActor
final class SceneOcclusion {
    private weak var view: ARView?
    private var root: AnchorEntity?
    private var entities: [UUID: ModelEntity] = [:]
    private var anchors: [UUID: ARMeshAnchor] = [:]
    private var pending: Set<UUID> = []
    private var pendingOrder: [UUID] = []
    private var lastUpdate: TimeInterval = -.infinity

    func connect(_ view: ARView) {
        self.view = view
        reset()
    }

    func reset() {
        root?.removeFromParent()
        let root = AnchorEntity(world: .zero)
        view?.scene.addAnchor(root)
        self.root = root
        entities.removeAll()
        anchors.removeAll()
        pending.removeAll()
        pendingOrder.removeAll()
        lastUpdate = -.infinity
    }

    func enqueue(_ updates: [ARAnchor]) {
        for case let anchor as ARMeshAnchor in updates {
            anchors[anchor.identifier] = anchor
            if pending.insert(anchor.identifier).inserted {
                pendingOrder.append(anchor.identifier)
            }
        }
    }

    func remove(_ removed: [ARAnchor]) {
        for anchor in removed {
            entities.removeValue(forKey: anchor.identifier)?.removeFromParent()
            anchors.removeValue(forKey: anchor.identifier)
            pending.remove(anchor.identifier)
            pendingOrder.removeAll { $0 == anchor.identifier }
        }
    }

    func floorChanged() {
        // Re-filter against the newly selected plane before enabling old geometry.
        for entity in entities.values { entity.isEnabled = false }
        pending = Set(anchors.keys)
        pendingOrder = Array(pending)
    }

    func update(at timestamp: TimeInterval, floorTransform: simd_float4x4?) {
        guard timestamp - lastUpdate >= 0.2 else { return }
        lastUpdate = timestamp
        // Bound main-thread work. Updated mesh anchors replace older pending ones.
        let batch = Array(pendingOrder.prefix(2))
        pendingOrder.removeFirst(batch.count)
        for id in batch {
            pending.remove(id)
            guard let anchor = anchors[id] else { continue }
            do {
                try rebuild(anchor, floorTransform: floorTransform)
            } catch {
                // A failed mesh must not leave stale geometry hiding the ink.
                entities.removeValue(forKey: id)?.removeFromParent()
            }
        }
    }

    private func rebuild(_ anchor: ARMeshAnchor, floorTransform: simd_float4x4?) throws {
        let geometry = anchor.geometry
        let source = geometry.vertices
        guard source.format == .float3, geometry.faces.indexCountPerPrimitive == 3 else { return }
        let vertexBuffer = source.buffer.contents()
        var vertices: [SIMD3<Float>] = []
        for index in 0..<source.count {
            let offset = source.offset + source.stride * index
            vertices.append(SIMD3(vertexBuffer.load(fromByteOffset: offset, as: Float.self),
                                  vertexBuffer.load(fromByteOffset: offset + 4, as: Float.self),
                                  vertexBuffer.load(fromByteOffset: offset + 8, as: Float.self)))
        }
        let faces = geometry.faces
        let indexBuffer = faces.buffer.contents()
        guard faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4 else { return }
        var triangles: [UInt32] = []
        for index in 0..<(faces.count * 3) {
            let offset = index * faces.bytesPerIndex
            triangles.append(faces.bytesPerIndex == 4
                             ? indexBuffer.load(fromByteOffset: offset, as: UInt32.self)
                             : UInt32(indexBuffer.load(fromByteOffset: offset, as: UInt16.self)))
        }
        var floorFaces = [Bool](repeating: false, count: faces.count)
        if let classifications = geometry.classification, classifications.format == .uchar {
            let buffer = classifications.buffer.contents()
            for face in 0..<min(classifications.count, faces.count) {
                let value = buffer.load(fromByteOffset: classifications.offset + classifications.stride * face, as: UInt8.self)
                floorFaces[face] = Int(value) == ARMeshClassification.floor.rawValue
            }
        }
        let meshToFloor = floorTransform.map { simd_inverse($0) * anchor.transform }
        let filtered = OcclusionGeometry.filteredIndices(vertices: vertices, triangles: triangles,
                                                          floorFaces: floorFaces, meshToFloor: meshToFloor)
        guard !filtered.isEmpty else {
            entities.removeValue(forKey: anchor.identifier)?.removeFromParent()
            return
        }
        var descriptor = MeshDescriptor(name: "Real-world occluder")
        descriptor.positions = MeshBuffers.Positions(vertices)
        descriptor.primitives = .triangles(filtered)
        let mesh = try MeshResource.generate(from: [descriptor])
        let entity = entities[anchor.identifier] ?? ModelEntity()
        entity.model = ModelComponent(mesh: mesh, materials: [OcclusionMaterial()])
        entity.transform = Transform(matrix: anchor.transform)
        entity.isEnabled = true
        if entities[anchor.identifier] == nil {
            root?.addChild(entity)
            entities[anchor.identifier] = entity
        }
    }
}
