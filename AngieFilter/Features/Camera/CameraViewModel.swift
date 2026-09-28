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
    private var pinchStart: CGFloat = 1
    private var isPinching = false

    init() {
        session.onStatus = { [weak self] status in
            self?.status = status
        }
        session.onPhoto = { [weak self] image in
            self?.reviewImage = image
            self?.closeFilters()
        }
        session.onFailure = { [weak self] message in
            self?.banner = message
        }
        syncParameters()
        session.start()
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

    func focus(viewPoint: CGPoint, in size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let x = min(max(viewPoint.x / size.width, 0), 1)
        let y = min(max(viewPoint.y / size.height, 0), 1)
        let devicePoint = status.facing == .front
            ? CGPoint(x: y, y: x)
            : CGPoint(x: y, y: 1 - x)
        focusPoint = viewPoint
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
        }
    }

    private func refreshThumbnails() {
        guard filtersOpen, let source = session.currentThumbnailSource() else { return }
        thumbnailWork?.cancel()
        let looks = visibleLooks
        let work = DispatchWorkItem {
            let context = CIContext(options: [
                .cacheIntermediates: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
            ])
            var images: [Look.ID: UIImage] = [:]
            for look in looks {
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
                guard let self else { return }
                var merged = self.thumbnails
                for (id, image) in images {
                    merged[id] = image
                }
                self.thumbnails = merged
            }
        }
        thumbnailWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
}
