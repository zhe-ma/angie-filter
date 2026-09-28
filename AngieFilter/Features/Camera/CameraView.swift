import SwiftUI

struct CameraView: View {
    @StateObject private var model = CameraViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.status.authorization == .denied {
                permissionView
            } else if let image = model.reviewImage {
                ReviewView(image: image, isSaving: model.isSaving, onRetake: model.retake, onSave: model.save)
            } else {
                cameraBody
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
    }

    private var cameraBody: some View {
        VStack(spacing: 0) {
            topBar
            preview
            if model.dualOn {
                dualBar
            }
            if model.frameOpen {
                framePanel
            }
            if model.filtersOpen {
                filterPanel
            }
            shutterBar
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: model.cycleFlash) {
                Image(systemName: flashSymbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            .disabled(!model.flashAvailable)
            .opacity(model.flashAvailable && model.status.flashMode != .off ? 1 : 0.45)
            Spacer()
            Menu {
                Picker("画幅", selection: Binding(
                    get: { model.aspectRatio },
                    set: { model.setAspect($0) }
                )) {
                    ForEach(AspectRatio.allCases) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }
            } label: {
                Text(model.aspectRatio.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
            }
            Spacer()
            if model.dualAvailable {
                Button("双摄", action: model.toggleDual)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.dualOn ? Color.black : Color.white)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(model.dualOn ? Color.white : Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
            }
            Button(action: model.flipCamera) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                PreviewContainer(view: model.session.previewView)
                if !model.status.hasCamera {
                    Text("这台设备没有可用的相机")
                        .foregroundStyle(.white)
                }
                if model.showZoomReadout {
                    Text(zoomText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                        .padding(.top, 16 + model.photoRect(in: geometry.size).minY)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
                if let point = model.focusPoint {
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(point)
                        .allowsHitTesting(false)
                }
                dualRing(in: geometry.size)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(previewDrag(in: geometry.size))
                    .simultaneousGesture(pinch)
                zoomRow
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4 + geometry.size.height - model.photoRect(in: geometry.size).maxY)
            }
        }
        .aspectRatio(model.previewWidthOverHeight, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
    }

    /// Each stop takes a 44pt target and the row swallows taps between them,
    /// so a slightly missed stop does not fall through to tap-to-focus.
    private var zoomRow: some View {
        HStack(spacing: 0) {
            ForEach(model.status.zoomStops) { stop in
                let selected = abs(model.status.zoomFactor - stop.factor) < 0.08
                Button {
                    model.zoom(to: stop)
                } label: {
                    Text(stop.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .frame(minWidth: 36, minHeight: 28)
                        .background(selected ? Color.white : Color.black.opacity(0.35), in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Capsule())
        .onTapGesture {}
    }

    private var framePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    frameStyleButton("关闭", style: .off)
                    frameStyleButton("留白", style: .white)
                    frameStyleButton("暗房", style: .black)
                    frameStyleButton("相纸", style: .paper)
                    frameStyleButton("窗线", style: .window)
                    frameStyleButton("角标", style: .stamp)
                    frameStyleButton("压底", style: .scrim)
                    frameStyleButton("拍立得", style: .instant)
                    frameStyleButton("印记", style: .captioned)
                }
            }
            if model.frame.allowsCaption {
                HStack(spacing: 16) {
                    frameToggle("型号", on: model.frame.showsModel) { model.setShowsModel($0) }
                    frameToggle("地点", on: model.frame.showsPlace) { model.setShowsPlace($0) }
                    frameToggle("日期", on: model.frame.showsDate) { model.setShowsDate($0) }
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.84))
                if model.placeMissing {
                    Text("未获得位置")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                TextField("一行短句", text: Binding(
                    get: { model.frame.customText },
                    set: { model.setCustomText($0) }
                ))
                .submitLabel(.done)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func frameStyleButton(_ title: String, style: FrameStyle) -> some View {
        let selected = model.frame.style == style
        return Button(title) {
            model.selectFrameStyle(style)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.black : Color.white)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
    }

    private func frameToggle(_ title: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button {
            set(!on)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                Text(title)
            }
        }
        .buttonStyle(.plain)
    }

    private var filterPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text(model.selectedLook.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.86))
                if model.dualOn {
                    dualCameraSwitch
                }
                if let notice = model.adjustmentNotice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if !model.selectedLook.isOriginal {
                    Button(model.adjustOpen ? "收起" : "调节", action: model.toggleAdjust)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.white, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            if model.adjustOpen, !model.selectedLook.isOriginal {
                adjustmentControls
            }
            familyRow
            FilterStripView(
                looks: model.visibleLooks,
                familyID: model.familyID,
                selectedID: model.lookID,
                thumbnails: model.thumbnails,
                onSelect: model.select
            )
            .frame(height: 84)
        }
        .padding(.bottom, 4)
    }

    private var adjustmentControls: some View {
        VStack(spacing: 6) {
            adjustmentRow("强度", value: model.draft.intensity, span: 1) { value in
                model.updateDraft { $0.intensity = value }
            }
            adjustmentRow("褪色", value: model.draft.fade, span: 1) { value in
                model.updateDraft { $0.fade = value }
            }
            if model.selectedLook.showsHalation {
                adjustmentRow("光晕", value: model.draft.halation, span: 1) { value in
                    model.updateDraft { $0.halation = value }
                }
            }
            adjustmentRow("颗粒", value: model.draft.grain, span: 1) { value in
                model.updateDraft { $0.grain = value }
            }
            adjustmentRow("暗角", value: model.draft.vignette, span: 1.5) { value in
                model.updateDraft { $0.vignette = value }
            }
            HStack(spacing: 12) {
                Button("恢复默认", action: model.resetDraft)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button("保存", action: model.saveAdjustment)
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Color.white, in: Capsule())
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 16)
    }

    private func adjustmentRow(
        _ title: String,
        value: Float,
        span: Float,
        set: @escaping (Float) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 42, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value / span) },
                    set: { set(Float($0) * span) }
                ),
                in: 0...1
            )
            Text("\(Int((value / span * 100).rounded()))")
                .frame(width: 28, alignment: .trailing)
                .monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.7))
    }

    private var familyRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LookLibrary.families) { family in
                        let active = family.id == model.familyID
                        Button(family.name) {
                            model.selectFamily(family.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.black : Color.white.opacity(0.75))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(active ? Color.white : Color.white.opacity(0.1), in: Capsule())
                        .id(family.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear {
                proxy.scrollTo(model.familyID, anchor: .center)
            }
            .onChange(of: model.familyID) { _, id in
                withAnimation {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var shutterBar: some View {
        HStack {
            HStack(spacing: 8) {
                Button(action: model.toggleFrame) {
                    Text("相框")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(frameButtonOn ? Color.black : Color.white)
                        .frame(minWidth: 64, minHeight: 36)
                        .background(frameButtonOn ? Color.white : Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                if model.dualOn {
                    Text(model.dualSelected == .back ? "后置" : "前置")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                }
                if showAppliedName {
                    Text(model.selectedLook.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: model.capture) {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                    .overlay(Circle().fill(Color.white).padding(6))
            }
            .buttonStyle(.plain)
            Button(action: model.toggleFilters) {
                Text("滤镜")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.filtersOpen || !model.selectedLook.isOriginal ? Color.black : Color.white)
                    .frame(minWidth: 64, minHeight: 36)
                    .background(
                        model.filtersOpen || !model.selectedLook.isOriginal ? Color.white : Color.white.opacity(0.18),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private var frameButtonOn: Bool {
        model.frameOpen || model.frame.drawsBorder
    }

    private var showAppliedName: Bool {
        !model.filtersOpen && !model.frameOpen && !model.selectedLook.isOriginal
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera")
                .font(.system(size: 40))
            Text("需要相机权限")
                .font(.system(size: 22, weight: .semibold))
            Text("AngieFilter 只用相机取景和拍摄。可以在设置里打开权限。")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
            Button("前往设置", action: model.openSettings)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Color.white, in: Capsule())
                .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { model.pinchChanged($0) }
            .onEnded { _ in model.pinchEnded() }
    }

    private func previewDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.previewDragChanged(start: value.startLocation, current: value.location, in: size)
            }
            .onEnded { value in
                model.previewDragEnded(start: value.startLocation, current: value.location, in: size)
            }
    }

    private var dualBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DualLayout.allCases) { layout in
                        let selected = model.dualLayout == layout
                        Button(layout.title) {
                            model.setDualLayout(layout)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
                    }
                }
            }
            dualExtra
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var dualExtra: some View {
        switch model.dualLayout {
        case .stacked, .sideBySide:
            dualTextButton("交换", action: model.swapLead)
        case .pip, .circle:
            HStack(spacing: 8) {
                dualTextButton("换角", action: model.cyclePipCorner)
                dualTextButton("交换", action: model.swapLead)
            }
        case .blend:
            HStack(spacing: 8) {
                Text("透明度")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Slider(
                    value: Binding(
                        get: { Double(model.veil) },
                        set: { model.setVeil(Float($0)) }
                    ),
                    in: 0.2...0.8
                )
                dualCameraSwitch
                dualTextButton("换层", action: model.swapLead)
            }
        }
    }

    private var dualCameraSwitch: some View {
        HStack(spacing: 6) {
            cameraChip("后置", facing: .back)
            cameraChip("前置", facing: .front)
        }
    }

    private func cameraChip(_ title: String, facing: CameraFacing) -> some View {
        let selected = model.dualSelected == facing
        return Button(title) {
            model.selectCamera(facing)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.black : Color.white)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
    }

    private func dualTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func dualRing(in viewSize: CGSize) -> some View {
        if model.dualOn {
            let photo = model.photoRect(in: viewSize)
            let geometry = DualFrameGeometry.make(canvas: photo.size, settings: model.dualGeometrySettings())
            let pane = geometry.pane(facing: model.dualSelected)
            let frame = model.dualLayout == .blend ? CGRect(origin: .zero, size: photo.size) : pane.frame
            let rect = frame.offsetBy(dx: photo.minX, dy: photo.minY)
            let circle = model.dualLayout != .blend && pane.isCircle
            Group {
                if circle {
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                } else {
                    RoundedRectangle(cornerRadius: pane.cornerRadius, style: .continuous)
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var flashSymbol: String {
        switch model.status.flashMode {
        case .off: return "bolt.slash"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic"
        }
    }

    private var zoomText: String {
        let value = (model.status.displayZoom * 10).rounded() / 10
        if value == value.rounded() {
            return "\(Int(value))×"
        }
        return String(format: "%.1f×", value)
    }
}

private struct PreviewContainer: UIViewRepresentable {
    let view: PreviewMetalView

    func makeUIView(context: Context) -> PreviewMetalView {
        view
    }

    func updateUIView(_ uiView: PreviewMetalView, context: Context) {}
}
