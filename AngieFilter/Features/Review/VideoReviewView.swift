import AVFoundation
import SwiftUI

/// The recorded clip loops with sound, already graded and framed, then goes to Photos or is thrown away.
struct VideoReviewView: View {
    let url: URL
    let isSaving: Bool
    var onRetake: () -> Void
    var onSave: () -> Void

    @State private var aspect: CGFloat = 3.0 / 4.0

    var body: some View {
        VStack(spacing: 0) {
            LoopingPlayer(url: url)
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    Text(isSaving ? "保存中" : "保存")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.white, in: Capsule())
                }
                .disabled(isSaving)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: url) {
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize), size.height > 0 else { return }
            aspect = size.width / size.height
        }
    }
}

private struct LoopingPlayer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        player.play()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        uiView.playerLayer.player?.pause()
        uiView.playerLayer.player = nil
        coordinator.looper = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
