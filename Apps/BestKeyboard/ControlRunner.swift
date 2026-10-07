import Photos
import UIKit

/// Kontrol Merkezi düğmelerinin işi (uygulama sürecinde, arka planda):
/// Fotoğraflar'daki son ekran görüntüsü → yazı (cihazda) → yapay zeka →
/// Hatırlatıcılar / Takvim → bildirim. Düğme kendi başına ekran görüntüsü
/// alamıyor (iOS izin vermiyor); kullanıcı önce alıyor, sonra düğmeye basıyor.
enum ControlRunner {
    /// Bu kadar eski görüntü "son" sayılmıyor — yanlış resim işlenmesin.
    static let maxAge: TimeInterval = 15 * 60
    /// Düğme izni arka planda isteyemedi; uygulama öne gelince istenecek
    /// (yalnız bu uygulamanın kaydı, ortak depoya gitmiyor).
    private static let photosNeededKey = "kb.photos.needed"
    /// Günlükte düğmenin kendi kaydı (iş başlamadan).
    private static let buttonLogName = "Kontrol Merkezi düğmesi"

    @MainActor static func install() {
        ControlActions.handler = { action in await run(action) }
    }

    /// Düğmenin işi — basış anında (`asOf`) ya da uygulama açılınca.
    @MainActor static func run(_ action: ControlAction, asOf: Date = Date()) async {
        switch action {
        case .dictation:
            if let url = DeepLink.url(.dictation) { _ = await URLOpener.open(url) }
        case .screenshotReminder: await runScreenshot(.reminder, asOf: asOf)
        case .screenshotEvent: await runScreenshot(.event, asOf: asOf)
        }
    }

    #if DEBUG
    /// `-controlRun reminder|event`: düğmeye basılmış gibi (simülatörde Kontrol Merkezi yok).
    @MainActor static func runIfRequested() {
        guard let which = LaunchArgs.value("-controlRun") else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await run(which == "event" ? .screenshotEvent : .screenshotReminder)
            print("CONTROL-RUN-DONE")
        }
    }
    #endif

    /// Uygulama öne gelince: eklentide kalmış bir basış varsa tamamla (ve günlüğe yaz).
    /// Basış anındaki ekran görüntüsü işleniyor, açılış anındaki değil; süresi
    /// geçen basış çalıştırılmıyor; bağlantı kurulmadan kayıt tüketilmiyor.
    @MainActor static func runPendingIfAny() {
        guard ControlActions.handler != nil, let p = ControlActions.claimPending(),
              let action = ControlAction(rawValue: p.action) else { return }
        guard p.isFresh else {
            AILog.record(origin: .control, action: buttonLogName, source: p.action,
                         detail: "Basış eklentide kaldı ve uygulama \(AppGroup.handoffTTLText) içinde açılmadı; çalıştırılmadı.")
            return
        }
        AILog.record(origin: .control, action: buttonLogName, source: p.action, status: .dismissed,
                     detail: "Düğme eklentide çalıştı; iş uygulama açılınca tamamlanıyor.")
        Task { await run(action, asOf: p.date) }
    }

    /// Uygulama öne gelince: düğme izin isteyemediyse burada iste.
    @MainActor static func requestPhotosIfNeeded() {
        guard UserDefaults.standard.bool(forKey: photosNeededKey) else { return }
        UserDefaults.standard.removeObject(forKey: photosNeededKey)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
    }

    /// Kontrol Merkezi düğmesi: sonuç ve hata bildirimle söyleniyor (düğmenin yazı alanı yok).
    /// - Parameter asOf: basış anı; o andaki son ekran görüntüsü işleniyor.
    @MainActor private static func runScreenshot(_ kind: AIAction.Kind, asOf: Date) async {
        do {
            let o = try await perform(kind, origin: .control, notify: true, asOf: asOf)
            // Ekleme bildirimini makerlar gönderdi; yönlendirme notu ayrıca (Things → Hatırlatıcılar gibi).
            if let note = o.note { await Notifier.shared.post(title: "Not", body: note, url: nil) }
        } catch {
            #if DEBUG
            print("CONTROL-RUN-ERROR", error.localizedDescription)
            #endif
            await Notifier.shared.post(title: "\(kind.title) eklenemedi",
                                       body: error.localizedDescription, url: nil)
        }
    }

    /// İşin kendisi; Siri de bunu çağırıyor.
    @MainActor static func perform(_ kind: AIAction.Kind, origin: AILog.Origin, notify: Bool,
                                   asOf: Date = Date()) async throws -> StructuredFlow.Outcome {
        let action = "Görüntüden · " + kind.title, source = AILog.Source.latestScreenshot
        let text: String
        do {
            text = try await TextRecognizer.requireText(in: try await latestScreenshot(asOf: asOf), what: "Son ekran görüntüsünde")
        } catch {
            // Yapay zekaya varmadan düştü (izin, görüntü yok, yazı yok): günlükte de görünsün.
            AILog.record(origin: origin, action: action, source: source, detail: error.localizedDescription)
            throw error
        }
        return try await StructuredFlow.run(kind, text: text, origin: origin, action: action, source: source, notify: notify)
    }

    /// Son ekran görüntüsü (yoksa son 15 dk'daki son resim).
    static func latestScreenshot(asOf: Date = Date()) async throws -> UIImage {
        // İzin arka planda istenemiyor: Kontrol Merkezi'nden çalışırken pencere
        // çıkmıyor ve istek hiç dönmüyordu (düğme "hiçbir şey yapmıyor" gibiydi).
        // Belirsizse uygulama öne gelince istesin, şimdi söyle.
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined, await UIApplication.shared.applicationState == .active {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            UserDefaults.standard.set(true, forKey: photosNeededKey)
            throw IntentError.message("Fotoğraflar izni gerekli: BestKeyboard'u bir kez aç ve izin ver (ya da \(Permission.settingsPath("Fotoğraflar"))).")
        }
        let since = asOf.addingTimeInterval(-maxAge) as NSDate
        // Basıştan **sonra** alınan görüntü seçilmiyor (başka içerik olurdu).
        let until = asOf as NSDate
        func newest(_ extra: String?) -> PHAsset? {
            let o = PHFetchOptions()
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            o.fetchLimit = 1
            var format = "creationDate >= %@ AND creationDate <= %@"
            var args: [Any] = [since, until]
            if let extra { format += " AND " + extra; args.append(PHAssetMediaSubtype.photoScreenshot.rawValue) }
            o.predicate = NSPredicate(format: format, argumentArray: args)
            return PHAsset.fetchAssets(with: .image, options: o).firstObject
        }
        guard let asset = newest("(mediaSubtypes & %d) != 0") ?? newest(nil) else {
            throw IntentError.message("Son \(Int(maxAge / 60)) dakikada ekran görüntüsü yok. Önce ekran görüntüsü al (yan tuş + ses açma), sonra düğmeye bas.")
        }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        let data: Data? = await withCheckedContinuation { c in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { d, _, _, _ in c.resume(returning: d) }
        }
        guard let data, let img = UIImage(data: data) else { throw IntentError.message("Ekran görüntüsü okunamadı.") }
        return img
    }
}
