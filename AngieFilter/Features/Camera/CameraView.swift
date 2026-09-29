import SwiftUI

enum CameraPalette {
    /// Fill for grouped controls on the black body.
    static let tray = Color.white.opacity(0.07)
    static let raised = Color.white.opacity(0.13)
    static let secondary = Color.white.opacity(0.5)
    /// The one accent: anything currently on or selected.
    static let accent = Color.yellow
}

/// Black body, three bands of fixed height: the viewfinder, a control deck, the shutter row.
/// The viewfinder carries only the picture and optional guides; every readout lives in the deck.
/// The deck swaps its contents in place, so opening a panel never moves the picture.
struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @AppStorage("viewfinder.grid") private var showsGrid = false
    @AppStorage("viewfinder.level") private var showsLevel = true
    @State private var adjustKey = AdjustKey.intensity
    @State private var shutterTaps = 0
    @State private var paneHighlight = false
    @State private var paneHighlightToken = 0
    @Environment(\.scenePhase) private var scenePhase

    private static let deckHeight: CGFloat = 156

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.status.authorization == .denied {
                permissionView
            } else if let url = model.reviewVideo {
                VideoReviewView(url: url, isSaving: model.isSaving, onRetake: model.retakeVideo, onSave: model.saveVideo)
            } else if let image = model.reviewImage {
                ReviewView(image: image, live: model.reviewLive, isSaving: model.isSaving,
                           onRetake: model.retake, onSave: model.save)
            } else {
                cameraBody
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.stopRecording() }
        }
    }

    private var cameraBody: some View {
        VStack(spacing: 0) {
            viewfinder
            deck
                .frame(height: Self.deckHeight)
            modeRow
            shutterRow
        }
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture { model.dismissPanels() }
            preview
            if let banner = model.banner {
                Text(banner)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if model.isRecording {
                recordingClock
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.banner)
        .animation(.easeOut(duration: 0.2), value: model.isRecording)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// With 跟拍, how far round the phone has circled sits beside the time, for a steady orbit.
    private var recordingClock: some View {
        let seconds = model.recordingSeconds
        return HStack(spacing: 6) {
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if let orbit = model.status.orbitDegrees {
                Text("绕 \(abs(orbit))°")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(abs(orbit) >= 90 ? CameraPalette.accent : Color.white)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(CameraPalette.tray, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .allowsHitTesting(false)
    }

    private var preview: some View {
        GeometryReader { geometry in
            let photo = model.photoRect(in: geometry.size)
            ZStack {
                PreviewContainer(view: model.session.previewView)
                if !model.status.hasCamera {
                    Text("这台设备没有可用的相机")
                        .font(.system(size: 14))
                        .foregroundStyle(CameraPalette.secondary)
                }
                if showsGrid {
                    GridOverlay()
                        .frame(width: photo.width, height: photo.height)
                        .position(x: photo.midX, y: photo.midY)
                }
                if showsLevel {
                    LevelIndicator()
                        .position(x: photo.midX, y: photo.midY)
                }
                if let point = model.focusPoint {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(CameraPalette.accent, lineWidth: 1)
                        .frame(width: 64, height: 64)
                        .position(point)
                        .allowsHitTesting(false)
                }
                paneOutline(in: geometry.size)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(previewDrag(in: geometry.size))
                    .simultaneousGesture(pinch)
            }
        }
        .aspectRatio(model.previewWidthOverHeight, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.dualSelected) { _, _ in flashPaneOutline() }
    }

    /// Shown for a moment after the edited camera changes, then fades. No permanent border on the picture.
    @ViewBuilder
    private func paneOutline(in viewSize: CGSize) -> some View {
        if model.dualOn, model.dualLayout != .blend {
            let photo = model.photoRect(in: viewSize)
            let geometry = DualFrameGeometry.make(canvas: photo.size, settings: model.dualGeometrySettings())
            let pane = geometry.pane(facing: model.dualSelected)
            let rect = pane.frame.offsetBy(dx: photo.minX, dy: photo.minY).insetBy(dx: 1, dy: 1)
            Group {
                if pane.isCircle {
                    Circle().stroke(Color.white, lineWidth: 1.5)
                } else {
                    RoundedRectangle(cornerRadius: max(pane.cornerRadius, 12), style: .continuous)
                        .stroke(Color.white, lineWidth: 1.5)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .opacity(paneHighlight ? 0.9 : 0)
            .allowsHitTesting(false)
        }
    }

    private func flashPaneOutline() {
        paneHighlightToken += 1
        let token = paneHighlightToken
        withAnimation(.easeOut(duration: 0.12)) { paneHighlight = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard token == paneHighlightToken else { return }
            withAnimation(.easeOut(duration: 0.4)) { paneHighlight = false }
        }
    }

    // MARK: Deck

    private var deckMode: Int {
        model.filtersOpen ? 1 : model.frameOpen ? 2 : 0
    }

    private var deck: some View {
        ZStack {
            if model.filtersOpen {
                filterDeck.transition(.opacity)
            } else if model.frameOpen {
                frameDeck.transition(.opacity)
            } else {
                shootDeck.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: deckMode)
        .animation(.easeInOut(duration: 0.18), value: model.adjustOpen)
    }

    private var shootDeck: some View {
        let movePicking = !model.beautyOpen && model.moveOpen && model.moveAvailable
        return VStack(spacing: model.dualOn || movePicking ? 10 : 16) {
            if model.dualOn {
                dualRow
            }
            if model.beautyOpen {
                beautyRow
            } else if movePicking {
                moveRow
                moveOptionsRow
            } else if model.dualOn, model.dualLayout == .blend {
                veilRow
            } else {
                focalRing
            }
            toolTray
        }
        .animation(.easeOut(duration: 0.15), value: model.beautyOpen)
        .animation(.easeOut(duration: 0.15), value: model.moveOpen)
        .animation(.easeOut(duration: 0.15), value: model.move)
    }

    /// Under the move row: the picked move's own setting on the left, then 水平 (off, 锁平, 匀转), 手持 and 虚化 for any
    /// move. Scrolls sideways when it doesn't fit.
    private var moveOptionsRow: some View {
        let options = model.moveOptions
        let row = HStack(spacing: 8) {
            switch model.move {
            case .dollyAway, .dollyToward:
                dollyStrength(options.strength)
            case .pushIn:
                optionChip(options.glideSecondsText, changed: options.glideSeconds != MoveOptions().glideSeconds,
                           action: model.cycleGlideSeconds)
                optionChip("到 " + MoveOptions.times(options.pushReach), changed: options.pushReach != MoveOptions().pushReach,
                           action: model.cyclePushReach)
            case .pullOut:
                optionChip(options.glideSecondsText, changed: options.glideSeconds != MoveOptions().glideSeconds,
                           action: model.cycleGlideSeconds)
                optionChip("从 " + MoveOptions.times(options.pullStart), changed: options.pullStart != MoveOptions().pullStart,
                           action: model.cyclePullStart)
            case .crashIn:
                optionChip(MoveOptions.seconds(options.crashDelay) + "后", changed: options.crashDelay != MoveOptions().crashDelay,
                           action: model.cycleCrashDelay)
                optionChip(options.crashText,
                           changed: options.crashReach != MoveOptions().crashReach || options.crashOut,
                           action: model.cycleCrashReach)
                optionChip("定格", changed: options.crashFreeze, action: model.toggleCrashFreeze)
            case .follow:
                EmptyView()
            }
            Spacer(minLength: 0)
            optionChip(options.horizon.label, changed: options.horizon != .off, action: model.cycleHorizon)
            optionChip("手持", changed: options.handheld, action: model.toggleHandheld)
            optionChip("虚化", changed: options.backgroundBlur, action: model.toggleBackgroundBlur)
        }
        .padding(.horizontal, 24)
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(height: 32)
        .transition(.opacity)
    }

    /// 希区柯克 strength as a percent: 100 holds the face's size. Double-tap the number for 100.
    private func dollyStrength(_ strength: Float) -> some View {
        HStack(spacing: 8) {
            Text("强度")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CameraPalette.secondary)
                .upright(model.iconAngle)
            Slider(
                value: Binding(
                    get: { Double(strength) },
                    set: { model.setDollyStrength(Float($0)) }
                ),
                in: Double(MoveOptions.strengthRange.lowerBound)...Double(MoveOptions.strengthRange.upperBound)
            )
            .tint(.white)
            Text("\(Int((strength * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(abs(strength - 1) < 0.001 ? Color.white : CameraPalette.accent)
                .frame(width: 38, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: model.resetDollyStrength)
        }
    }

    /// Steps through its values on each tap; yellow when not at its default.
    private func optionChip(_ title: String, changed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(changed ? CameraPalette.accent : Color.white.opacity(0.85))
                .upright(model.iconAngle)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(CameraPalette.tray, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 希区柯克's two walks, then the zoom-only moves, then 跟拍; picking one also sets the zoom the take starts at.
    /// 关闭 turns 运镜 off and hides the row. Scrolls sideways on a phone too narrow for it.
    private var moveRow: some View {
        let row = HStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(CameraMove.allCases) { move in
                    if move == .pushIn || move == .follow {
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 1, height: 14)
                            .padding(.horizontal, 3)
                    }
                    tab(move.title(model.moveOptions), selected: model.move == move, padding: 6) {
                        model.setMove(move)
                    }
                }
            }
            Spacer(minLength: 0)
            Button("关闭") { model.setMoveOn(false); model.dismissPanels() }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CameraPalette.secondary)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(height: 40)
        .transition(.opacity)
    }

    /// 美颜 strength. Double-tap the number for the default; 关闭 turns it off and hides the row.
    private var beautyRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "face.smiling")
                .font(.system(size: 13))
                .foregroundStyle(CameraPalette.secondary)
                .upright(model.iconAngle)
            Slider(
                value: Binding(
                    get: { Double(model.beautyAmount) },
                    set: { model.setBeautyAmount(Float($0)) }
                ),
                in: 0...1
            )
            .tint(.white)
            Text("\(Int((model.beautyAmount * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 26, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: model.resetBeautyAmount)
            Button("关闭") { model.setBeautyOn(false); model.dismissPanels() }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CameraPalette.secondary)
                .buttonStyle(.plain)
        }
        .frame(height: 40)
        .padding(.horizontal, 28)
        .transition(.opacity)
    }

    /// Stops in 35mm-equivalent focal lengths. The stop the lens is on, or just past, shows the live value.
    private var focalRing: some View {
        let stops = model.status.zoomStops
        let focal = model.status.focalLength
        let active = stops.last { $0.focalLength <= focal + 0.5 } ?? stops.first
        return HStack(spacing: 2) {
            ForEach(stops) { stop in
                let isActive = stop.id == active?.id
                Button {
                    model.zoom(to: stop)
                } label: {
                    Text(isActive ? "\(Int(focal.rounded()))mm" : stop.title)
                        .font(.system(size: 12, weight: isActive ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(isActive ? CameraPalette.accent : Color.white.opacity(0.8))
                        .upright(model.iconAngle)
                        .frame(minWidth: isActive ? 50 : 38, minHeight: 34)
                        .background(isActive ? CameraPalette.raised : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(CameraPalette.tray, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: active?.id)
    }

    private var toolTray: some View {
        HStack(spacing: 0) {
            trayButton(flashSymbol, on: model.status.flashMode != .off, action: model.cycleFlash)
                .disabled(!model.flashAvailable)
                .opacity(model.flashAvailable ? 1 : 0.3)
            if model.mode == .video {
                Button(action: model.toggleFrameRate) {
                    Text(model.frameRate.label)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(model.frameRate == .thirty ? Color.white : CameraPalette.accent)
                        .upright(model.iconAngle)
                        .frame(width: trayItemWidth, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lockedWhileRecording(model.isRecording)
                .overlay(alignment: .bottom) {
                    if model.status.logVideo && !model.dualOn {
                        Text("LOG")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(CameraPalette.accent)
                            .upright(model.iconAngle)
                            .offset(y: -3)
                            .allowsHitTesting(false)
                    }
                }
                if model.moveAvailable {
                    // Mid-take with 运镜 on it fires 冲击.
                    let hits = model.isRecording && model.moveOn
                    trayButton(hits ? "sparkles" : moveSymbol(model.move), on: model.moveOn, action: model.tapMove)
                        .lockedWhileRecording(model.isRecording && !hits)
                }
            } else {
                trayButton(model.liveWanted ? "livephoto" : "livephoto.slash",
                           on: model.liveWanted && model.liveAvailable, action: model.toggleLive)
                    .disabled(!model.liveAvailable)
                    .opacity(model.liveAvailable ? 1 : 0.3)
            }
            trayButton("face.smiling", on: model.beautyOn && model.beautyAmount > 0.005, action: model.tapBeauty)
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
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .upright(model.iconAngle)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .lockedWhileRecording(model.isRecording)
            trayButton("squareshape.split.3x3", on: showsGrid) { showsGrid.toggle() }
            trayButton("level", on: showsLevel) { showsLevel.toggle() }
            if model.dualAvailable {
                trayButton("rectangle.inset.bottomright.filled", on: model.dualOn, action: model.toggleDual)
                    .lockedWhileRecording(model.isRecording)
            }
            trayButton(model.dualOn ? "arrow.left.arrow.right" : "arrow.triangle.2.circlepath", on: false,
                       action: model.flipCamera)
                .lockedWhileRecording(model.isRecording && !model.dualOn)
        }
        .padding(.horizontal, 6)
        .background(CameraPalette.tray, in: Capsule())
    }

    /// Video mode carries one more button, the 希区柯克 toggle, in the same width.
    private var trayItemWidth: CGFloat {
        model.mode == .video ? 42 : 44
    }

    private func moveSymbol(_ move: CameraMove) -> String {
        switch move {
        case .dollyAway, .dollyToward: "person.and.background.dotted"
        case .pushIn: "plus.magnifyingglass"
        case .pullOut: "minus.magnifyingglass"
        case .crashIn: "bolt"
        case .follow: "viewfinder"
        }
    }

    private func trayButton(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(on ? CameraPalette.accent : Color.white)
                .upright(model.iconAngle)
                .frame(width: trayItemWidth, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dualRow: some View {
        HStack(spacing: 4) {
            ForEach(DualLayout.allCases) { layout in
                tab(layout.title, selected: model.dualLayout == layout) {
                    model.setDualLayout(layout)
                }
            }
            switch model.dualLayout {
            case .pip, .circle:
                iconButton("arrow.up.right.and.arrow.down.left", action: model.cyclePipCorner)
            case .stacked, .sideBySide, .blend:
                EmptyView()
            }
        }
        .lockedWhileRecording(model.isRecording)
    }

    private var veilRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 13))
                .foregroundStyle(CameraPalette.secondary)
            Slider(
                value: Binding(
                    get: { Double(model.veil) },
                    set: { model.setVeil(Float($0)) }
                ),
                in: 0.2...0.8
            )
            .tint(.white)
            Text("\(Int((model.veil * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 26, alignment: .trailing)
        }
        .frame(height: 40)
        .padding(.horizontal, 40)
    }

    // MARK: Filters

    private var filterDeck: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if model.dualOn {
                    cameraSegment
                } else {
                    Text(model.selectedLook.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                if let notice = model.adjustmentNotice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(CameraPalette.secondary)
                }
                Spacer()
                if !model.selectedLook.isOriginal {
                    Button(action: model.toggleAdjust) {
                        Label(model.adjustOpen ? "收起" : "调节", systemImage: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(model.adjustOpen ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(model.adjustOpen ? Color.white : CameraPalette.tray, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 16)
            if model.adjustOpen, !model.selectedLook.isOriginal {
                adjustPanel
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                familyRow
                FilterStripView(
                    looks: model.visibleLooks,
                    familyID: model.familyID,
                    selectedID: model.lookID,
                    store: model.thumbnails,
                    onSelect: model.select
                )
                .frame(height: 84)
            }
        }
    }

    /// Which camera the filter panel edits in dual mode. Tapping a pane on the picture does the same.
    private var cameraSegment: some View {
        HStack(spacing: 0) {
            segment("后置 · \(lookName(for: .back))", selected: model.dualSelected == .back) { model.selectCamera(.back) }
            segment("前置 · \(lookName(for: .front))", selected: model.dualSelected == .front) { model.selectCamera(.front) }
        }
        .padding(2)
        .background(CameraPalette.tray, in: Capsule())
    }

    private func lookName(for facing: CameraFacing) -> String {
        facing == model.dualSelected ? model.selectedLook.name : model.dualLookName(for: facing)
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(selected ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var adjustKeys: [AdjustKey] {
        AdjustKey.allCases.filter {
            switch $0 {
            case .halation: return model.selectedLook.showsHalation
            case .diffusion: return model.selectedLook.showsDiffusion
            default: return true
            }
        }
    }

    private var activeAdjustKey: AdjustKey {
        adjustKeys.contains(adjustKey) ? adjustKey : .intensity
    }

    /// One parameter at a time: pick it, then drag the single slider.
    private var adjustPanel: some View {
        let key = activeAdjustKey
        let value = key.value(in: model.draft)
        return VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(adjustKeys) { item in
                    tab(item.title, selected: item == key) { adjustKey = item }
                }
            }
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { Double(value / key.span) },
                        set: { next in model.updateDraft { key.set(Float(next) * key.span, in: &$0) } }
                    ),
                    in: 0...1
                )
                .tint(.white)
                Text("\(Int((value / key.span * 100).rounded()))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 24)
            HStack {
                Button("恢复默认", action: model.resetDraft)
                    .font(.system(size: 13))
                    .foregroundStyle(CameraPalette.secondary)
                Spacer()
                Button("保存", action: model.saveAdjustment)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
    }

    private var familyRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(LookLibrary.families) { family in
                        tab(family.name, selected: family.id == model.familyID) {
                            model.selectFamily(family.id)
                        }
                        .id(family.id)
                    }
                }
                .padding(.horizontal, 12)
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

    // MARK: Frames

    private var frameDeck: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    frameStyleTab("关闭", style: .off)
                    frameStyleTab("留白", style: .white)
                    frameStyleTab("暗房", style: .black)
                    frameStyleTab("相纸", style: .paper)
                    frameStyleTab("窗线", style: .window)
                    frameStyleTab("角标", style: .stamp)
                    frameStyleTab("压底", style: .scrim)
                    frameStyleTab("拍立得", style: .instant)
                    frameStyleTab("印记", style: .captioned)
                    frameStyleTab("字幕", style: .subtitle)
                    frameStyleTab("海报", style: .poster)
                }
                .padding(.horizontal, 12)
            }
            if model.frame.style.printsInfo {
                HStack(spacing: 18) {
                    frameToggle("型号", on: model.frame.showsModel) { model.setShowsModel($0) }
                    frameToggle("地点", on: model.frame.showsPlace) { model.setShowsPlace($0) }
                    frameToggle("日期", on: model.frame.showsDate) { model.setShowsDate($0) }
                    if model.placeMissing {
                        Text("未获得位置")
                            .font(.system(size: 12))
                            .foregroundStyle(CameraPalette.secondary)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.84))
                .padding(.horizontal, 20)
            }
            if model.frame.allowsCaption {
                TextField(model.frame.style.customTextPrompt, text: Binding(
                    get: { model.frame.customText },
                    set: { model.setCustomText($0) }
                ))
                .submitLabel(.done)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(CameraPalette.tray, in: Capsule())
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func frameStyleTab(_ title: String, style: FrameStyle) -> some View {
        tab(title, selected: model.frame.style == style) {
            model.selectFrameStyle(style)
        }
    }

    private func frameToggle(_ title: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button {
            set(!on)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? CameraPalette.accent : CameraPalette.secondary)
                Text(title)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Shutter row

    /// Hidden but still laid out while recording, so the shutter never moves under the finger.
    private var modeRow: some View {
        HStack(spacing: 18) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    model.setMode(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.mode == mode ? CameraPalette.accent : Color.white.opacity(0.6))
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(model.isRecording ? 0 : 1)
        .allowsHitTesting(!model.isRecording)
        .animation(.easeOut(duration: 0.15), value: model.mode)
    }

    private var shutterRow: some View {
        HStack {
            sideButton("photo.artframe", open: model.frameOpen, applied: model.frame.drawsBorder, action: model.toggleFrame)
                .lockedWhileRecording(model.isRecording)
                .frame(maxWidth: .infinity)
            Button {
                shutterTaps += 1
                model.capture()
            } label: {
                let video = model.mode == .video
                let recording = model.isRecording
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 3.5)
                        .frame(width: 78, height: 78)
                    RoundedRectangle(cornerRadius: recording ? 7 : 32.5, style: .continuous)
                        .fill(video ? Color.red : Color.white)
                        .frame(width: recording ? 30 : 65, height: recording ? 30 : 65)
                }
                .contentShape(Circle())
                .animation(.easeInOut(duration: 0.2), value: recording)
                .animation(.easeInOut(duration: 0.2), value: video)
            }
            .buttonStyle(ShutterStyle())
            .sensoryFeedback(.impact(weight: .medium), trigger: shutterTaps)
            sideButton("camera.filters", open: model.filtersOpen, applied: !model.selectedLook.isOriginal,
                       action: model.toggleFilters)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// White while its panel is open; a yellow glyph means its setting is in use.
    private func sideButton(_ symbol: String, open: Bool, applied: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(open ? Color.black : applied ? CameraPalette.accent : Color.white)
                .upright(model.iconAngle)
                .frame(width: 50, height: 50)
                .background(open ? Color.white : CameraPalette.tray, in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// Text tab: selected is bright and bold, the rest recede. No boxes.
    private func tab(_ title: String, selected: Bool, padding: CGFloat = 8, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                .padding(.horizontal, padding)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 28)
                .background(CameraPalette.tray, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Other

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera")
                .font(.system(size: 40, weight: .light))
            Text("需要相机权限")
                .font(.system(size: 22, weight: .semibold))
            Text("AngieFilter 只用相机取景和拍摄。可以在设置里打开权限。")
                .font(.system(size: 15))
                .foregroundStyle(CameraPalette.secondary)
                .multilineTextAlignment(.center)
            Button("前往设置", action: model.openSettings)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .frame(height: 46)
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

    private var flashSymbol: String {
        switch model.status.flashMode {
        case .off: return "bolt.slash"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic"
        }
    }
}

private enum AdjustKey: CaseIterable, Identifiable {
    case intensity, fade, diffusion, halation, grain, vignette

    var id: Self { self }

    var title: String {
        switch self {
        case .intensity: return "强度"
        case .fade: return "褪色"
        case .diffusion: return "柔光"
        case .halation: return "光晕"
        case .grain: return "颗粒"
        case .vignette: return "暗角"
        }
    }

    /// The slider's full travel. Vignette runs past 1.
    var span: Float {
        self == .vignette ? 1.5 : 1
    }

    func value(in adjustment: LookAdjustment) -> Float {
        switch self {
        case .intensity: return adjustment.intensity
        case .fade: return adjustment.fade
        case .diffusion: return adjustment.diffusion
        case .halation: return adjustment.halation
        case .grain: return adjustment.grain
        case .vignette: return adjustment.vignette
        }
    }

    func set(_ value: Float, in adjustment: inout LookAdjustment) {
        switch self {
        case .intensity: adjustment.intensity = value
        case .fade: adjustment.fade = value
        case .diffusion: adjustment.diffusion = value
        case .halation: adjustment.halation = value
        case .grain: adjustment.grain = value
        case .vignette: adjustment.vignette = value
        }
    }
}

private extension View {
    /// Turns a glyph in place to read upright however the phone is held. The layout stays portrait.
    func upright(_ angle: Double) -> some View {
        rotationEffect(.radians(angle))
            .animation(.easeInOut(duration: 0.3), value: angle)
    }

    /// Controls that would change the movie's size mid-recording.
    func lockedWhileRecording(_ locked: Bool) -> some View {
        disabled(locked).opacity(locked ? 0.3 : 1)
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PreviewContainer: UIViewRepresentable {
    let view: PreviewMetalView

    func makeUIView(context: Context) -> PreviewMetalView {
        view
    }

    func updateUIView(_ uiView: PreviewMetalView, context: Context) {}
}
