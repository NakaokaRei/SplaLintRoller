import ARKit
import AVFoundation
import Combine
import CoreImage
import RealityKit
import SwiftUI

@MainActor
final class RollerSession: NSObject, ObservableObject {
    static var deviceSupported: Bool {
        ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    enum Phase: Equatable {
        case preparing, unavailable, scanning, readyToSelect, selecting, initializing, tracking, lost
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var message = "カメラを準備しています"
    @Published private(set) var isPainting = false
    @Published private(set) var canPaint = false
    @Published private(set) var trackingUncertain = false
    @Published private(set) var cameraNormal = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var frozenImage: UIImage?
    @Published private(set) var trackingBox: CGRect?
    @Published private(set) var hasInk = false
    @Published var widthCentimeters: Double = 16 {
        didSet { stroke.breakStroke() }
    }

    private weak var view: ARView?
    private var floor: ARPlaneAnchor?
    private var frozenFrame: ARFrame?
    private var frozenTransform = CGAffineTransform.identity
    private var tracker = RollerTracker()
    private let renderer = InkRenderer()
    private let occlusion = SceneOcclusion()
    private let liveDepthOcclusion = LiveDepthOcclusion()
    private let imageContext = CIContext()
    private var stroke = StrokeBuilder()
    private var movement = StrokeBuilder()
    private var inFlight = false
    private var generation = 0
    private var paintingGeneration = 0
    private var active = true
    private var preparing = false
    private var configured = false
    private var recovering = false
    private var recoveryTask: Task<Void, Never>?
    private var tolerance = TrackingTolerance()

    var canSelect: Bool {
        floor != nil && cameraNormal && !recovering && phase != .initializing && phase != .selecting
    }

    func connect(_ view: ARView) {
        self.view = view
        view.session.delegateQueue = .main
        view.session.delegate = self
        view.automaticallyConfigureSession = false
        view.renderOptions.remove(.disablePersonOcclusion)
        // The custom mesh excludes the selected floor, unlike the built-in option.
        view.environment.sceneUnderstanding.options.remove(.occlusion)
        occlusion.connect(view)
        liveDepthOcclusion.connect(view)
    }

    func activate() async {
        active = true
        guard !preparing else { return }
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            phase = .unavailable
            message = "このアプリにはLiDAR搭載のiPhone実機が必要です。シミュレーターではAR追跡を利用できません。"
            return
        }
        preparing = true
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        preparing = false
        guard allowed else {
            cameraDenied = true
            phase = .unavailable
            message = "床とローラーを映すため、設定でカメラへのアクセスを許可してください。映像は保存・送信しません。"
            return
        }
        cameraDenied = false
        guard active else { return }
        if !configured {
            configured = true
            run(reset: true)
        } else {
            resume()
        }
    }

    func deactivate() {
        active = false
        recoveryTask?.cancel()
        invalidateTracking()
        cameraNormal = false
        liveDepthOcclusion.suspend()
        view?.session.pause()
        if configured {
            phase = floor == nil ? .scanning : .readyToSelect
            message = "再開後にローラーを再指定してください"
        }
    }

    private func configuration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.frameSemantics.insert(.sceneDepth)
        let withPeople: ARConfiguration.FrameSemantics = [.sceneDepth, .personSegmentationWithDepth]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(withPeople) {
            configuration.frameSemantics = withPeople
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        return configuration
    }

    private func run(reset: Bool) {
        guard active else { return }
        view?.session.run(configuration(), options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        if reset {
            recoveryTask?.cancel()
            recovering = false
            invalidateTracking()
            floor = nil
            renderer.remove()
            occlusion.reset()
            liveDepthOcclusion.reset()
            hasInk = false
            cameraNormal = false
            phase = .scanning
            message = "iPhoneをゆっくり動かして床を映し、掃除する床をタップしてください"
        }
    }

    private func resume() {
        invalidateTracking()
        phase = floor == nil ? .scanning : .readyToSelect
        recovering = floor != nil
        message = recovering ? "床の位置を復元しています。元の床にカメラを向けてください" : "床を映してタップしてください"
        run(reset: false)
        recoveryTask?.cancel()
        guard recovering else { return }
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.active, self.recovering else { return }
            self.run(reset: true)
            self.message = "床の位置を復元できなかったため塗り跡をリセットしました。床を選び直してください"
        }
    }

    func selectFloor(at point: CGPoint) {
        guard phase == .scanning, cameraNormal, let view else { return }
        guard let result = view.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first,
              let plane = result.anchor as? ARPlaneAnchor,
              plane.classification != .table, plane.classification != .seat,
              let frame = view.session.currentFrame,
              frame.camera.transform.columns.3.y - result.worldTransform.columns.3.y > 0.15 else {
            message = "床を認識できませんでした。床全体が映るように動かし、もう一度タップしてください"
            return
        }
        floor = plane
        occlusion.floorChanged()
        liveDepthOcclusion.suspend()
        renderer.attach(to: view, floor: plane)
        phase = .readyToSelect
        message = "床を選択しました。ローラーを床に置き、「ローラーを指定」を押してください"
    }

    func beginSelection() {
        guard canSelect, let view, let frame = view.session.currentFrame,
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        invalidateTracking()
        let transform = frame.displayTransform(for: .portrait, viewportSize: view.bounds.size)
        let raw = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = imageContext.createCGImage(raw, from: raw.extent) else {
            message = "画像を取得できませんでした。もう一度指定してください"
            return
        }
        // Match the AR viewport with the same transform used for selection and tracking.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            context.cgContext.scaleBy(x: view.bounds.width, y: view.bounds.height)
            context.cgContext.concatenate(transform)
            UIImage(cgImage: cgImage).draw(in: TrackingGeometry.unitRect)
        }
        frozenFrame = frame
        frozenTransform = transform
        frozenImage = image
        phase = .selecting
        message = "粘着ローラー部分だけをドラッグで囲んでください。持ち手は含めず、iPhoneをなるべく動かさないでください"
    }

