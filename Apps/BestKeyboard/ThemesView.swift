import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

struct ThemesView: View {
    let model: KeyboardSettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(settings: model.settings)
            ScrollView {
                VStack(spacing: 12) {
                    SharedStoreNotice()
                    NavigationLink { ThemeEditorView(model: model) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Kendi temanı oluştur")
                        }
                        .font(.headline).foregroundStyle(BK.pink.ink)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .overlay(RoundedRectangle(cornerRadius: BK.Radius.preview).strokeBorder(BK.pink.ink, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        ForEach(ThemeChoice.allCases, id: \.rawValue) { choice in
                            themeTile(choice)
                        }
                    }
                }
                .padding(16)
            }
        }
        .bkScreen("Temalar")
    }

    private func themeTile(_ choice: ThemeChoice) -> some View {
        var s = model.settings
        s.theme = choice
        let on = model.theme == choice
        return Button { model.theme = choice } label: {
            VStack(spacing: 0) {
                GeometryReader { g in
                    ScaledKeyboardPreview(settings: s, scheme: scheme, width: g.size.width)
                }
                .aspectRatio(ThemedKeyboardPreview.width / ThemedKeyboardPreview.height(s), contentMode: .fit)
                HStack {
                    Text(choice.title).font(.subheadline.weight(.bold)).foregroundStyle(BK.ink).lineLimit(1)
                    Spacer()
                    if let custom = ThemeSpec.find(id: choice.rawValue), custom.isCustom {
                        NavigationLink("Düzenle") { ThemeEditorView(model: model, editing: custom) }
                            .font(.footnote.weight(.semibold))
                    } else if on {
                        Image(systemName: "checkmark").font(.subheadline.weight(.heavy)).foregroundStyle(BK.accent)
                    }
                }
                .padding(.horizontal, 12).frame(height: 40)
            }
            .background(BK.card)
            .clipShape(RoundedRectangle(cornerRadius: BK.Radius.preview, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BK.Radius.preview, style: .continuous)
                .strokeBorder(on ? BK.accent : .clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
