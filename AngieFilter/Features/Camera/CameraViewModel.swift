import Combine
import CoreImage
import SwiftUI

/// Observed only by the filter strip, so a thumbnail refresh never re-renders the camera screen.
@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [Look.ID: UIImage] = [:]

    func merge(_ fresh: [Look.ID: UIImage]) {
        images.merge(fresh) { _, new in new }
    }
}

/// One low-priority context, so the strip yields the GPU to the live preview.
/// Each refresh renders the frame once into a small square, lays every graded look out as a tile
/// of one atlas, and reads the atlas back with a single GPU pass.
private enum ThumbnailBake {
    private static let columns = 8
    static let context = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
    ])

    /// The strip shows a square, so only the center square is graded.
    static func base(from source: CIImage) -> CIImage? {
        let extent = source.extent
        let edge = min(extent.width, extent.height).rounded(.down)
        guard edge > 1 else { return nil }
        let square = CGRect(x: extent.midX - edge / 2, y: extent.midY - edge / 2, width: edge, height: edge)
        let shifted = source.cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
        guard let cgImage = context.createCGImage(shifted, from: CGRect(x: 0, y: 0, width: edge, height: edge)) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }

    static func images(from base: CIImage, looks: [Look]) -> [Look.ID: UIImage] {
        guard !looks.isEmpty else { return [:] }
        let edge = base.extent.width
        let rows = (looks.count + columns - 1) / columns
        let atlasRect = CGRect(x: 0, y: 0, width: edge * CGFloat(columns), height: edge * CGFloat(rows))
        var atlas = CIImage.empty()
        var tiles: [(id: Look.ID, rect: CGRect)] = []
        for (index, look) in looks.enumerated() {
            let x = CGFloat(index % columns) * edge
            let y = CGFloat(index / columns) * edge
            let graded = GradeApplicator.apply(base, look: look, adjustment: .baseline(for: look), quality: .thumbnail)
                .cropped(to: base.extent)
                .transformed(by: CGAffineTransform(translationX: x, y: y))
            atlas = graded.composited(over: atlas)
            tiles.append((look.id, CGRect(x: x, y: atlasRect.height - y - edge, width: edge, height: edge)))
        }
        guard let cgImage = context.createCGImage(atlas, from: atlasRect) else { return [:] }
        var images: [Look.ID: UIImage] = [:]
        for tile in tiles {
            if let slice = cgImage.cropping(to: tile.rect) {
                images[tile.id] = UIImage(cgImage: slice)
            }
        }
        return images
    }
}

/// The review screen's Live Photo: the still shows at once, the graded movie follows a few seconds later.
enum LiveReview: Equatable {
    case none
    case processing(Int64)
    case ready(LivePhotoFiles)
    case failed
}

@MainActor
final class CameraViewModel: ObservableObject {
    private static let liveKey = "capture.live"
    private static let frameRateKey = "capture.frameRate"
    private static let beautyKey = "capture.beauty"
    private static let beautyAmountKey = "capture.beautyAmount"
    /// Light enough that the face still reads as untouched: blotches soften, pores and stubble stay.
    static let beautyDefault: Float = 0.3

    @Published private(set) var status = CameraStatus()
    @Published var aspectRatio: AspectRatio = .threeFour
    @Published var lookID = Look.originalID
    @Published var adjustOpen = false
    @Published var draft = LookAdjustment()
    @Published var adjustmentNotice: String?
    @Published var filtersOpen = false
    @Published var frameOpen = false
    @Published var frame = FrameSettings()
    /// True while the place switch is on, the caption style is selected, and no place string exists yet.
    @Published private(set) var placeMissing = false
    @Published var familyID = "original"
    @Published var reviewImage: UIImage?
    @Published private(set) var reviewLive: LiveReview = .none
    @Published var isSaving = false
    @Published private(set) var liveWanted = UserDefaults.standard.bool(forKey: CameraViewModel.liveKey)
    /// 希区柯克变焦, offered in single-camera video mode. Not kept across launches.
    @Published private(set) var dollyOn = false
    @Published private(set) var dollyDirection = DollyDirection.away
    /// The direction picker, in place of the focal ring.
    @Published private(set) var dollyOpen = false
    @Published private(set) var beautyOn = UserDefaults.standard.bool(forKey: CameraViewModel.beautyKey)
    /// Kept while 美颜 is off, so turning it back on returns to the same strength.
    @Published private(set) var beautyAmount = UserDefaults.standard.object(forKey: CameraViewModel.beautyAmountKey) as? Float
        ?? CameraViewModel.beautyDefault
    /// The strength slider, in place of the focal ring.
    @Published private(set) var beautyOpen = false
    @Published private(set) var mode = CaptureMode.photo
    @Published private(set) var frameRate = VideoFrameRate(
        rawValue: UserDefaults.standard.integer(forKey: CameraViewModel.frameRateKey)
    ) ?? .thirty
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var reviewVideo: URL?
    private var recordingTimer: Timer?
    @Published var focusPoint: CGPoint?
    let thumbnails = ThumbnailStore()
    @Published var banner: String?
    @Published var showZoomReadout = false
    /// Radians the controls' glyphs turn so they read upright. Accumulates, so every turn takes the short way.
    @Published private(set) var iconAngle: Double = 0
    private var hold = HoldOrientation.portrait