    func confirmSelection(_ rect: CGRect) {
        guard phase == .selecting, let frame = frozenFrame,
              rect.width >= 0.04, rect.height >= 0.025 else { return }
        let box = TrackingGeometry.visionRect(screenRect: rect, displayTransform: frozenTransform)
        guard !box.isNull, box.width > 0, box.height > 0 else { return }
        phase = .initializing
        message = "ローラーの追跡を準備しています"
        generation += 1
        let token = generation
        let worker = RollerTracker()
        tracker = worker
        Task { [weak self] in
            do {
                try await worker.seed(frame: frame, box: box)
                guard let self, self.generation == token, self.active else { return }
                self.tolerance.begin(at: self.view?.session.currentFrame?.timestamp ?? frame.timestamp)
                self.frozenFrame = nil
                self.frozenImage = nil
                self.phase = .tracking
                self.message = "追跡位置を確認しています。ローラーを床に置いてください"
            } catch {
                guard let self, self.generation == token else { return }
                self.loseTracking("ローラーを指定できませんでした。もう一度囲んでください")
            }
        }
    }

    func cancelSelection() {
        invalidateTracking()
        phase = .readyToSelect
        message = "ローラーを床に置いて指定してください"
    }

    func togglePainting() {
        if isPainting {
            pausePainting()
            message = "一時停止中。ローラーを床に置いてから再開してください"
        } else if canPaint && phase == .tracking && cameraNormal {
            paintingGeneration += 1
            stroke.breakStroke()
            isPainting = true
            message = "塗っています。ローラーを持ち上げる前に一時停止してください"
        }
    }

    private func pausePainting() {
        paintingGeneration += 1
        isPainting = false
        stroke.breakStroke()
    }

    func clearInk() {
        pausePainting()
        renderer.clear()
        hasInk = false
        message = "塗り跡を消しました"
    }

