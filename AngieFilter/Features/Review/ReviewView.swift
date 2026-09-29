import SwiftUI

struct ReviewView: View {
    let image: UIImage
    let isSaving: Bool
    var onRetake: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
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
    }
}
