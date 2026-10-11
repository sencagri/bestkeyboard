import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

struct ThemesView: View {
    let model: KeyboardSettingsModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                             count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(ThemeChoice.allCases, id: \.rawValue) { choice in
                            themeTile(choice)
                        }
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("screen.scroll")
        }
        .bkScreen("Temalar")
    }

    private func themeTile(_ choice: ThemeChoice) -> some View {
        var s = model.settings
        s.theme = choice
        let on = model.theme == choice
        let custom = ThemeSpec.find(id: choice.rawValue).flatMap { $0.isCustom ? $0 : nil }
        let captionLayout = custom != nil || dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
        return Button { model.theme = choice } label: {
            VStack(spacing: 0) {
                GeometryReader { g in
                    ScaledKeyboardPreview(settings: s, scheme: scheme, width: g.size.width)
                }
                .aspectRatio(ThemedKeyboardPreview.width / ThemedKeyboardPreview.height(s), contentMode: .fit)
                captionLayout {
                    Text(choice.title).font(.subheadline.weight(.bold)).foregroundStyle(BK.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let custom {
                        NavigationLink("Düzenle") { ThemeEditorView(model: model, editing: custom) }
                            .font(.footnote.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(minHeight: 44)
                            .accessibilityLabel("\(choice.title) temasını düzenle")
                    } else if on {
                        Image(systemName: "checkmark").font(.subheadline.weight(.heavy)).foregroundStyle(BK.accent)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 40)
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