    func resetFloor() {
        run(reset: true)
    }

    private func invalidateTracking() {
        generation += 1
        pausePainting()
        canPaint = false
        movement.breakStroke()
        tolerance.reset()
        trackingUncertain = false
        trackingBox = nil
        frozenImage = nil
        frozenFrame = nil
        renderer.showContact(nil)
    }

    private func loseTracking(_ reason: String) {
        invalidateTracking()
        phase = floor == nil ? .scanning : .lost
        message = reason
    }

    private func holdTracking(_ reason: String, at time: TimeInterval) {
        guard phase == .tracking else { return }
        if tolerance.hasExpired(at: time) {
            loseTracking(reason + " ローラーを再指定してください")
            return
        }
        // Keep the same Vision request alive, but never paint uncertain samples or
        // bridge the hidden interval. The user's start/pause intent is preserved.
        if !trackingUncertain { paintingGeneration += 1 }
        trackingUncertain = true
        canPaint = false
        stroke.breakStroke()
        movement.breakStroke()
        renderer.showContact(nil)
        trackingBox = nil
        message = reason + " 少し待っています。ローラーを映し続けてください"
    }

    private func process(_ observation: RollerObservation, frame: ARFrame, viewport: CGSize,
                         paintingToken: Int) {
        let transform = frame.displayTransform(for: .portrait, viewportSize: viewport)
        let rect = TrackingGeometry.screenRect(visionRect: observation.box, displayTransform: transform)
        guard TrackingTolerance.isUsable(confidence: observation.confidence, screenRect: rect) else {
            holdTracking("ローラーの位置が不確かです。", at: frame.timestamp)
            return
        }
        trackingBox = rect
        let imagePoint = TrackingGeometry.contactImagePoint(screenRect: rect, displayTransform: transform)
        let direction = TrackingGeometry.worldRay(imagePoint: imagePoint, imageSize: frame.camera.imageResolution,
                                                  intrinsics: frame.camera.intrinsics, cameraTransform: frame.camera.transform)
        let camera = frame.camera.transform.columns.3
        let origin = SIMD3<Float>(camera.x, camera.y, camera.z)
        let query = ARRaycastQuery(origin: origin, direction: direction,
                                   allowing: .existingPlaneGeometry, alignment: .horizontal)
        guard let floor, let view,
              let hit = view.session.raycast(query).first(where: { $0.anchor?.identifier == floor.identifier }) else {
            holdTracking("ローラーの下に選択した床を確認できません。", at: frame.timestamp)
            return
        }
        let hitWorld = hit.worldTransform.columns.3
        guard simd_distance(origin, SIMD3(hitWorld.x, hitWorld.y, hitWorld.z)) <= 3 else {
            loseTracking("ローラーが遠すぎます。3m以内で再指定してください")
            return
        }
        let local = simd_inverse(floor.transform) * hitWorld
        let point = SIMD3<Float>(local.x, 0, local.z)
        if case .discontinuity = movement.append(point, at: frame.timestamp) {
            loseTracking("追跡位置が急に変わったため停止しました。ローラーを再指定してください")
            return
        }
        renderer.showContact(point)
        tolerance.accept(at: frame.timestamp)
        trackingUncertain = false
        if !canPaint {
            canPaint = true
            message = isPainting
                ? "追跡が安定しました。塗りを続けています"
                : "黄色の点がローラーの接地点に合うか確認してから、塗り始めてください"
        }
        guard isPainting, paintingToken == paintingGeneration else { return }
        switch stroke.append(point, at: frame.timestamp) {
        case .discontinuity:
            loseTracking("軌跡が途切れたため停止しました。ローラーを再指定してください")
        case .accepted(let segments):
            do {
                try renderer.append(segments, width: Float(widthCentimeters / 100))
            } catch InkRenderer.InkError.capacityReached {
                pausePainting()
                message = "今回の描画上限に達しました。塗り跡を消してから再開してください"
                return
            } catch {
                pausePainting()
                message = "塗り跡を描画できませんでした。塗り跡を消して再試行してください"
                return
            }
            hasInk = renderer.segmentCount > 0
        }
    }
}

