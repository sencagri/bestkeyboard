import Photos
import UIKit

/// Kontrol Merkezi düğmelerinin işi (uygulama sürecinde, arka planda):
/// Fotoğraflar'daki son ekran görüntüsü → yazı (cihazda) → yapay zeka →
/// Hatırlatıcılar / Takvim → bildirim. Düğme kendi başına ekran görüntüsü
/// alamıyor (iOS izin vermiyor); kullanıcı önce alıyor, sonra düğmeye basıyor.
enum ControlRunner {
    /// Bu kadar eski görüntü "son" sayılmıyor — yanlış resim işlenmesin.
    static let maxAge: TimeInterval = 15 * 60
    private static let photosNeededKey = AppGroup.Key.photosNeeded

    @MainActor static func install() {
        ControlActions.handler = { action in
            switch action {
            case .dictation:
                if let url = DeepLink.url(.dictation) { await UIApplication.shared.open(url) }
            case .screenshotReminder: await run(event: false)
            case .screenshotEvent: await run(event: true)
            }
        }
    }

    #if DEBUG
    /// `-controlRun reminder|event`: düğmeye basılmış gibi (simülatörde Kontrol Merkezi yok).
    @MainActor static func runIfRequested() {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-controlRun"), i + 1 < a.count else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await run(event: a[i + 1] == "event")
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
            AILog.recordFailure(origin: .control, action: "Kontrol Merkezi düğmesi", source: p.action,
                                detail: "Basış eklentide kaldı ve uygulama \(AppGroup.handoffTTLText) içinde açılmadı; çalıştırılmadı.")
            return
        }
        AILog.recordFailure(origin: .control, action: "Kontrol Merkezi düğmesi", source: p.action,
                            detail: "Düğme eklentide çalıştı; iş uygulama açılınca tamamlanıyor.", status: .dismissed)
        Task {
            switch action {
            case .screenshotReminder: await run(event: false, asOf: p.date)
            case .screenshotEvent: await run(event: true, asOf: p.date)
            case .dictation: await ControlActions.handler?(action)
            }
        }
    }

    /// Uygulama öne gelince: düğme izin isteyemediyse burada iste.
    @MainActor static func requestPhotosIfNeeded() {
        guard UserDefaults.standard.bool(forKey: photosNeededKey) else { return }
        UserDefaults.standard.removeObject(forKey: photosNeededKey)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
    }

    /// Kontrol Merkezi düğmesi: sonuç ve hata bildirimle söyleniyor (düğmenin yazı alanı yok).
    /// - Parameter asOf: basış anı; o andaki son ekran görüntüsü işleniyor.
    @MainActor static func run(event: Bool, asOf: Date = Date()) async {
        do {
            let o = try await perform(event: event, origin: .control, notify: true, asOf: asOf)
            // Ekleme bildirimini makerlar gönderdi; yönlendirme notu ayrıca (Things → Hatırlatıcılar gibi).
            if let note = o.note { await Notifier.shared.post(title: "Not", body: note, url: nil) }
        } catch {
            #if DEBUG
            print("CONTROL-RUN-ERROR", error.localizedDescription)
            #endif
            await Notifier.shared.post(title: "\(event ? "Takvim" : "Hatırlatıcı") eklenemedi",
                                       body: error.localizedDescription, url: nil)
        }
    }

    /// İşin kendisi; Siri de bunu çağırıyor.
    @MainActor static func perform(event: Bool, origin: AILog.Origin, notify: Bool,
                                   asOf: Date = Date()) async throws -> StructuredFlow.Outcome {
        let kind: AIAction.Kind = event ? .event : .reminder
        let action = "Görüntüden · " + kind.title, source = AILog.Source.latestScreenshot
        let text: String
        do {
            text = try await TextRecognizer.requireText(in: try await latestScreenshot(asOf: asOf), what: "Son ekran görüntüsünde")
        } catch {
            // Yapay zekaya varmadan düştü (izin, görüntü yok, yazı yok): günlükte de görünsün.
            AILog.recordFailure(origin: origin, action: action, source: source, detail: error.localizedDescription)
            throw error
        }
        return try await StructuredFlow.run(kind, text: text, actions: KeyboardSettingsStore.load().aiActions,
                                            origin: origin, action: action, source: source, notify: notify)
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
            throw IntentError.message("Fotoğraflar izni gerekli: BestKeyboard'u bir kez aç ve izin ver (ya da Ayarlar › BestKeyboard › Fotoğraflar).")
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
