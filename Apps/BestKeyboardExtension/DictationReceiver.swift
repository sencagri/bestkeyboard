import Foundation

/// Uygulamanın dikte ekranından gelen metnin klavyedeki alıcısı.
///
/// Uygulama adadan "Bitti — yaz" deyince klavye zaten açık olabilir;
/// `viewWillAppear` gelmez. Darwin bildirimi süreçler arası tek sinyal.
/// Metnin kendisi `DictationHandoff`'ta (ortak klasör, atomik sahiplenme).
final class DictationReceiver {
    private var observing = false
    private let onSignal: () -> Void

    init(onSignal: @escaping () -> Void) { self.onSignal = onSignal }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
    }

    func start() {
        guard !observing else { return }
        observing = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DictationReceiver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.onSignal() }
            },
            DictationHandoff.notification as CFString, nil, .deliverImmediately)
    }

    /// Neden yazılmadığı (Tam Erişim, parola alanı, klavye ekranda değil) ya
    /// da `nil` — yazılabilir.
    static func blocker(fullAccess: Bool, secureField: Bool, onScreen: Bool) -> String? {
        !fullAccess ? "Tam Erişim kapalı; metin bekliyor."
            : secureField ? "Şifre alanı; metin bekliyor."
            : !onScreen ? "Klavye ekranda değil; metin bekliyor." : nil
    }

    /// Aktarım da günlükte ("Sesle yazma · Klavye") — ulaşmadığında nedeni görünsün.
    static func log(_ text: String, status: AILog.Status, detail: String) {
        AILog.record(origin: .keyboard, action: "Sesle yazma", source: AILog.Source.dictationScreen, text: text,
                     provider: "Telefon", model: "Konuşma tanıma", status: status, detail: detail)
    }
}
