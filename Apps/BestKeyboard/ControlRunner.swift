import Photos
import UIKit

/// Kontrol Merkezi düğmelerinin işi (uygulama sürecinde, arka planda):
/// Fotoğraflar'daki son ekran görüntüsü → yazı (cihazda) → yapay zeka →
/// Hatırlatıcılar / Takvim → bildirim. Düğme kendi başına ekran görüntüsü
/// alamıyor (iOS izin vermiyor); kullanıcı önce alıyor, sonra düğmeye basıyor.
enum ControlRunner {
    /// Bu kadar eski görüntü "son" sayılmıyor — yanlış resim işlenmesin.
    static let maxAge: TimeInterval = 15 * 60
    private static let photosNeededKey = "kb.photos.needed"

    @MainActor static func install() {
        ControlActions.handler = { action in
            switch action {
            case .dictation:
                if let url = URL(string: "bestkeyboard://dikte") { await UIApplication.shared.open(url) }
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

    /// Uygulama öne gelince: düğme izin isteyemediyse burada iste.
    @MainActor static func requestPhotosIfNeeded() {
        guard UserDefaults.standard.bool(forKey: photosNeededKey) else { return }
        UserDefaults.standard.removeObject(forKey: photosNeededKey)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
    }

    /// Kontrol Merkezi düğmesi: hata bildirimle söyleniyor (düğmenin yazı alanı yok).
    @MainActor static func run(event: Bool) async {
        do { _ = try await perform(event: event, origin: .control) }
        catch {
            #if DEBUG
            print("CONTROL-RUN-ERROR", error.localizedDescription)
            #endif
            await Notifier.shared.post(title: "\(event ? "Takvim" : "Hatırlatıcı") eklenemedi",
                                       body: error.localizedDescription, url: nil)
        }
    }

    /// İşin kendisi; Siri de bunu çağırıyor. - Returns: kullanıcıya söylenecek özet.
    @MainActor static func perform(event: Bool, origin: AILog.Origin) async throws -> String {
        let img = try await latestScreenshot()
        guard let text = await TextRecognizer.text(in: img), !text.isEmpty else {
            throw IntentError.message("Son ekran görüntüsünde okunabilen yazı yok.")
        }
        let actions = KeyboardSettingsStore.load().aiActions
        if event {
            EventMaker.refreshCalendarNames()
            let template = actions.first { $0.kind == .event }?.prompt ?? ""
            let plan = try await AILog.measure(origin: origin, action: "Görüntüden · Takvim", source: "Son ekran görüntüsü",
                                               text: text, summarize: { (p: AIService.EventPlan) in p.items.map(\.title).joined(separator: "; ") }) {
                try await AIService.events(from: text, template: template)
            }.value
            let cal = try await EventMaker.add(plan)   // bildirimi kendisi gönderiyor
            let items = plan.items.map { $0.title + " · " + $0.start.formatted(date: .abbreviated, time: $0.allDay ? .omitted : .shortened) }
            return "Takvime eklendi · \(cal)\n" + items.joined(separator: "\n")
        } else {
            await ReminderMaker.refreshListNames()
            let template = actions.first { $0.kind == .reminder }?.prompt ?? ""
            let plan = try await AILog.measure(origin: origin, action: "Görüntüden · Hatırlatıcı", source: "Son ekran görüntüsü",
                                               text: text, summarize: { (p: AIService.ReminderPlan) in "\(p.items.count) madde" }) {
                try await AIService.reminders(from: text, template: template)
            }.value
            let list = try await ReminderMaker.add(plan)
            let head = plan.items.count > 1 ? "\(plan.items.count) madde eklendi · \(list)" : "Eklendi · \(list)"
            return head + "\n" + plan.items.map(\.title).joined(separator: "\n")
        }
    }

    /// Son ekran görüntüsü (yoksa son 15 dk'daki son resim).
    static func latestScreenshot() async throws -> UIImage {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            UserDefaults.standard.set(true, forKey: photosNeededKey)
            throw IntentError.message("Fotoğraflar izni gerekli: BestKeyboard'u bir kez aç ve izin ver (ya da Ayarlar › BestKeyboard › Fotoğraflar).")
        }
        let since = Date().addingTimeInterval(-maxAge) as NSDate
        func newest(_ extra: String?) -> PHAsset? {
            let o = PHFetchOptions()
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            o.fetchLimit = 1
            var format = "creationDate >= %@"
            var args: [Any] = [since]
            if let extra { format += " AND " + extra; args.append(PHAssetMediaSubtype.photoScreenshot.rawValue) }
            o.predicate = NSPredicate(format: format, argumentArray: args)
            return PHAsset.fetchAssets(with: .image, options: o).firstObject
        }
        guard let asset = newest("(mediaSubtypes & %d) != 0") ?? newest(nil) else {
            throw IntentError.message("Son 15 dakikada ekran görüntüsü yok. Önce ekran görüntüsü al (yan tuş + ses açma), sonra düğmeye bas.")
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