    let looks = LookLibrary.looks
    let session = CameraSessionController()
    let dualSession: DualSessionController

    @Published private(set) var dualAvailable = DualSessionController.isSupported
    @Published private(set) var dualOn = false
    @Published var dualLayout: DualLayout = .pip
    @Published var dualLead: CameraFacing = .back
    @Published var dualSelected: CameraFacing = .back
    @Published var pipCorner: PipCorner = .bottomRight
    @Published var pipLeft: CGFloat?
    @Published var pipTop: CGFloat?
    @Published var veil: Float = 0.45

    private var savedAdjustments: [Look.ID: LookAdjustment] = [:]
    /// The frame caught when the filter panel opened. Every thumbnail until it closes grades this one bitmap.
    private var thumbnailBase: CIImage?
    private var thumbnailRendered: Set<Look.ID> = []
    private var thumbnailEpoch = 0
    private let thumbnailLiveEpoch = Locked(0)
    private let thumbnailQueue = DispatchQueue(label: "angie.thumbnails", qos: .userInitiated)
    private var focusClear: Task<Void, Never>?
    private var zoomHide: Task<Void, Never>?
    private var dayTimer: Timer?
    private var previewDate = FrameDateText.string(from: Date())
    private var placeText = ""
    private let places = PlaceReader()
    private var pinchStart: CGFloat = 1
    private var isPinching = false
    private var dualTransition = false
    private var singleLookID = Look.originalID
    private var singleFamilyID = "original"
    private var singleSaved: [Look.ID: LookAdjustment] = [:]
    private var singleDraft = LookAdjustment()
    private var singleAdjustOpen = false
    private var dualLook: [CameraFacing: Look.ID] = [.back: Look.originalID, .front: Look.originalID]
    private var dualFamily: [CameraFacing: String] = [.back: "original", .front: "original"]
    private var dualSaved: [CameraFacing: [Look.ID: LookAdjustment]] = [:]
    private var dualDraft: [CameraFacing: LookAdjustment] = [:]
    private var dualAdjustOpen: [CameraFacing: Bool] = [:]
    private var insetDragOrigin: CGPoint?
    private var insetDragSize = CGSize.zero
    private var insetDragMoved = false
    private var insetDragDecided = false

