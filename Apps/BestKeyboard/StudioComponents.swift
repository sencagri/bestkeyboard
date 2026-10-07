import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

/// Stüdyo öğesinin küçük resmi — çıkartma şeffaf zeminde, GIF dolu.
struct MediaThumb: View {
    let item: MediaStore.Item
    var height: CGFloat
    var radius: CGFloat = 12
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let t = MediaStore.thumbnail(item) {
                    if item.kind == .gif { Image(uiImage: t).resizable().scaledToFill() }
                    else { Image(uiImage: t).resizable().scaledToFit().padding(4) }
                } else { BK.line }
            }
            .frame(maxWidth: .infinity).frame(height: height).clipped()
            .background(item.kind == .sticker ? BK.ground : .clear)
            if item.kind == .gif, height >= 60 {
                Text("GIF").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { c, s in
            let n: CGFloat = 12
            for y in stride(from: 0, to: s.height, by: n) {
                for x in stride(from: 0, to: s.width, by: n) where (Int(x / n) + Int(y / n)) % 2 == 0 {
                    c.fill(Path(CGRect(x: x, y: y, width: n, height: n)), with: .color(BK.line))
                }
            }
        }
        .background(BK.card)
    }
}

/// Kategori çipleri + "+ Kategori". `allowsAll`: süzgeçte "Tümü" var;
/// yapıcılarda yok (seçilmezse kategorisiz).
struct CategoryPicker: View {
    @Binding var selection: String?
    let allowsAll: Bool
    let tint: BK.Tint
    @State private var categories = MediaStore.categories()
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if allowsAll { chip("Tümü", on: selection == nil) { selection = nil } }
                ForEach(categories, id: \.self) { c in
                    chip(c, on: selection == c) { selection = (selection == c && !allowsAll) ? nil : c }
                }
                Button { adding = true } label: {
                    Text(allowsAll ? "+ Kategori" : "+ Yeni").font(.subheadline.weight(.bold))
                        .foregroundStyle(tint.ink).padding(.horizontal, 12).frame(height: 34)
                        .overlay(Capsule().strokeBorder(tint.ink, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
                .buttonStyle(.plain)
            }
        }
        .alert("Yeni kategori", isPresented: $adding) {
            TextField("ör. Komik, Aile, İş", text: $newName)
            Button("Ekle") {
                MediaStore.addCategory(newName)
                categories = MediaStore.categories()
                let n = newName.trimmed
                if !n.isEmpty { selection = categories.first { $0.trEquals(n) } }
                newName = ""
            }
            Button("Vazgeç", role: .cancel) { newName = "" }
        }
        .onAppear { categories = MediaStore.categories() }
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .white : tint.ink)
                .padding(.horizontal, 14).frame(height: 34)
                .background(on ? tint.ink : tint.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Hazır GIF/çıkartmayı paylaşım sayfasıyla gönderir.
struct SendLink: View {
    let url: URL
    let tint: BK.Tint
    var body: some View {
        ShareLink(item: url) { Label("Gönder — WhatsApp, Mesajlar…", systemImage: "square.and.arrow.up") }
            .buttonStyle(.bkTinted(tint))
    }
}
