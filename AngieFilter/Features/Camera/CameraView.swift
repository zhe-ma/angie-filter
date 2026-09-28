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
                        .padding(.top, 16)
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
                    .padding(.bottom, 12)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(pinch)
                    .onTapGesture { location in
                        if model.filtersOpen {
                            model.closeFilters()
                        }
                        model.focus(viewPoint: location, in: geometry.size)
                    }
            }
        }
        .aspectRatio(model.aspectRatio.widthOverHeight, contentMode: .fit)
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

    private var filterPanel: some View {
        VStack(spacing: 8) {
            Text(model.selectedLook.name)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.86))
            if model.intensityOpen, !model.selectedLook.isOriginal {
                HStack(spacing: 10) {
                    Text("强度")
                    Slider(value: Binding(
                        get: { Double(model.intensity) },
                        set: { model.setIntensity(Float($0)) }
                    ), in: 0...1)
                    Text("\(Int(model.intensity * 100))")
                        .frame(width: 32, alignment: .trailing)
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 28)
            }
            FilterStripView(
                looks: model.looks,
                selectedID: model.lookID,
                thumbnails: model.thumbnails,
                onSelect: model.select
            )
            .frame(height: 84)
        }
        .padding(.bottom, 4)
    }

    private var shutterBar: some View {
        HStack {
            Text(model.filtersOpen || model.selectedLook.isOriginal ? "" : model.selectedLook.name)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
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
