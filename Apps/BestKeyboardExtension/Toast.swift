import UIKit

/// Klavyenin üstünde kısa bilgi balonu — klavye ve panellerin **tek** geçici
/// mesaj yolu; aynı süre, aynı görünüm, VoiceOver'a da okunuyor.
@MainActor
final class Toast {
    static var duration: TimeInterval { PanelUI.messageDuration }

    private let label = UILabel()
    private weak var host: UIView?

    init(in host: UIView) {
        self.host = host
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    func show(_ text: String, theme: KeyboardTheme) {
        guard let host else { return }
        if label.superview == nil {
            host.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: host.topAnchor, constant: 6),
                label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -24),
                label.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            ])
        }
        label.backgroundColor = theme.panelText.withAlphaComponent(0.88)
        label.textColor = theme.panelFace
        label.text = "  \(text)  "
        host.bringSubviewToFront(label)
        label.layer.removeAllAnimations()
        label.alpha = 1
        UIView.animate(withDuration: 0.3, delay: Self.duration, options: [.allowUserInteraction]) {
            self.label.alpha = 0
        }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
