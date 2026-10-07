import UIKit
import KBGeometry
import KBRuntime

/// Kişisel sözlük bölümü (§8.7): öğrenilen kelimeler, sil, alandan öğren.
extension KeyboardSettingsPanel {
    // MARK: - Kişisel sözlük (§8.7)

    func buildPersonalSection() {
        personalStack.axis = .vertical
        personalStack.spacing = 8
        for v in personalStack.arrangedSubviews {
            personalStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        personalDeleteButtons.removeAll()

        let title = UILabel()
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.text = personalWords.isEmpty
            ? "Kişisel sözlük — boş"
            : "Kişisel sözlük (\(personalWords.count))"
        labels.append(title)
        personalStack.addArrangedSubview(title)

        let hint = UILabel()
        hint.font = .systemFont(ofSize: 12)
        hint.numberOfLines = 0
        hint.text = personalImportNote
            ?? "Sözlükte olmayan bir kelimeyi üç kez yazınca klavye onu öğrenir "
             + "ve bir daha düzeltmez."
        labels.append(hint)
        personalStack.addArrangedSubview(hint)

        // Korpus içe aktarımı: **bu alandaki** metinden öğren.
        //
        // Pano değil: panoyu okumak Tam Erişim istiyor ve iOS her okumada
        // sistem onayı gösteriyor. Alandaki metin zaten kullanıcının önünde ve
        // klavye onu izin almadan görüyor.
        if onImportPersonal != nil {
            let importButton = UIButton(type: .system)
            importButton.setTitle(Self.learnTitle, for: .normal)
            importButton.titleLabel?.font = .systemFont(ofSize: 14)
            importButton.contentHorizontalAlignment = .leading
            importButton.tintColor = theme.controlTint
            importButton.addAction(UIAction { [weak self] _ in self?.learnFromField() }, for: .touchUpInside)
            personalDeleteButtons.append(importButton)   // tema aynı yoldan
            personalStack.addArrangedSubview(importButton)
        }

        if personalWords.isEmpty { return }

        for word in personalWords.prefix(Self.shownPersonalWords) {
            let l = UILabel()
            l.text = word
            l.font = .systemFont(ofSize: 14)
            l.setContentHuggingPriority(.defaultLow, for: .horizontal)
            labels.append(l)

            let del = UIButton(type: .system)
            del.setTitle("sil", for: .normal)
            // Etiket **kelimeyi taşıyor**. Görülen "sil" yazısı yeterli değil:
            // kelime ayrı bir öğede duruyor ve VoiceOver kullanıcısı listede
            // arka arkaya beş tane "sil, düğme" duyuyordu. Hangisinin hangi
            // kelimeye ait olduğu yalnız ekrana bakınca belliydi — ve bu
            // **yıkıcı** bir eylem, yanlış olanı seçmek kelimeyi siliyor.
            del.accessibilityLabel = "\(word) sözcüğünü sil"
            del.titleLabel?.font = .systemFont(ofSize: 14)
            del.tintColor = theme.controlTint
            del.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            del.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onForgetPersonal?(word)
                self.personalWords.removeAll { $0 == word }
                self.buildPersonalSection()
            }, for: .touchUpInside)
            personalDeleteButtons.append(del)

            let row = UIStackView(arrangedSubviews: [l, del])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12
            personalStack.addArrangedSubview(row)
        }

        if personalWords.count > Self.shownPersonalWords {
            let more = UILabel()
            more.font = .systemFont(ofSize: 12)
            more.text = SettingsFormat.more(personalWords.count - Self.shownPersonalWords, "kelime")
            labels.append(more)
            personalStack.addArrangedSubview(more)
        }
    }

    /// Alandaki metinden öğren — hızlı düğme ve kelime listesindeki düğme aynı iş.
    func learnFromField() {
        guard let result = onImportPersonal?() else { return }
        personalWords = result.all
        personalImportNote = result.note
        quickNote.text = result.note
        quickNote.isHidden = false
        buildPersonalSection()
    }
}
