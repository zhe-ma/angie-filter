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
            .disabled(model.status.facing == .front)
            .opacity(model.status.facing == .front || model.status.flashMode == .off ? 0.45 : 1)
            Spacer()
            Button(model.aspectRatio.rawValue, action: model.cycleAspect)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
            Spacer()
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
                }
                if let point = model.focusPoint {
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(point)
                }
                zoomRow
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12 + geometry.size.height - model.photoRect(in: geometry.size).maxY)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(pinch)
                    .onTapGesture { location in
                        let photo = model.photoRect(in: geometry.size)
                        if model.filtersOpen || model.frameOpen {
                            model.dismissPanels()
                        }
                        guard photo.contains(location) else { return }
                        let local = CGPoint(x: location.x - photo.minX, y: location.y - photo.minY)
                        model.focus(viewPoint: local, in: photo.size, displayPoint: location)
                    }
            }
        }
        .aspectRatio(model.previewWidthOverHeight, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            ForEach(model.status.zoomStops) { stop in
                let selected = abs(model.status.zoomFactor - stop.factor) < 0.08
                Button(stop.title) {
                    model.zoom(to: stop)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(minWidth: 36, minHeight: 28)
                .background(selected ? Color.white : Color.black.opacity(0.35), in: Capsule())
            }
        }
    }

    private var framePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                frameStyleButton("关闭", style: .off)
                frameStyleButton("白边", style: .white)
                frameStyleButton("白边带字", style: .captioned)
            }
            if model.frame.style == .captioned {
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
            if model.selectedLook.adjustsSpatially {
                adjustmentRow("清晰度", value: model.draft.clarity, span: 1) { value in
                    model.updateDraft { $0.clarity = value }
                }
                adjustmentRow("颗粒", value: model.draft.grain, span: 1) { value in
                    model.updateDraft { $0.grain = value }
                }
                adjustmentRow("暗角", value: model.draft.vignette, span: 1.5) { value in
                    model.updateDraft { $0.vignette = value }
                }
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
