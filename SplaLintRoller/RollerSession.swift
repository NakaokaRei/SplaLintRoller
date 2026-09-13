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
        case preparing, unavailable, scanning, readyToSelect, selecting, initializing, tracking, searching, lost
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var message = "カメラを準備しています"
    @Published private(set) var isPainting = false
    @Published private(set) var canPaint = false
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
    private var lastSampleTime: TimeInterval?
    private var hasRecoveryTemplate = false
    private var lastSearchTime: TimeInterval = -.infinity

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
        view?.session.pause()
        if configured {
            phase = floor == nil ? .scanning : (hasRecoveryTemplate ? .searching : .readyToSelect)
            message = "再開後にローラーをカメラに戻してください"
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
            hasRecoveryTemplate = false
            renderer.remove()
            occlusion.reset()
            hasInk = false
            cameraNormal = false
            phase = .scanning
            message = "iPhoneをゆっくり動かして床を映し、掃除する床をタップしてください"
        }
    }

    private func resume() {
        invalidateTracking()
        phase = floor == nil ? .scanning : (hasRecoveryTemplate ? .searching : .readyToSelect)
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
        renderer.attach(to: view, floor: plane)
        phase = .readyToSelect
        message = "床を選択しました。ローラーを床に置き、「ローラーを指定」を押してください"
    }

    func beginSelection() {
        guard canSelect, let view, let frame = view.session.currentFrame,
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        invalidateTracking()
        hasRecoveryTemplate = false
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
                let canRecover = try await worker.seed(frame: frame, box: box)
                guard let self, self.generation == token, self.active else { return }
                self.hasRecoveryTemplate = canRecover
                self.frozenFrame = nil
                self.frozenImage = nil
                self.phase = .tracking
                self.message = "追跡位置を確認しています。ローラーを床に置いてください"
            } catch {
                guard let self, self.generation == token else { return }
                self.loseTracking("ローラーを指定できませんでした。もう一度囲んでください", allowRecovery: false)
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
        lastSampleTime = nil
        trackingBox = nil
        frozenImage = nil
        frozenFrame = nil
        renderer.showContact(nil)
    }

    private func loseTracking(_ reason: String, allowRecovery: Bool = true) {
        invalidateTracking()
        lastSearchTime = -.infinity
        if floor != nil && hasRecoveryTemplate && allowRecovery {
            phase = .searching
            message = reason + " ローラーをカメラに戻してください。撮り直さずに探します"
        } else {
            phase = floor == nil ? .scanning : .lost
            message = reason
            if floor != nil && allowRecovery {
                message += " 見分ける特徴が少ないため、ローラーの輪郭を含めて再指定してください"
            }
        }
    }

    private func searchForRoller(frame: ARFrame) {
        guard !inFlight, !recovering, let view,
              frame.timestamp - lastSearchTime >= 0.25 else { return }
        lastSearchTime = frame.timestamp
        inFlight = true
        let token = generation
        let worker = tracker
        let viewport = view.bounds.size
        let transform = frame.displayTransform(for: .portrait, viewportSize: viewport)
        let visible = TrackingGeometry.unitRect.applying(transform.inverted()).intersection(TrackingGeometry.unitRect)
        Task { [weak self] in
            defer { self?.inFlight = false }
            do {
                let observation = try await worker.recover(frame: frame, visibleRect: visible, generation: token)
                guard let self, self.generation == token, self.active, self.cameraNormal,
                      self.phase == .searching, !self.recovering,
                      let observation, let current = self.view?.session.currentFrame,
                      current.timestamp - frame.timestamp <= 0.5 else { return }
                // Floor projection still has to pass. Never resume painting automatically
                // and never connect the stroke from before the loss.
                self.movement.breakStroke()
                self.stroke.breakStroke()
                self.phase = .tracking
                self.process(observation, frame: frame, viewport: viewport,
                             paintingToken: self.paintingGeneration)
                if self.phase == .tracking, self.canPaint {
                    self.message = "ローラーが見つかりました。黄色の点を確認して「塗り始める」で再開できます"
                    await worker.accept(observation)
                }
            } catch {
                guard let self, self.generation == token, self.phase == .searching else { return }
                self.message = "ローラーを探しています。明るい床に置いてカメラに戻してください"
            }
        }
    }

    private func process(_ observation: RollerObservation, frame: ARFrame, viewport: CGSize,
                         paintingToken: Int) {
        let transform = frame.displayTransform(for: .portrait, viewportSize: viewport)
        let rect = TrackingGeometry.screenRect(visionRect: observation.box, displayTransform: transform)
        guard observation.confidence >= 0.6, !rect.isNull,
              rect.width > 0.01, rect.height > 0.01,
              rect.minX > 0.005, rect.maxX < 0.995,
              rect.minY > 0.005, rect.maxY < 0.995 else {
            loseTracking("ローラーを見失いました。床に置いてください")
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
            loseTracking("ローラーの下に選択した床を確認できません。床に置いてください")
            return
        }
        let hitWorld = hit.worldTransform.columns.3
        guard simd_distance(origin, SIMD3(hitWorld.x, hitWorld.y, hitWorld.z)) <= 3 else {
            loseTracking("ローラーが遠すぎます。3m以内に戻してください")
            return
        }
        let local = simd_inverse(floor.transform) * hitWorld
        let point = SIMD3<Float>(local.x, 0, local.z)
        if case .discontinuity = movement.append(point, at: frame.timestamp) {
            loseTracking("追跡位置が急に変わったため停止しました。ローラーをカメラに戻してください")
            return
        }
        renderer.showContact(point)
        lastSampleTime = frame.timestamp
        if !canPaint {
            canPaint = true
            message = "黄色の点がローラーの接地点に合うか確認してから、塗り始めてください"
        }
        guard isPainting, paintingToken == paintingGeneration else { return }
        switch stroke.append(point, at: frame.timestamp) {
        case .discontinuity:
            loseTracking("軌跡が途切れたため停止しました。ローラーをカメラに戻してください")
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
            cameraNormal = true
            if recovering {
                recovering = false
                recoveryTask?.cancel()
                message = "床の位置を復元しました。ローラーをカメラに戻してください"
            }
        } else {
            cameraNormal = false
            if phase == .tracking || phase == .selecting || phase == .initializing {
                loseTracking("カメラの位置追跡が不安定です。床をゆっくり映してください")
            }
            return
        }
        if phase == .searching {
            searchForRoller(frame: frame)
            return
        }
        guard phase == .tracking, let view else { return }
        if let lastSampleTime, frame.timestamp - lastSampleTime > 0.5 {
            loseTracking("追跡の更新が途切れたため停止しました。ローラーをカメラに戻してください")
            return
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
                guard let current = self.view?.session.currentFrame,
                      current.timestamp - frame.timestamp <= 0.35 else {
                    self.loseTracking("画像解析が遅れているため停止しました。ローラーをカメラに戻してください")
                    return
                }
                self.process(observation, frame: frame, viewport: viewport, paintingToken: paintingToken)
                if self.generation == token, self.phase == .tracking {
                    await worker.accept(observation)
                }
            } catch {
                guard let self, self.generation == token else { return }
                self.loseTracking("画像の追跡に失敗しました。ローラーをカメラに戻してください")
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
        renderer.remove()
        hasInk = false
        recovering = false
        loseTracking("選択した床が更新されたため塗り跡をリセットしました。床を選び直してください")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        recoveryTask?.cancel()
        recovering = false
        invalidateTracking()
        cameraNormal = false
        phase = floor == nil ? .scanning : (hasRecoveryTemplate ? .searching : .readyToSelect)
        message = "ARが中断されました。再開後にローラーをカメラに戻してください"
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
        hasRecoveryTemplate = false
        occlusion.reset()
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
