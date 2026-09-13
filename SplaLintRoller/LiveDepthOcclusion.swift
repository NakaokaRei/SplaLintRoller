import ARKit
import CoreGraphics
import Foundation
import RealityKit
import simd

nonisolated struct DepthGrid: Sendable {
    let width: Int
    let height: Int
    let depths: [Float]
    let confidence: [UInt8]
}

nonisolated struct DepthOcclusionMesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []
}

/// Camera-space depth geometry for small/moving objects that scene reconstruction
/// may miss. Depth is axial camera distance, not distance along a normalized ray.
nonisolated enum DepthOcclusionGeometry {
    static let minimumHeight: Float = 0.015
    static let maximumDepthJump: Float = 0.08
    static let maximumAge: TimeInterval = 0.12

    static func isFresh(sampleTime: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - sampleTime
        return age.isFinite && age >= 0 && age <= maximumAge
    }

    static func makeMesh(grid: DepthGrid, imageSize: CGSize, intrinsics: simd_float3x3,
                         cameraToFloor: simd_float4x4, step: Int = 2) -> DepthOcclusionMesh {
        guard grid.width >= 2, grid.height >= 2, step > 0,
              grid.depths.count == grid.width * grid.height,
              grid.confidence.count == grid.depths.count,
              imageSize.width > 0, imageSize.height > 0,
              intrinsics[0][0] > 0, intrinsics[1][1] > 0 else { return DepthOcclusionMesh() }
        let xs = Array(stride(from: 0, to: grid.width, by: step))
        let ys = Array(stride(from: 0, to: grid.height, by: step))
        guard xs.count >= 2, ys.count >= 2 else { return DepthOcclusionMesh() }
        var mesh = DepthOcclusionMesh()
        var vertexMap = [Int](repeating: -1, count: xs.count * ys.count)
        var sampledDepths = [Float](repeating: 0, count: vertexMap.count)
        for (row, y) in ys.enumerated() {
            for (column, x) in xs.enumerated() {
                let sourceIndex = y * grid.width + x
                let depth = grid.depths[sourceIndex]
                guard grid.confidence[sourceIndex] >= 1, depth.isFinite,
                      depth >= 0.1, depth <= 3 else { continue }
                let pixelX = (Float(x) + 0.5) * Float(imageSize.width) / Float(grid.width)
                let pixelY = (Float(y) + 0.5) * Float(imageSize.height) / Float(grid.height)
                let point = SIMD3<Float>((pixelX - intrinsics[2][0]) / intrinsics[0][0] * depth,
                                         -(pixelY - intrinsics[2][1]) / intrinsics[1][1] * depth,
                                         -depth)
                let floorPoint = cameraToFloor * SIMD4(point.x, point.y, point.z, 1)
                guard floorPoint.y.isFinite, floorPoint.y >= minimumHeight else { continue }
                let index = row * xs.count + column
                vertexMap[index] = mesh.positions.count
                sampledDepths[index] = depth
                mesh.positions.append(point)
            }
        }
        for row in 0..<(ys.count - 1) {
            for column in 0..<(xs.count - 1) {
                let a = row * xs.count + column
                let corners = [a, a + 1, a + xs.count, a + xs.count + 1]
                guard corners.allSatisfy({ vertexMap[$0] >= 0 }) else { continue }
                let depths = corners.map { sampledDepths[$0] }
                // Do not stretch a triangle across foreground/background boundaries.
                guard let minDepth = depths.min(), let maxDepth = depths.max(),
                      maxDepth - minDepth <= maximumDepthJump else { continue }
                let vertices = corners.map { UInt32(vertexMap[$0]) }
                mesh.indices += [vertices[0], vertices[2], vertices[1], vertices[1], vertices[2], vertices[3]]
            }
        }
        return mesh
    }
}

