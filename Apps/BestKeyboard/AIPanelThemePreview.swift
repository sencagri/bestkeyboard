import SwiftUI
import KBRuntime

#if DEBUG
/// `-bkScreen yzkart -aiTheme <id> [-panel ai|emoji|pano|medya]`: klavyedeki
/// kartı ve panelleri seçili temayla, klavye önizlemesinin üstünde çizer —
/// simülatörde klavye eklentisinin temasını dışarıdan değiştirmek mümkün değil.
struct AIPanelThemePreview: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let themeID = LaunchArgs.value("-aiTheme") ?? "light", panel = LaunchArgs.value("-panel") ?? "ai"
        let theme = (ThemeSpec.preset(id: themeID) ?? ThemeSpec.preset(id: "light")!).resolved()
        var settings = KeyboardSettings.default
        settings.theme = ThemeChoice(rawValue: themeID)
        return GeometryReader { g in
            VStack(spacing: 0) {
                Spacer()
                if ["ai", "hatirlatici", "takvim", "kisi"].contains(panel) {
                    ZStack(alignment: .top) {
                        BackdropRepresentable(theme: theme).frame(height: 300)
                        PanelRepresentable(theme: theme, kind: panel).frame(height: 300)
                    }
                    ScaledKeyboardPreview(settings: settings, scheme: scheme, width: g.size.width, themeOverride: theme)
                } else {
                    let h = ThemedKeyboardPreview.height(settings) * g.size.width / ThemedKeyboardPreview.width
                    ZStack {
                        BackdropRepresentable(theme: theme)
                        PanelRepresentable(theme: theme, kind: panel)
                    }
                    .frame(height: h)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .bkScreen("\(panel) · \(themeID)")
    }
}

private struct PanelRepresentable: UIViewRepresentable {
    let theme: KeyboardTheme
    let kind: String
    func makeUIView(context: Context) -> UIView {
        switch kind {
        case "emoji":
            return EmojiPanel(theme: theme, recents: EmojiRecents(items: ["😂", "🇹🇷", "❤️", "👍", "🙏", "😊", "🎉", "🔥"]))
        case "pano":
            return ClipboardPanel(items: [], theme: theme)
        case "medya":
            return MediaPanel(theme: theme)
        case "takvim":
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            p.show(.events(calendar: "Ev", rows: [.init(SampleData.meeting)]))
            return p
        case "kisi":
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            let c = SampleData.contact
            p.show(.contact(name: c.displayName, organization: c.organization, phones: c.phones, emails: c.emails))
            return p
        case "hatirlatici":
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            p.show(.reminders(list: "Alışveriş", rows: [("8 yumurta", nil), ("5 kedi maması", nil), ("4 süt", "Yarın 09:00")]))
            return p
        default:
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            p.show(.pick(source: "Are you free tomorrow evening?", label: "Panodan", canSwitch: true))
            return p
        }
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
