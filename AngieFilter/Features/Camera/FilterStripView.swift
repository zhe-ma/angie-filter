import SwiftUI

struct FilterStripView: View {
    let looks: [Look]
    let familyID: String
    let selectedID: Look.ID
    let thumbnails: [Look.ID: UIImage]

    var onSelect: (Look) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(looks) { look in
                        Button {
                            onSelect(look)
                        } label: {
                            VStack(spacing: 6) {
                                thumbnail(for: look)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedID == look.id ? Color.white : Color.white.opacity(0.16), lineWidth: selectedID == look.id ? 2 : 1)
                                    }
                                Text(look.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(selectedID == look.id ? Color.white : Color.white.opacity(0.55))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(look.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear {
                scroll(proxy, to: selectedID)
            }
            .onChange(of: selectedID) { _, id in
                withAnimation {
                    scroll(proxy, to: id)
                }
            }
            .onChange(of: familyID) { _, _ in
                let target = looks.contains { $0.id == selectedID } ? selectedID : looks.first?.id
                if let target {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: Look.ID) {
        guard looks.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id, anchor: .center)
    }

    @ViewBuilder
    private func thumbnail(for look: Look) -> some View {
        if let image = thumbnails[look.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color.white.opacity(0.12)
        }
    }
}
