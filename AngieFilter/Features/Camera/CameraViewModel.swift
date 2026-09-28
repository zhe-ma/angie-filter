import Combine
import CoreImage
import SwiftUI

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var status = CameraStatus()
    @Published var aspectRatio: AspectRatio = .fourThree
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
    @Published var isSaving = false
    @Published var focusPoint: CGPoint?
    @Published var thumbnails: [Look.ID: UIImage] = [:]
    @Published var banner: String?
    @Published var showZoomReadout = false

    let looks = LookLibrary.looks
    let session = CameraSessionController()

    private var savedAdjustments: [Look.ID: LookAdjustment] = [:]
    private var thumbnailWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var focusClear: Task<Void, Never>?
    private var zoomHide: Task<Void, Never>?
    private var dayTimer: Timer?
    private var previewDate = FrameDateText.string(from: Date())
    private var placeText = ""
    private let places = PlaceReader()
    private var pinchStart: CGFloat = 1
    private var isPinching = false

    init() {
        session.onStatus = { [weak self] status in
            self?.status = status
        }
        session.onPhoto = { [weak self] image in
            self?.reviewImage = image
            self?.closeFilters()
            self?.frameOpen = false
        }
        session.onFailure = { [weak self] message in
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
            self.placeMissing = self.frame.showsPlace && self.frame.style == .captioned
            self.syncParameters()
        }
        syncParameters()
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

    func cycleAspect() {
        aspectRatio = aspectRatio.next()
        syncParameters()
    }

    func cycleFlash() {
        guard status.facing == .back else { return }
        session.setFlash(status.flashMode.next())
    }

    func flipCamera() {
        let next: CameraFacing = status.facing == .back ? .front : .back
        session.setFacing(next)
    }

    var previewWidthOverHeight: CGFloat {
        let photo = aspectRatio.widthOverHeight
        guard frame.drawsBorder else { return photo }
        return FrameLayout.outerWidthOverHeight(photoWidthOverHeight: photo)
    }

    func photoRect(in size: CGSize) -> CGRect {
        guard frame.drawsBorder else { return CGRect(origin: .zero, size: size) }
        let fractions = FrameLayout.fractions(photoWidthOverHeight: aspectRatio.widthOverHeight)
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
        refreshThumbnails()
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
        filtersOpen.toggle()
        if filtersOpen {
            familyID = LookLibrary.family(containing: lookID).id
            refreshThumbnails()
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshThumbnails()
                }
            }
        } else {
            closeFilters()
        }
    }

    func closeFilters() {
        filtersOpen = false
        adjustOpen = false
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func toggleFrame() {
        if frameOpen {
            frameOpen = false
            return
        }
        if filtersOpen { closeFilters() }
        frameOpen = true
    }

    func dismissPanels() {
        frameOpen = false
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
        let next = FrameSettings.limited(text)
        guard next != frame.customText else { return }
        frame.customText = next
        syncParameters()
    }

    func focus(viewPoint: CGPoint, in size: CGSize, displayPoint: CGPoint) {
        guard size.width > 1, size.height > 1 else { return }
        let x = min(max(viewPoint.x / size.width, 0), 1)
        let y = min(max(viewPoint.y / size.height, 0), 1)
        let devicePoint = status.facing == .front
            ? CGPoint(x: y, y: x)
            : CGPoint(x: y, y: 1 - x)
        focusPoint = displayPoint
        session.focus(atDevicePoint: devicePoint)
        focusClear?.cancel()
        focusClear = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            focusPoint = nil
        }
    }

    func pinchChanged(_ scale: CGFloat) {
        guard status.facing == .back else { return }
        if !isPinching {
            isPinching = true
            pinchStart = status.zoomFactor
        }
        session.setZoom(factor: pinchStart * scale)
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
        session.setZoom(factor: stop.factor)
        showZoomReadout = true
        pinchEnded()
    }

    func capture() {
        session.capturePhoto()
    }

    func retake() {
        reviewImage = nil
    }

    func save() {
        guard let reviewImage, !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await PhotoLibraryStore.save(reviewImage)
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

    private func syncParameters() {
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
        }
    }

    private func refreshPlaceTracking() {
        let wants = frame.showsPlace && frame.style == .captioned
        if wants {
            placeMissing = placeText.isEmpty
            places.start()
        } else {
            places.stop()
            placeMissing = false
        }
    }

    private func refreshThumbnails() {
        guard filtersOpen, let source = session.currentThumbnailSource() else { return }
        thumbnailWork?.cancel()
        let looks = visibleLooks
        var work: DispatchWorkItem?
        work = DispatchWorkItem {
            let context = CIContext(options: [
                .cacheIntermediates: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
            ])
            var images: [Look.ID: UIImage] = [:]
            for look in looks {
                if work?.isCancelled == true { return }
                let graded = GradeApplicator.apply(
                    source,
                    look: look,
                    adjustment: .baseline(for: look),
                    quality: .preview
                )
                let extent = graded.extent.integral
                guard extent.width > 1, let cgImage = context.createCGImage(graded, from: extent) else { continue }
                images[look.id] = UIImage(cgImage: cgImage)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, work?.isCancelled == false else { return }
                var merged = self.thumbnails
                for (id, image) in images {
                    merged[id] = image
                }
                self.thumbnails = merged
            }
        }
        thumbnailWork = work
        if let work {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    private func refreshPreviewDate() {
        let day = FrameDateText.string(from: Date())
        guard day != previewDate else { return }
        previewDate = day
        syncParameters()
    }
}
