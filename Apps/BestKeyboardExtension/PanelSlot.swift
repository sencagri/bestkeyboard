import UIKit

/// Klavyenin üstünü kaplayan panel (ayarlar, emoji, pano, medya, yapay zeka).
protocol OverlayPanel: UIView {
    func apply(theme: KeyboardTheme)
}

/// Panellerin **tek** yuvası: aynı anda bir panel açık.
///
/// Önce her panelin kendi aç/kapa kopyası vardı ve kopyalar ayrışmıştı:
/// hangisinin hangisini kapattığı panelden panele değişiyordu, açıkken kip
/// değişince yalnız ikisi temayı alıyordu. Yerleşim, tema ve "hangisi açık"
/// artık burada; açılış/kapanışın klavyeye etkisi denetleyicide tek yerde.
@MainActor
final class PanelSlot {
    enum Kind { case settings, emoji, clipboard, media, ai }

    private(set) var kind: Kind?
    private(set) var panel: OverlayPanel?
    private unowned let host: UIView

    init(host: UIView) { self.host = host }

    /// Paneli yerleştirir: üstten `bottom`'a kadar, tam genişlik.
    func show(_ kind: Kind, _ panel: OverlayPanel, bottom: NSLayoutYAxisAnchor) {
        precondition(self.panel == nil, "önce açık panel kapatılmalı")
        panel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: host.topAnchor),
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottom),
        ])
        self.kind = kind
        self.panel = panel
    }

    /// - Returns: kapanan panelin türü; açık panel yoksa `nil`.
    @discardableResult
    func close() -> Kind? {
        guard let kind else { return nil }
        panel?.removeFromSuperview()
        panel = nil
        self.kind = nil
        return kind
    }

    func apply(theme: KeyboardTheme) { panel?.apply(theme: theme) }

    /// Açık panel bu türdense o.
    func current<T: OverlayPanel>(_ type: T.Type) -> T? { panel as? T }
}

extension KeyboardSettingsPanel: OverlayPanel {}
extension EmojiPanel: OverlayPanel {}
extension ClipboardPanel: OverlayPanel {}
extension MediaPanel: OverlayPanel {}
extension AIPanel: OverlayPanel {}
