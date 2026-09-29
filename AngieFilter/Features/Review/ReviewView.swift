import PhotosUI
import SwiftUI

struct ReviewView: View {
    let image: UIImage
    let live: LiveReview
    let isSaving: Bool
    var onRetake: () -> Void
    var onSave: () -> Void

    private var liveProcessing: Bool {
        if case .processing = live { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            picture
                .aspectRatio(image.size, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) { liveBadge.padding(10) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 12) {
                Button(action: onRetake) {
                    Text("重拍")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(CameraPalette.tray, in: Capsule())
                }
                Button(action: onSave) {
                    Text(isSaving ? "保存中" : liveProcessing ? "实况处理中" : "保存")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.white.opacity(liveProcessing ? 0.5 : 1), in: Capsule())
                }
                .disabled(isSaving || liveProcessing)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private var picture: some View {
        if case .ready(let files) = live {
            LivePhotoPlayer(files: files, placeholder: image)
                .id(files.movie)
        } else {
            Image(uiImage: image)
                .resizable()
        }
    }

    @ViewBuilder
    private var liveBadge: some View {
        switch live {
        case .none:
            EmptyView()
        case .processing:
            badge {
                ProgressView().controlSize(.mini).tint(.white)
                Text("实况")
            }
        case .ready:
            badge {
                Image(systemName: "livephoto")
                Text("实况 · 长按播放")
            }
        case .failed:
            badge {
                Image(systemName: "livephoto.slash")
                Text("仅照片")
            }
        }
    }

    private func badge(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 5) { content() }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
    }
}

/// The system Live Photo view: press and hold to play, with the same feel as Photos.
/// Loading from the two files also checks that they pair.
private struct LivePhotoPlayer: UIViewRepresentable {
    let files: LivePhotoFiles
    let placeholder: UIImage

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        PHLivePhoto.request(
            withResourceFileURLs: [files.photo, files.movie],
            placeholderImage: placeholder,
            targetSize: .zero,
            contentMode: .aspectFit
        ) { [weak view] livePhoto, info in
            guard let view, let livePhoto else { return }
            view.livePhoto = livePhoto
            let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
            if !degraded {
                view.startPlayback(with: .hint)
            }
        }
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {}
}
