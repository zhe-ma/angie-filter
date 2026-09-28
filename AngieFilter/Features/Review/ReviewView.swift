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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("重拍", action: onRetake)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                Spacer()
                Button(isSaving ? "保存中" : "保存", action: onSave)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(Color.white, in: Capsule())
                    .disabled(isSaving)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .padding(.top, 12)
        }
        .background(Color.black)
    }
}