extension RollerSession: @MainActor ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard active else { return }
        occlusion.update(at: frame.timestamp, floorTransform: floor?.transform)
        if case .normal = frame.camera.trackingState {
            liveDepthOcclusion.update(frame: frame, floorTransform: floor?.transform)
            cameraNormal = true
            if recovering {
                recovering = false
                recoveryTask?.cancel()
                message = "床の位置を復元しました。ローラーを再指定してください"
            }
        } else {
            liveDepthOcclusion.suspend()
            cameraNormal = false
            if phase == .tracking {
                holdTracking("カメラの位置追跡が不安定です。", at: frame.timestamp)
            } else if phase == .selecting || phase == .initializing {
                loseTracking("カメラの位置追跡が不安定です。床を映してローラーを再指定してください")
            }
            return
        }
        guard phase == .tracking, let view else { return }
        if tolerance.hasExpired(at: frame.timestamp) {
            loseTracking("追跡の更新が途切れたため停止しました。ローラーを再指定してください")
            return
        }
        if let lastGoodTime = tolerance.lastGoodTime,
           frame.timestamp - lastGoodTime > TrackingTolerance.maximumResultAge {
            holdTracking("追跡結果を待っています。", at: frame.timestamp)
        }
        guard !inFlight else { return }
        inFlight = true
        let token = generation
        let paintingToken = paintingGeneration
        let viewport = view.bounds.size
        let worker = tracker
        Task { [weak self] in
            defer { self?.inFlight = false }
            do {
                let observation = try await worker.track(frame: frame)
                guard let self, self.generation == token, self.active, self.phase == .tracking,
                      self.cameraNormal else { return }
                guard let current = self.view?.session.currentFrame else { return }
                guard TrackingTolerance.isFresh(sampleTime: frame.timestamp, currentTime: current.timestamp) else {
                    self.holdTracking("画像解析が遅れています。", at: current.timestamp)
                    return
                }
                self.process(observation, frame: frame, viewport: viewport, paintingToken: paintingToken)
            } catch {
                guard let self, self.generation == token else { return }
                self.holdTracking("画像の追跡が途切れています。",
                                  at: self.view?.session.currentFrame?.timestamp ?? frame.timestamp)
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        occlusion.enqueue(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        occlusion.enqueue(anchors)
        for case let plane as ARPlaneAnchor in anchors where plane.identifier == floor?.identifier {
            floor = plane
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        occlusion.remove(anchors)
        guard let floor, anchors.contains(where: { $0.identifier == floor.identifier }) else { return }
        // Plane merges can remove the selected anchor. Never attach old ink to a different floor.
        self.floor = nil
        occlusion.floorChanged()
        liveDepthOcclusion.suspend()
        renderer.remove()
        hasInk = false
        recovering = false
        loseTracking("選択した床が更新されたため塗り跡をリセットしました。床を選び直してください")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        liveDepthOcclusion.suspend()
        recoveryTask?.cancel()
        recovering = false
        invalidateTracking()
        cameraNormal = false
        phase = floor == nil ? .scanning : .readyToSelect
        message = "ARが中断されました。再開後にローラーを再指定してください"
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        if active { resume() }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        recoveryTask?.cancel()
        recovering = false
        cameraNormal = false
        invalidateTracking()
        configured = false
        floor = nil
        occlusion.reset()
        liveDepthOcclusion.reset()
        renderer.remove()
        hasInk = false
        phase = .unavailable
        message = "ARを開始できませんでした。再試行してください。\n\(error.localizedDescription)"
    }
}

struct RollerARView: UIViewRepresentable {
    let model: RollerSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        model.connect(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
        uiView.session.delegate = nil
    }
}
