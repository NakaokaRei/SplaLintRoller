import SwiftUI

struct ContentView: View {
    @StateObject private var model = RollerSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: CGRect = .zero
    @State private var showClearConfirmation = false
    @State private var showResetConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if RollerSession.deviceSupported {
                    RollerARView(model: model)
                }
                if let image = model.frozenImage {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(true)
                }

                if model.phase == .scanning {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { location in model.selectFloor(at: location) }
                    Image(systemName: "viewfinder")
                        .font(.system(size: 52, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.65))
                        .allowsHitTesting(false)
                }

                if model.phase == .selecting {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                selection = TrackingGeometry.selection(from: value.startLocation,
                                                                       to: value.location, in: geometry.size)
                            })
                    selectionOutline(selection, size: geometry.size, color: .yellow)
                } else if let box = model.trackingBox {
                    selectionOutline(box, size: geometry.size, color: .mint)
                }

                if model.phase == .unavailable {
                    unavailableView
                } else {
                    VStack(spacing: 12) {
                        header
                        Spacer(minLength: 0)
                        controls
                    }
                    .padding(16)
                }
            }
            .clipped()
            .onChange(of: model.phase) { _, phase in
                if phase == .selecting { selection = .zero }
            }
        }
        .background(.black, ignoresSafeAreaEdges: .all)
        .preferredColorScheme(.dark)
        .tint(.pink)
        .task { await model.activate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.activate() }
            } else {
                model.deactivate()
            }
        }
        .confirmationDialog("今回の塗り跡をすべて消しますか？", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("塗り跡を消す", role: .destructive) { model.clearInk() }
        }
        .confirmationDialog("床を選び直すと、今回の塗り跡も消えます", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("床を選び直す", role: .destructive) { model.resetFloor() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "paintbrush.pointed.fill").foregroundStyle(.pink)
                Text("コロコロインク").font(.headline)
                Spacer()
                Text(model.isPainting ? "塗り中" : (model.phase == .searching ? "再探索中" : "AR試作"))
                    .font(.caption.bold())
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(model.isPainting ? Color.pink : Color.white.opacity(0.15), in: Capsule())
            }
            Text(model.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sessionStatus")
        }
        .padding(14)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 12) {
            if model.phase == .selecting {
                HStack {
                    Button("撮り直す") {
                        model.cancelSelection()
                        model.beginSelection()
                    }
                    .buttonStyle(.bordered)
                    Button("この範囲を追跡") { model.confirmSelection(selection) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isNull || selection.width < 0.04 || selection.height < 0.025)
                }
                Button("キャンセル") { model.cancelSelection() }.font(.subheadline)
            } else if model.phase == .initializing || model.phase == .preparing {
                ProgressView().padding()
            } else if model.phase != .scanning {
                if model.phase == .searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("撮り直し不要 · ローラーをカメラに戻してください")
                            .font(.caption)
                    }
                    .accessibilityIdentifier("rollerRecoveryStatus")
                }
                HStack {
                    Text("塗り幅").font(.subheadline)
                    Slider(value: $model.widthCentimeters, in: 5...30, step: 1)
                        .accessibilityLabel("塗り幅")
                        .disabled(model.isPainting)
                    Text("\(Int(model.widthCentimeters)) cm")
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                Button(action: model.togglePainting) {
                    Label(model.isPainting ? "一時停止" : "塗り始める",
                          systemImage: model.isPainting ? "pause.fill" : "paintbrush.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPaint && !model.isPainting)
                .accessibilityIdentifier("paintButton")

                HStack {
                    Button(model.phase == .readyToSelect ? "ローラーを指定" : "ローラーを再指定") {
                        model.beginSelection()
                    }
                    .disabled(!model.canSelect)
                    Spacer()
                    Button("塗り跡を消す", systemImage: "trash") {
                        if model.isPainting { model.togglePainting() }
                        showClearConfirmation = true
                    }
                        .labelStyle(.iconOnly)
                        .disabled(!model.hasInk)
                    Button("床を選び直す", systemImage: "arrow.counterclockwise") {
                        if model.isPainting { model.togglePainting() }
                        showResetConfirmation = true
                    }
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
                Text("持ち上げる前に一時停止 · 掃除位置は推定です")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("床をタップして選択", systemImage: "hand.tap")
                    .font(.headline)
                Text("明るい場所で、床にカメラを向けてください")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
    }

    private var unavailableView: some View {
        VStack(spacing: 20) {
            Image(systemName: model.cameraDenied ? "camera.fill" : "iphone.slash")
                .font(.system(size: 44)).foregroundStyle(.pink)
            Text("ARを利用できません").font(.title2.bold())
            Text(model.message).multilineTextAlignment(.center)
                .accessibilityIdentifier("unavailableMessage")
            if model.cameraDenied {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            } else if RollerSession.deviceSupported {
                Button("再試行") { Task { await model.activate() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }

    private func selectionOutline(_ rect: CGRect, size: CGSize, color: Color) -> some View {
        Rectangle()
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            .frame(width: max(0, rect.width * size.width), height: max(0, rect.height * size.height))
            .position(x: rect.midX * size.width, y: rect.midY * size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview {
    ContentView()
}