/// Reads only the raw per-frame depth map, avoiding the trails temporal depth
/// smoothing can introduce for a moving roller. CPU processing stays off the UI actor.
actor DepthOcclusionBuilder {
    func build(frame: ARFrame, floorTransform: simd_float4x4) -> DepthOcclusionMesh? {
        guard let data = frame.sceneDepth, let confidence = data.confidenceMap else { return nil }
        let depth = data.depthMap
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8 else { return nil }
        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        guard CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(depth)
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        var depths: [Float] = []
        var confidences: [UInt8] = []
        depths.reserveCapacity(width * height)
        confidences.reserveCapacity(width * height)
        for y in 0..<height {
            let depthRow = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float.self)
            let confidenceRow = confidenceBase.advanced(by: y * confidenceStride).assumingMemoryBound(to: UInt8.self)
            depths.append(contentsOf: UnsafeBufferPointer(start: depthRow, count: width))
            confidences.append(contentsOf: UnsafeBufferPointer(start: confidenceRow, count: width))
        }
        let grid = DepthGrid(width: width, height: height, depths: depths, confidence: confidences)
        return DepthOcclusionGeometry.makeMesh(grid: grid, imageSize: frame.camera.imageResolution,
                                               intrinsics: frame.camera.intrinsics,
                                               cameraToFloor: simd_inverse(floorTransform) * frame.camera.transform,
                                               step: max(1, (width + 127) / 128))
    }
}

@MainActor
final class LiveDepthOcclusion {
    private weak var view: ARView?
    private var root: AnchorEntity?
    private let entity = ModelEntity()
    private let worker = DepthOcclusionBuilder()
    private var inFlight = false
    private var generation = 0
    private var lastSubmittedTime: TimeInterval = -.infinity
    private var displayedTime: TimeInterval = -.infinity

    func connect(_ view: ARView) {
        self.view = view
        reset()
    }

    func reset() {
        suspend()
        entity.removeFromParent()
        root?.removeFromParent()
        let root = AnchorEntity(world: .zero)
        root.addChild(entity)
        view?.scene.addAnchor(root)
        self.root = root
    }

    func suspend() {
        generation += 1
        entity.isEnabled = false
        entity.model = nil
        lastSubmittedTime = -.infinity
        displayedTime = -.infinity
    }

    func update(frame: ARFrame, floorTransform: simd_float4x4?) {
        guard let floorTransform, frame.sceneDepth != nil else { suspend(); return }
        if !DepthOcclusionGeometry.isFresh(sampleTime: displayedTime, now: frame.timestamp) {
            entity.isEnabled = false
        }
        guard !inFlight, frame.timestamp - lastSubmittedTime >= 1.0 / 20 else { return }
        lastSubmittedTime = frame.timestamp
        inFlight = true
        let token = generation
        let worker = worker
        Task { [weak self] in
            let mesh = await worker.build(frame: frame, floorTransform: floorTransform)
            guard let self else { return }
            defer { self.inFlight = false }
            guard self.generation == token,
                  let current = self.view?.session.currentFrame,
                  DepthOcclusionGeometry.isFresh(sampleTime: frame.timestamp, now: current.timestamp) else { return }
            guard let mesh, !mesh.indices.isEmpty else {
                self.entity.isEnabled = false
                self.entity.model = nil
                return
            }
            do {
                var descriptor = MeshDescriptor(name: "Live foreground depth")
                descriptor.positions = MeshBuffers.Positions(mesh.positions)
                descriptor.primitives = .triangles(mesh.indices)
                let resource = try MeshResource.generate(from: [descriptor])
                self.entity.model = ModelComponent(mesh: resource, materials: [OcclusionMaterial()])
                // The geometry and transform come from the exact same camera frame.
                self.entity.transform = Transform(matrix: frame.camera.transform)
                self.entity.isEnabled = true
                self.displayedTime = frame.timestamp
            } catch {
                self.entity.isEnabled = false
                self.entity.model = nil
            }
        }
    }
}