    init() {
        dualSession = DualSessionController(previewView: session.previewView)
        session.onStatus = { [weak self] status in
            guard let self, !self.dualOn else { return }
            self.status = status
        }
        session.onPhoto = { [weak self] image, liveID in
            self?.showReview(image)
            self?.reviewLive = liveID.map { .processing($0) } ?? .none
        }
        session.onLivePhoto = { [weak self] id, files in
            self?.liveArrived(id, files: files)
        }
        session.onFailure = { [weak self] message in
            self?.banner = message
        }
        dualSession.onStatus = { [weak self] status in
            guard let self, self.dualOn else { return }
            self.status = status
        }
        dualSession.onPhoto = { [weak self] image in
            self?.showReview(image)
            self?.reviewLive = .none
        }
        dualSession.onFailure = { [weak self] message in
            self?.banner = message
        }
        places.onPlace = { [weak self] text in
            guard let self else { return }
            self.placeMissing = false
            guard text != self.placeText else { return }
            self.placeText = text
            self.syncParameters()
        }
        places.onDenied = { [weak self] in
            guard let self else { return }
            self.placeText = ""
            self.placeMissing = self.frame.showsPlace && self.frame.style.printsInfo
            self.syncParameters()
        }
        MotionHub.shared.onHold = { [weak self] hold in
            self?.holdChanged(hold)
        }
        MotionHub.shared.start()
        syncParameters()
        MainThreadWatch.start()
        session.setLivePhoto(liveWanted)
        session.setVideoFrameRate(frameRate)
        dualSession.setVideoFrameRate(frameRate)
        session.start()
        dayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPreviewDate()
            }
        }
    }

    var selectedLook: Look {
        LookLibrary.look(id: lookID)
    }

    var visibleLooks: [Look] {
        LookLibrary.family(id: familyID)?.looks ?? [LookLibrary.original]
    }

    func setAspect(_ ratio: AspectRatio) {
        guard aspectRatio != ratio, !isRecording else { return }
        aspectRatio = ratio
        syncParameters()
    }

    var flashAvailable: Bool {
        mode == .photo && (dualOn || status.facing == .back)
    }

    func cycleFlash() {
        guard flashAvailable else { return }
        let next = status.flashMode.next()
        status.flashMode = next
        if dualOn {
            dualSession.setFlash(next)
        } else {
            session.setFlash(next)
        }
    }

    func flipCamera() {
        guard !isRecording else { return }
        if dualOn {
            swapLead()
            return
        }
        let next: CameraFacing = status.facing == .back ? .front : .back
        session.setFacing(next)
    }

    func toggleDual() {
        guard dualAvailable, !dualTransition, !isRecording else { return }
        dualTransition = true
        if dualOn {
            rememberDualLook()
            leaveDual(message: nil)
        } else {
            rememberSingleLook()
            applyDualLook()
            dualOn = true
            dualSession.setSelected(dualSelected)
            dualSession.setFlash(status.flashMode)
            syncParameters()
            session.stop { [weak self] in
                guard let self else { return }
                self.dualSession.start { [weak self] outcome in
                    guard let self else { return }
                    switch outcome {
                    case .running:
                        guard self.dualOn else { return }
                        self.syncParameters()
                        self.dualTransition = false
                        if self.filtersOpen { self.captureThumbnailReference() }
                    case .waitingForAuthorization:
                        guard self.dualOn else { return }
                        self.dualTransition = false
                    case .unavailable(let message):
                        self.leaveDual(message: message)
                    }
                }
            }
        }
    }

    private func leaveDual(message: String?) {
        guard dualOn else { return }
        let flash = status.flashMode
        dualOn = false
        restoreSingleLook()
        if let message {
            banner = message
        }
        dualTransition = true
        dualSession.stop { [weak self] in
            guard let self else { return }
            self.session.setFlash(flash)
            self.session.start()
            self.syncParameters()
            self.dualTransition = false
            if self.filtersOpen { self.captureThumbnailReference() }
        }
    }

    func setDualLayout(_ layout: DualLayout) {
        guard dualLayout != layout, !isRecording else { return }
        dualLayout = layout
        syncParameters()
    }

    func swapLead() {
        dualLead = dualLead == .back ? .front : .back
        syncParameters()
    }

    func cyclePipCorner() {
        pipCorner = pipCorner.next()
        pipLeft = nil
        pipTop = nil
        syncParameters()
    }

    func setVeil(_ value: Float) {
        veil = min(max(value, 0.2), 0.8)
        syncParameters()
    }

    func selectCamera(_ facing: CameraFacing) {
        guard dualOn, dualSelected != facing else { return }
        rememberDualLook()
        dualSelected = facing
        lookID = dualLook[facing] ?? Look.originalID
        familyID = dualFamily[facing] ?? LookLibrary.family(containing: lookID).id
        savedAdjustments = dualSaved[facing] ?? [:]
        adjustOpen = dualAdjustOpen[facing] ?? false
        if adjustOpen {
            draft = dualDraft[facing] ?? .baseline(for: selectedLook)
        }
        adjustmentNotice = nil
        dualSession.setSelected(facing)
        syncParameters()
        if filtersOpen { captureThumbnailReference() }
    }

    func dualLookName(for facing: CameraFacing) -> String {
        LookLibrary.look(id: dualLook[facing] ?? Look.originalID).name
    }

    func dualGeometrySettings() -> DualSettings {
        DualSettings(
            layout: dualLayout,
            lead: dualLead,
            selected: dualSelected,
            pipCorner: pipCorner,
            pipLeft: pipLeft,
            pipTop: pipTop,
            veil: veil
        )
    }

    var previewWidthOverHeight: CGFloat {
        let photo = aspectRatio.widthOverHeight
        guard frame.drawsBorder else { return photo }
        return FrameLayout.outerWidthOverHeight(photoWidthOverHeight: photo, style: frame.style)
    }

    func photoRect(in size: CGSize) -> CGRect {
        guard frame.drawsBorder else { return CGRect(origin: .zero, size: size) }
        let fractions = FrameLayout.fractions(photoWidthOverHeight: aspectRatio.widthOverHeight, style: frame.style)
        return CGRect(
            x: size.width * fractions.left,
            y: size.height * fractions.top,
            width: size.width * (1 - fractions.left * 2),
            height: size.height * (1 - fractions.top - fractions.bottom)
        )
    }

    func selectFamily(_ id: String) {
        guard familyID != id else { return }
        familyID = id
        adjustOpen = false
        renderThumbnails()
        syncParameters()
    }

    func select(_ look: Look) {
        if lookID == look.id, !look.isOriginal {
            toggleAdjust()
            return
        }
        lookID = look.id
        familyID = LookLibrary.family(containing: look.id).id
        adjustOpen = false
        adjustmentNotice = nil
        syncParameters()
    }

    func toggleAdjust() {
        guard !selectedLook.isOriginal else { return }
        if adjustOpen {
            adjustOpen = false
        } else {
            draft = savedAdjustments[lookID] ?? .baseline(for: selectedLook)
            adjustmentNotice = nil
            adjustOpen = true
        }
        syncParameters()
    }

    func updateDraft(_ body: (inout LookAdjustment) -> Void) {
        body(&draft)
        adjustmentNotice = nil
        syncParameters()
    }

    func resetDraft() {
        draft = .baseline(for: selectedLook)
        adjustmentNotice = nil
        syncParameters()
    }

    func saveAdjustment() {
        guard !selectedLook.isOriginal else { return }
        let baseline = LookAdjustment.baseline(for: selectedLook)
        if draft == baseline {
            savedAdjustments.removeValue(forKey: lookID)
        } else {
            savedAdjustments[lookID] = draft
        }
        adjustmentNotice = "已保存"
        syncParameters()
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if adjustmentNotice == "已保存" {
                adjustmentNotice = nil
            }
        }
    }

    func toggleFilters() {
        frameOpen = false
        beautyOpen = false
        dollyOpen = false
        filtersOpen.toggle()
        if filtersOpen {
            familyID = LookLibrary.family(containing: lookID).id
            captureThumbnailReference()
        } else {
            closeFilters()
        }
    }

    func closeFilters() {
        filtersOpen = false
        adjustOpen = false
        resetThumbnails()
    }

    func toggleFrame() {
        guard !isRecording else { return }
        if frameOpen {
            frameOpen = false
            return
        }
        if filtersOpen { closeFilters() }
        beautyOpen = false
        dollyOpen = false
        frameOpen = true
    }

    func dismissPanels() {
        frameOpen = false
        beautyOpen = false
        dollyOpen = false
        closeFilters()
    }

    func selectFrameStyle(_ style: FrameStyle) {
        frame.style = style
        refreshPlaceTracking()
        syncParameters()
    }

    func setShowsModel(_ shows: Bool) {
        frame.showsModel = shows
        syncParameters()
    }

    func setShowsDate(_ shows: Bool) {
        frame.showsDate = shows
        syncParameters()
    }

    func setShowsPlace(_ shows: Bool) {
        frame.showsPlace = shows
        refreshPlaceTracking()
        syncParameters()
    }

    func setCustomText(_ text: String) {
        let next = FrameSettings.limited(text, style: frame.style)
        guard next != frame.customText else { return }
        frame.customText = next
        syncParameters()
    }

    func previewDragChanged(start: CGPoint, current: CGPoint, in viewSize: CGSize) {
        guard !isPinching else { return }
        guard dualOn, dualLayout == .pip || dualLayout == .circle else { return }
        let photo = photoRect(in: viewSize)
        let startLocal = CGPoint(x: start.x - photo.minX, y: start.y - photo.minY)
        let currentLocal = CGPoint(x: current.x - photo.minX, y: current.y - photo.minY)
        if !insetDragDecided {
            insetDragDecided = true
            let geometry = DualFrameGeometry.make(canvas: photo.size, settings: dualGeometrySettings())
            guard geometry.other.contains(startLocal) else { return }
            insetDragOrigin = geometry.other.frame.origin
            insetDragSize = geometry.other.frame.size
        }
        guard let origin = insetDragOrigin else { return }
        let dx = currentLocal.x - startLocal.x
        let dy = currentLocal.y - startLocal.y
        if !insetDragMoved, dx * dx + dy * dy < 64 { return }
        insetDragMoved = true
        var left = origin.x + dx
        var top = origin.y + dy
        left = min(max(0, left), max(0, photo.width - insetDragSize.width))
        top = min(max(0, top), max(0, photo.height - insetDragSize.height))
        guard photo.width > 1, photo.height > 1 else { return }
        pipLeft = left / photo.width
        pipTop = top / photo.height
        syncParameters()
    }

    func previewDragEnded(start: CGPoint, current: CGPoint, in viewSize: CGSize) {
        let movedInset = insetDragMoved
        insetDragOrigin = nil
        insetDragSize = .zero
        insetDragMoved = false
        insetDragDecided = false
        if isPinching || movedInset { return }
        let dx = current.x - start.x
        let dy = current.y - start.y
        if dx * dx + dy * dy > 64 { return }
        // In dual mode a tap on a pane picks which camera the open filter panel edits.
        if frameOpen || beautyOpen || dollyOpen || (filtersOpen && !dualOn) {
            dismissPanels()
        }
        let photo = photoRect(in: viewSize)
        guard photo.contains(start) else { return }
        let local = CGPoint(x: start.x - photo.minX, y: start.y - photo.minY)
        if dualOn {
            focusDual(local: local, photoSize: photo.size, displayPoint: start)
        } else {
            focus(viewPoint: local, in: photo.size, displayPoint: start)
        }
    }

    func focus(viewPoint: CGPoint, in size: CGSize, displayPoint: CGPoint) {
        guard size.width > 1, size.height > 1 else { return }
        let x = min(max(viewPoint.x / size.width, 0), 1)
        let y = min(max(viewPoint.y / size.height, 0), 1)
        let devicePoint = status.facing == .front
            ? CGPoint(x: y, y: x)
            : CGPoint(x: y, y: 1 - x)
        showFocus(at: displayPoint)
        session.focus(atDevicePoint: devicePoint)
    }

    func pinchChanged(_ scale: CGFloat) {
        if !isPinching {
            isPinching = true
            pinchStart = status.zoomFactor
        }
        insetDragDecided = true
        insetDragOrigin = nil
        let factor = pinchStart * scale
        if dualOn {
            dualSession.setZoom(factor: factor)
        } else {
            session.setZoom(factor: factor)
        }
        showZoomReadout = true
    }

    func pinchEnded() {
        isPinching = false
        zoomHide?.cancel()
        zoomHide = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            showZoomReadout = false
        }
    }

    func zoom(to stop: ZoomStop) {
        if dualOn {
            dualSession.setZoom(factor: stop.factor)
        } else {
            session.setZoom(factor: stop.factor)
        }
        showZoomReadout = true
        pinchEnded()
    }

    func capture() {
        guard !dualTransition else { return }
        if mode == .video {
            isRecording ? stopRecording() : startRecording()
            return
        }
        if dualOn {
            dualSession.capturePhoto()
        } else {
            session.capturePhoto()
        }
    }

    /// Live Photo needs the single-camera photo pipeline; dual never offers it.
    var liveAvailable: Bool {
        mode == .photo && !dualOn && status.liveSupported
    }

    /// Both sessions keep the mode, so switching single and dual in video mode keeps the microphone.
    func setMode(_ next: CaptureMode) {
        guard mode != next, !isRecording else { return }
        mode = next
        session.setVideoMode(next == .video)
        dualSession.setVideoMode(next == .video)
    }

    var dollyAvailable: Bool {
        mode == .video && !dualOn
    }

    /// During a take the zoom follows the distance to the face, so it keeps its size while the phone moves, and only
    /// goes the way the picked walk does. A zoom stop or a pinch mid-take starts over from the size then.
    /// Off: turns it on and shows the direction picker. On: shows or hides the picker.
    func tapDolly() {
        guard dollyAvailable, !isRecording else { return }
        guard dollyOn else {
            setDollyOn(true)
            dollyOpen = true
            return
        }
        dollyOpen.toggle()
    }

    func setDollyOn(_ on: Bool) {
        guard dollyAvailable, !isRecording, dollyOn != on else { return }
        dollyOn = on
        session.setDollyZoom(on, direction: dollyDirection)
        flashBanner(on ? dollyDirection.hint : "希区柯克已关闭")
    }

    /// Moves the zoom to where that walk starts.
    func setDollyDirection(_ direction: DollyDirection) {
        guard dollyOn, !isRecording, dollyDirection != direction else { return }
        dollyDirection = direction
        session.setDollyZoom(true, direction: direction)
        flashBanner(direction.hint)
    }

    func toggleFrameRate() {
        guard mode == .video, !isRecording else { return }
        frameRate = frameRate.next
        UserDefaults.standard.set(frameRate.rawValue, forKey: Self.frameRateKey)
        session.setVideoFrameRate(frameRate)
        dualSession.setVideoFrameRate(frameRate)
        flashBanner(frameRate == .twentyFour ? "24 帧，电影的帧率" : "30 帧")
    }

    /// The frame, aspect, and dual layout fix the movie's size, so they lock while recording. Looks can still change.
    private func startRecording() {
        guard !isRecording else { return }
        frameOpen = false
        dollyOpen = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mov")
        if dualOn {
            dualSession.startRecording(to: url)
        } else {
            session.startRecording(to: url)
        }
        isRecording = true
        recordingSeconds = 0
        let start = Date()
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        let finish: (URL?) -> Void = { [weak self] url in
            self?.recordingFinished(url)
        }
        if dualOn {
            dualSession.stopRecording(finish)
        } else {
            session.stopRecording(finish)
        }
    }

    private func recordingFinished(_ url: URL?) {
        guard let url else {
            flashBanner("录像没有保存下来")
            return
        }
        discardVideo()
        reviewVideo = url
        closeFilters()
        frameOpen = false
    }

    func retakeVideo() {
        discardVideo()
    }

    func saveVideo() {
        guard let url = reviewVideo, !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await PhotoLibraryStore.saveVideo(url)
                discardVideo()
                flashBanner("已保存到最近项目")
            } catch {
                banner = "保存失败，可以再试一次"
            }
            isSaving = false
        }
    }

    private func discardVideo() {
        if let reviewVideo {
            try? FileManager.default.removeItem(at: reviewVideo)
        }
        reviewVideo = nil
    }

    func toggleLive() {
        guard liveAvailable, !isRecording else { return }
        liveWanted.toggle()
        UserDefaults.standard.set(liveWanted, forKey: Self.liveKey)
        session.setLivePhoto(liveWanted)
        flashBanner(liveWanted ? "实况已打开" : "实况已关闭")
    }

    /// Off: turns 美颜 on at the last strength and shows the slider. On: shows or hides the slider.
    /// Works under every look, in photos, video, and both cameras, and may change mid-take.
    func tapBeauty() {
        guard beautyOn else {
            setBeautyOn(true)
            beautyOpen = true
            return
        }
        beautyOpen.toggle()
    }

    func setBeautyOn(_ on: Bool) {
        guard beautyOn != on else { return }
        beautyOn = on
        if on, beautyAmount < 0.01 {
            setBeautyAmount(Self.beautyDefault)
        }
        UserDefaults.standard.set(on, forKey: Self.beautyKey)
        syncParameters()
        flashBanner(on ? "美颜已打开" : "美颜已关闭")
    }

    func setBeautyAmount(_ value: Float) {
        beautyAmount = min(max(value, 0), 1)
        UserDefaults.standard.set(beautyAmount, forKey: Self.beautyAmountKey)
        syncParameters()
    }

    func resetBeautyAmount() {
        setBeautyAmount(Self.beautyDefault)
    }

    func retake() {
        reviewImage = nil
        discardLive()
    }

    func save() {
        guard let reviewImage, !isSaving else { return }
        if case .processing = reviewLive { return }
        isSaving = true
        let live = reviewLive
        Task {
            do {
                if case .ready(let files) = live {
                    try await PhotoLibraryStore.saveLive(files)
                    files.discard()
                    self.reviewLive = .none
                } else {
                    try await PhotoLibraryStore.save(reviewImage)
                }
                self.reviewImage = nil
                banner = "已保存到最近项目"
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if banner == "已保存到最近项目" {
                        banner = nil
                    }
                }
            } catch {
                banner = "保存失败，可以再试一次"
            }
            isSaving = false
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func renderedAdjustment(for look: Look) -> LookAdjustment {
        guard !look.isOriginal else { return LookAdjustment() }
        if adjustOpen, look.id == lookID {
            return draft
        }
        return savedAdjustments[look.id] ?? .baseline(for: look)
    }

    private func holdChanged(_ next: HoldOrientation) {
        guard next != hold else { return }
        hold = next
        iconAngle += HoldOrientation.normalized(-next.angle - iconAngle)
        syncParameters()
    }

    private func syncParameters() {
        let hold = hold
        let beauty = beautyOn ? beautyAmount : 0
        if dualOn {
            let settings = currentDualSettings()
            let aspect = aspectRatio
            let framed = frame
            let date = previewDate
            let place = placeText
            dualSession.updateRenderParameters { parameters in
                parameters.aspectRatio = aspect
                parameters.frame = framed
                parameters.frameDate = date
                parameters.framePlace = place
                parameters.hold = hold
                parameters.beauty = beauty
                parameters.dual = settings
            }
        } else {
            let aspect = aspectRatio
            let look = selectedLook
            let adjustment = renderedAdjustment(for: look)
            session.updateRenderParameters { parameters in
                parameters.aspectRatio = aspect
                parameters.lookID = look.id
                parameters.adjustment = adjustment
                parameters.frame = frame
                parameters.frameDate = previewDate
                parameters.framePlace = placeText
                parameters.hold = hold
                parameters.beauty = beauty
                parameters.dual = nil
            }
        }
    }

    private func currentDualSettings() -> DualSettings {
        dualLook[dualSelected] = lookID
        dualFamily[dualSelected] = familyID
        dualSaved[dualSelected] = savedAdjustments
        var settings = dualGeometrySettings()
        settings.veil = min(max(veil, 0.2), 0.8)
        settings.backLookID = dualLook[.back] ?? Look.originalID
        settings.frontLookID = dualLook[.front] ?? Look.originalID
        settings.backAdjustment = adjustment(for: .back)
        settings.frontAdjustment = adjustment(for: .front)
        return settings
    }

    private func adjustment(for facing: CameraFacing) -> LookAdjustment {
        let id = facing == dualSelected ? lookID : (dualLook[facing] ?? Look.originalID)
        let look = LookLibrary.look(id: id)
        guard !look.isOriginal else { return LookAdjustment() }
        if facing == dualSelected {
            return renderedAdjustment(for: look)
        }
        return dualSaved[facing]?[id] ?? .baseline(for: look)
    }

    private func rememberSingleLook() {
        singleLookID = lookID
        singleFamilyID = familyID
        singleSaved = savedAdjustments
        singleDraft = draft
        singleAdjustOpen = adjustOpen
    }

    private func restoreSingleLook() {
        lookID = singleLookID
        familyID = singleFamilyID
        savedAdjustments = singleSaved
        draft = singleDraft
        adjustOpen = singleAdjustOpen
        adjustmentNotice = nil
    }

    private func rememberDualLook() {
        dualLook[dualSelected] = lookID
        dualFamily[dualSelected] = familyID
        dualSaved[dualSelected] = savedAdjustments
        dualDraft[dualSelected] = draft
        dualAdjustOpen[dualSelected] = adjustOpen
    }

    private func applyDualLook() {
        lookID = dualLook[dualSelected] ?? Look.originalID
        familyID = dualFamily[dualSelected] ?? LookLibrary.family(containing: lookID).id
        savedAdjustments = dualSaved[dualSelected] ?? [:]
        adjustOpen = dualAdjustOpen[dualSelected] ?? false
        if adjustOpen {
            draft = dualDraft[dualSelected] ?? .baseline(for: selectedLook)
        }
        adjustmentNotice = nil
    }

    private func focusDual(local: CGPoint, photoSize: CGSize, displayPoint: CGPoint) {
        let geometry = DualFrameGeometry.make(canvas: photoSize, settings: dualGeometrySettings())
        switch geometry.hit(local) {
        case .none:
            return
        case .blend(let frame):
            focusPane(frame, facing: dualSelected, local: local, displayPoint: displayPoint)
        case .pane(let facing, let frame):
            if facing != dualSelected {
                selectCamera(facing)
            }
            focusPane(frame, facing: facing, local: local, displayPoint: displayPoint)
        }
    }

    private func focusPane(_ frame: CGRect, facing: CameraFacing, local: CGPoint, displayPoint: CGPoint) {
        guard frame.width > 1, frame.height > 1 else { return }
        let point = CGPoint(
            x: min(max((local.x - frame.minX) / frame.width, 0), 1),
            y: min(max((local.y - frame.minY) / frame.height, 0), 1)
        )
        showFocus(at: displayPoint)
        dualSession.focus(atCellPoint: point, facing: facing, cellAspect: frame.width / frame.height)
    }

    private func showFocus(at displayPoint: CGPoint) {
        focusPoint = displayPoint
        focusClear?.cancel()
        focusClear = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            focusPoint = nil
        }
    }

    private func showReview(_ image: UIImage) {
        discardLive()
        reviewImage = image
        closeFilters()
        frameOpen = false
    }

    private func liveArrived(_ id: Int64, files: LivePhotoFiles?) {
        guard case .processing(let waiting) = reviewLive, waiting == id else {
            files?.discard()
            return
        }
        if let files {
            reviewLive = .ready(files)
        } else {
            reviewLive = .failed
            flashBanner("实况没有生成，会保存为照片")
        }
    }

    private func discardLive() {
        if case .ready(let files) = reviewLive {
            files.discard()
        }
        reviewLive = .none
    }

    private func flashBanner(_ text: String) {
        banner = text
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if banner == text {
                banner = nil
            }
        }
    }

    private func refreshPlaceTracking() {
        let wants = frame.showsPlace && frame.style.printsInfo
        if wants {
            placeMissing = placeText.isEmpty
            places.start()
        } else {
            places.stop()
            placeMissing = false
        }
    }

    /// Asks the camera for its next frame and makes it the reference for this opening of the panel.
    private func captureThumbnailReference() {
        guard filtersOpen else { return }
        let epoch = resetThumbnails()
        let queue = thumbnailQueue
        let arrived: @Sendable (CIImage?) -> Void = { [weak self] source in
            queue.async {
                let base = source.flatMap(ThumbnailBake.base(from:))
                DispatchQueue.main.async {
                    self?.referenceArrived(base, epoch: epoch)
                }
            }
        }
        if dualOn {
            dualSession.requestThumbnailSource(arrived)
        } else {
            session.requestThumbnailSource(arrived)
        }
    }

    @discardableResult
    private func resetThumbnails() -> Int {
        thumbnailEpoch += 1
        let epoch = thumbnailEpoch
        thumbnailLiveEpoch.with { $0 = epoch }
        thumbnailBase = nil
        thumbnailRendered = []
        return epoch
    }

    private func referenceArrived(_ base: CIImage?, epoch: Int) {
        guard epoch == thumbnailEpoch, filtersOpen, let base else { return }
        thumbnailBase = base
        renderThumbnails()
    }

    /// Grades the reference once for each look of the current family not yet drawn in this opening,
    /// one atlas row of eight at a time.
    private func renderThumbnails() {
        guard let base = thumbnailBase else { return }
        let looks = visibleLooks.filter { !thumbnailRendered.contains($0.id) }
        guard !looks.isEmpty else { return }
        thumbnailRendered.formUnion(looks.map(\.id))
        let epoch = thumbnailEpoch
        let live = thumbnailLiveEpoch
        thumbnailQueue.async { [weak self] in
            let start = PerfLog.now()
            for first in stride(from: 0, to: looks.count, by: 8) {
                guard live.with({ $0 }) == epoch else { return }
                let row = Array(looks[first..<min(first + 8, looks.count)])
                let images = ThumbnailBake.images(from: base, looks: row)
                DispatchQueue.main.async {
                    guard let self, self.thumbnailEpoch == epoch else { return }
                    self.thumbnails.merge(images)
                }
            }
            PerfLog.line(String(format: "thumbnails %d looks in %.1f ms", looks.count, PerfLog.ms(since: start)))
        }
    }

    private func refreshPreviewDate() {
        let day = FrameDateText.string(from: Date())
        guard day != previewDate else { return }
        previewDate = day
        syncParameters()
    }
}
