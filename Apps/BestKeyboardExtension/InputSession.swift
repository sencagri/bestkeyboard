import UIKit
import KBGeometry
import KBSpatial
import KBLexicon
import KBRuntime
import KBLearning
import KBAssembly
import KBSessions
import KBFoundation

/// Oturumun belgeye ve alana açılan penceresi.
@MainActor
protocol InputSessionHost: DocumentEditor {
    /// Alan **parola alanı** mı — orada hiçbir şey tamponlanmıyor.
    var fieldIsSecure: Bool { get }
    /// Alan türü literal'i koruyor mu (§8 `θ = ∞`).
    var fieldProtectsLiteral: Bool { get }
    /// Host'ta zaten duran metin (imleçten önce + sonra).
    var documentBaseline: String { get }
    /// Klavyenin **gerçek** geometrisi.
    func geometrySnapshot() -> CanonicalSession.Geometry
    /// Belgeye kendi düzenlememiz — host uzlaştırması o sırada çalışmıyor.
    func withOwnEdit<T>(_ body: () -> T) -> T
}

/// Klavyenin **girdi oturumu**: kaydedici, yedek yol ve aralarındaki geçiş
/// kuralları tek yerde.
///
/// Önce bunların hepsi `KeyboardViewController`'daydı ve denetleyicinin her
/// köşesinde `input ?? fallback` seçimi tekrar ediyordu — bir yerde yalnız
/// kaydedici sorulunca bozulmuş durumda dokunulan öneri no-op oluyordu.
/// Denetleyici artık yalnız bu nesneye soruyor; hangi yolun yazdığı burada
/// kararlaştırılıyor.
///
/// ## İki yol
///
/// - **Kaydedici** (`ProductionRecorder`): normal durum, tek mutasyon noktası
///   motorda ve her eylem kayda geçiyor.
/// - **Yedek** (`InputCoordinator`): paket yüklenemezse, parola alanında,
///   VoiceOver açıkken ya da kayıt bozulunca. Aynı motoru ve sözlüğü
///   kullanıyor — bozulmuş durumda klavye başka bir klavye olmamalı.
@MainActor
final class InputSession {
    unowned let host: any InputSessionHost
    /// Kalibrasyonun kalıcılığı — canlı öğrenici motorla birlikte yaşıyor.
    let calibration = CalibrationPersistence()

    private(set) var layout: KeyLayout
    private var metrics: KeyboardMetrics

    /// `nil` = kayıt yok (paket bekleniyor, askıda ya da bozuldu).
    private var recorder: ProductionRecorder?
    /// Yedek koordinatör — `init`'te layout ile **aynı** ölçüden kuruluyor.
    private var fallback: InputCoordinator
    /// Kaydın neden olmadığı — durum satırında ve düğmede söyleniyor.
    private(set) var failure: String?
    /// Yüklenen paketler — kaydediciyi yeniden başlatmak için saklanıyor.
    private var loadedPacks: PackLoader.Loaded?
    /// Kaydedici token sınırı bekliyor.
    private var pendingStart = false
    /// Güvenli alan yüzünden kapatıldı mı.
    ///
    /// Ayrı bir bayrak: gerçek bir hata (paket yüklenemedi) ile geçici bir
    /// askıya alma aynı şey değil ve ikisini karıştırmak, alandan çıkınca
    /// kaydın hiç dönmemesine yol açıyordu.
    private var suspendedForSecureField = false
    /// Son biten dokunmanın kimliği — harf zarfı ona atıf yapıyor.
    private(set) var lastTouchID: Int?
    /// Yedek yolda son dokunma noktası — uzamsal kanıt yine gerçek.
    private var lastFallbackPoint = Point(x: 0.5, y: 0.5)

    init(host: any InputSessionHost, layout: KeyLayout, metrics: KeyboardMetrics) {
        self.host = host
        self.layout = layout
        self.metrics = metrics
        self.fallback = InputCoordinator(layout: layout)
    }

    /// Kaydın motoru — yalnız durum okumaları için.
    var engine: RecordingEngine? { recorder?.engine }

    /// Kayıtların yazıldığı dizin — uzantının **kendi** konteyneri.
    ///
    /// Uygulamanınkiyle paylaşmak app group gerektiriyor, o da klavyeye
    /// "Full Access" verdirir (ağ erişimi + iOS'un uyarısı). Gerekmiyor:
    /// `devicectl` uzantının konteynerine erişebiliyor ve `pull-sessions.sh`
    /// oradan çekiyor.
    static var captureDirectory: URL? { RecordingLibrary.directory }

    private static var personalDirectory: URL? {
        LocalStore.url(LocalStore.Name.personal, isDirectory: true)
    }

    // MARK: - Okumalar (yazan yol hangisiyse)

    var isComposing: Bool { engine?.isComposing ?? fallback.session.isComposing }

    /// Klavyenin o an bildiği kişisel kelimeler.
    var personalWords: [String] { (engine?.personal ?? fallback.personal).admitted }

    /// Çubukta gösterilecek yüzeyler — bozulmuş durumda da: boş çubuk "aday
    /// yok" demek olurdu, oysa yalnız kayıt yok.
    func suggestionSurfaces() -> [String] {
        engine?.suggestionSurfaces() ?? fallback.suggestionSurfaces()
    }

    /// Çubukta görünen bir yüzeyin **motordaki** önerisi (kimlik ve kaynakla).
    ///
    /// Kaydedici bozuksa yedekten aranıyor: eskiden yalnız motor sorulduğu
    /// için çubukta görünen adaya dokunmak no-op oluyordu.
    func suggestion(for surface: String) -> InputCoordinator.Suggestion? {
        let shown = engine?.visibleSuggestions() ?? fallback.suggestions()
        return shown.first(where: { $0.surface == surface })
    }

    var selectionHasRealEvidence: Bool { engine?.selectionHasRealEvidence == true }

    // MARK: - Yaşam döngüsü

    /// Paketler geldi: kaydedici kuruluyor, kaydedilmiş kalibrasyon motora
    /// uygulanıyor ve deneme devrediliyor (snapshot artık motoru anlatmıyor).
    func didLoad(_ loaded: PackLoader.Loaded) {
        start(with: loaded)
        // Profil layout sırasında, motordan ÖNCE kurulmuştu; kaydedilmiş
        // kalibrasyon ancak burada uygulanabilir.
        if let engine { calibration.engineDidLoad(engine) }
        rollOver()
    }

    /// Geometri değişti: **yeni bir deneme**.
    ///
    /// Tampondaki dokunmalar eski normalize uzayda kaydedildi ve onları yeni
    /// tuş merkezleriyle aynı kayda koymak, iki farklı klavyeyi tek dosyada
    /// anlatmak olurdu. Yedek yol da yeni geometriye geçiyor; profil anahtarı
    /// `layout.id`'yi taşıdığı için kalibrasyon da sıfırlanıyor.
    func reset(layout: KeyLayout, metrics: KeyboardMetrics) {
        saveCalibration()          // eski profilin verisi kaybolmasın
        self.layout = layout
        self.metrics = metrics
        recorder = nil
        fallback = InputCoordinator(layout: layout)
        calibration.reset()
    }

    /// Klavye kapanıyor: tampon **atılıyor** — bir sonraki açılış başka bir
    /// alanda olabilir. Kalibrasyon **önce** kaydediliyor: motor bırakılınca
    /// kaydedilecek örnek kalmıyordu.
    func suspend() {
        saveCalibration()
        recorder = nil
        suspendedForSecureField = false
    }

    /// Bırakılmış kaydediciyi yeniden kurmayı dener. Kurulum koşulları (güvenli
    /// alan, VoiceOver, token sınırı) `start`'ta — burada tekrarlanmıyor.
    func restart() {
        guard recorder == nil, let loaded = loadedPacks else { return }
        failure = nil
        start(with: loaded)
    }

    /// Token sınırında bekleyen kurulumu karşılar.
    ///
    /// Sınırda kurmak bir gecikme değil doğruluk şartı: token ortasında
    /// kurulan kaydedici, yazılmakta olan kelimenin dokunma kanıtını
    /// göremiyor ve ilk commit'te sayım tutmuyordu.
    func startPendingIfAtBoundary() {
        guard pendingStart, !host.fieldIsSecure, !fallback.session.isComposing else { return }
        restart()
    }

    /// Alan değişti: güvenli alana girildiyse tampon **atılıyor**.
    ///
    /// Yalnız yazmayı durdurmak yetmezdi — o ana kadarki tampon bellekte
    /// kalırdı ve kullanıcı parola alanındayken düğmeye bassa diske düşerdi.
    func dropIfSecure() {
        guard host.fieldIsSecure, recorder != nil else { return }
        recorder = nil
        // Sebep **kaydediliyor**: yoksa güvenli alandan çıkınca kaydın neden
        // kapalı olduğu bilinmez ve "kayıt hazır değil" kalıcı görünürdü.
        failure = "parola alanı"
        suspendedForSecureField = true
    }

    /// Güvenli alandan **çıkıldıysa** kaydı yeniden başlatır.
    func resumeAfterSecureField() {
        guard suspendedForSecureField, !host.fieldIsSecure, recorder == nil else { return }
        suspendedForSecureField = false
        restart()
    }

    /// VoiceOver açıldı ya da kapandı.
    ///
    /// Açılışta kaydedici bırakılıyor; kapanışta geri geliyor. Geri getirme
    /// `start`'a bırakılıyor, koşulları burada tekrarlanmıyor.
    func voiceOverChanged() {
        if UIAccessibility.isVoiceOverRunning {
            if recorder != nil { release(reason: "VoiceOver açık") }
        } else if !suspendedForSecureField {
            restart()
        }
    }

    private func start(with loaded: PackLoader.Loaded) {
        loadedPacks = loaded
        // Güvenli alanda **kurulmuyor**: devam eden bir paket yükü, başarılı
        // bir drop'tan sonra bile kaydediciyi geri getirebiliyordu.
        guard !host.fieldIsSecure else {
            recorder = nil
            suspendedForSecureField = true
            failure = "parola alanı"
            configureFallbackIfIdle(loaded)
            return
        }
        // VoiceOver açıkken **hiç kurulmuyor**. Ekran okuyucuyla yazılan her
        // harf türetilmiş kanıt taşıyor (§8.9) ve kayıt onu bir dokunma olgusu
        // olarak yazamaz. Kayıt yok ama klavye **aynı** klavye: öneri motoru
        // ve kişisel sözlük yedek yola veriliyor.
        guard !UIAccessibility.isVoiceOverRunning else {
            recorder = nil
            failure = "VoiceOver açık"
            configureFallbackIfIdle(loaded)
            return
        }
        // **Token ortasında kurulmuyor.** Yeni koordinatör fallback'in
        // composing'ini taşımıyor: paketler `"kal"` yazılırken gelirse kullanıcı
        // `"em"` için aday görürdü, `"kalem"` için değil. Sınırda kurmak hiçbir
        // şey kaybettirmiyor — o ana kadar zaten kayıt yoktu.
        guard !fallback.session.isComposing else {
            pendingStart = true
            return
        }
        pendingStart = false
        let l = layout, m = metrics
        do {
            recorder = try ProductionRecorder(
                makeDescriptor: { [weak self] id in
                    Self.productionDescriptor(
                        id: id, layout: l, metrics: m,
                        geometry: self?.host.geometrySnapshot()
                            ?? RecordingSnapshot.geometry(layout: l, keyboard: nil, host: UIView()))
                },
                build: { writer in
                    RecordingEngine(writer: writer,
                                    coordinator: InputCoordinator(layout: l),
                                    layout: l)
                },
                configure: { [weak self] engine in
                    try engine.configure(
                        loaded: loaded,
                        // Kayıttan gelen kalibrasyon **yok**: üretimde motor
                        // canlı öğreniciyle kuruluyor (`learner:` aşağıda) ve
                        // snapshot onu okuyor. Bu alan replay yolunun girişi.
                        calibration: .init(applied: false, strongSamples: 0,
                                           biasX: [], biasY: [],
                                           hierarchical: .init(globalX: 0, globalY: 0,
                                                               rowX: [], rowY: [],
                                                               keyX: [], keyY: []),
                                           sigma: .known(.init(x: [], y: []))),
                        // Devretmede koordinatör sıfırdan kuruluyor: sözlük
                        // **her denemede** yeniden veriliyor, yoksa bayt
                        // sınırında kullanıcı kendi kelimelerini kaybederdi.
                        personal: Self.loadPersonalLexicon(),
                        // **Devretme öğrenilmiş sapmayı düşürmemeli.**
                        //
                        // Rezervuar **canlı kopyadan**, diskten değil: son
                        // kaydetmeden sonra biriken örnekler de taşınsın.
                        // `engine` burada okunamaz — devretme sırasında o
                        // çoktan yeni (boş) motoru gösteriyor.
                        learner: self?.calibration.learnerForNewEngine())
                },
                baseline: { [weak self] in
                    // Host'ta zaten duran metin: **fark** buradan hesaplanıyor,
                    // kayda girmiyor. Vermezsek kullanıcının bu dilimde
                    // yazmadığı içerik ilk mutasyona sızıyordu.
                    self?.host.documentBaseline ?? ""
                })
            failure = nil
        } catch {
            recorder = nil
            failure = "\(error)"
        }
        configureFallback(loaded)
    }

    /// Yedek yol da **aynı** motoru ve geometriyi kullanıyor.
    ///
    /// Kişisel sözlük paketlerden gelmiyor: taze kurulan her leksikonun
    /// üstüne **burada** biniyor (kaydedici yolunda o `configure`'ın parçası).
    private func configureFallback(_ loaded: PackLoader.Loaded) {
        fallback = InputCoordinator(layout: layout)
        fallback.setEngine(.init(decoder: loaded.decoder,
                                 literalChannel: loaded.literalChannel,
                                 expansions: loaded.expansions))
        fallback.replacePersonalLexicon(Self.loadPersonalLexicon())
        syncFieldFlags()
    }

    /// Yeni koordinatör yazılmakta olan token'ı taşımıyor: token ortasında
    /// kurulmuyor, sınırda (`start` yeniden çağrılınca) kuruluyor.
    private func configureFallbackIfIdle(_ loaded: PackLoader.Loaded) {
        guard !fallback.session.isComposing else { return }
        configureFallback(loaded)
    }

    /// Üretim denemesinin tanımı — **hedef yok**.
    ///
    /// `alignmentSource: .none`: kullanıcının ne yazmak istediğini yalnız kendisi
    /// biliyor; hizalama `constructed` olmadığı için kalibrasyon kapısı bu
    /// kayıtları eliyor.
    private static func productionDescriptor(id: String, layout: KeyLayout,
                                             metrics: KeyboardMetrics,
                                             geometry: CanonicalSession.Geometry)
        -> CanonicalSession {
        let bundle = Bundle(for: InputSession.self)
        return CanonicalSession(
            attemptID: id, participantID: "device", sessionOrdinal: 0,
            condition: .behavior, status: .recording,
            promptID: "production", promptText: "", promptSource: .manual,
            // **Hedef yok**, boş hedef değil: `.known(["-"])` yazmak olmayan
            // bir hedefi varmış gibi göstermek ve tokenizer kanonikliği
            // (§2.3) o yer tutucuyu haklı olarak reddediyordu.
            split: "none", promptTokens: .notApplicable,
            alignmentSource: .none, startedAt: Date(),
            engine: .unconfigured(
                buildConfiguration: RecordingSnapshot.buildConfiguration,
                appVersion: RecordingSnapshot.appVersion(bundle),
                build: RecordingSnapshot.buildManifest(bundle),
                policy: .init(RecordingPolicy.behavior)),
            geometry: geometry)
    }

    // MARK: - Tek mutasyon noktası

    /// Klavyenin **tek** belge mutasyon yolu.
    ///
    /// - Parameter point: harfin dokunma noktası — yedek yolun uzamsal kanıtı.
    /// - Parameter synthetic: harf bir **erişilebilirlik etkinleştirmesinden**
    ///   geliyor; koordinat gözlem değil, tuş merkezi (§8.9).
    func perform(_ command: ReplayCommand,
                 touch: CanonicalSession.Touch? = nil,
                 point: Point? = nil,
                 touchID: Int? = nil,
                 at time: TimeInterval? = nil,
                 synthetic: Bool = false) {
        // **Güvenli alan kontrolü burada.** `textDidChange` üzerinden düşürmeye
        // güvenmek yetmiyordu: o çağrı proxy'nin henüz güncel olmadığı anda
        // koşuyor. Kontrolü mutasyonun kendisine koymak, tamponun parola
        // karakteri görmesini yapısal olarak imkânsız kılıyor.
        dropIfSecure()
        syncFieldFlags()
        if let point { lastFallbackPoint = point }
        // Türetilmiş harf **kaydedilemez**: kayıt her harfe bir dokunma olgusu
        // bağlamayı şart koşuyor ve elimizde bir dokunma yok. Kaydedici
        // normalde VoiceOver açıkken hiç kurulmuyor; buraya ancak kayıt
        // sürerken VoiceOver açılırsa gelinir.
        if synthetic, recorder != nil {
            release(reason: "VoiceOver açıldı")
        }
        let t = time ?? ProductionRecorder.now
        guard let recorder, let engine else {
            // Kayıt yok ama klavye çalışmak zorunda. Komut kümesi çekirdekte
            // tek yerde (`InputCoordinator.perform`): kayıt, tekrar oynatma ve
            // bu yedek yol aynı dağıtıcıdan geçiyor.
            let sample = TouchSample(down: lastFallbackPoint, timestamp: t)
            host.withOwnEdit {
                _ = try? fallback.perform(command, touch: sample, synthetic: synthetic,
                                          fieldProtectsLiteral: host.fieldProtectsLiteral,
                                          into: host)
            }
            return
        }
        host.withOwnEdit {
            do {
                if let touch { try engine.record(touch) }
                try engine.perform(.init(command: command, touchID: touchID, timestamp: t), into: host)
                // **Devretmeden önce.** Kişisel sözlüğe kabul edilen kelime
                // devretmeyi tetikliyor ve devretme yeni koordinatörün
                // sözlüğünü **diskten** okuyor.
                if engine.wantsPersonalSave {
                    savePersonal()
                    engine.personalSaved()
                }
                // Rezervuarın **canlı** kopyası: devretmede `configure`
                // çağrıldığında `engine` çoktan YENİ motoru gösteriyor.
                calibration.live = engine.calibration
                // Sınıra **eylemden sonra** bakılıyor: ortasında devretmek yarım
                // bir mutasyonu iki denemeye bölerdi.
                try recorder.rollOverIfNeeded()
            } catch {
                // Kayıt bozulursa klavye çalışmaya devam etmeli.
                release(reason: "\(error)")
            }
        }
    }

    /// Klavyenin ürettiği **her** dokunma kayda giriyor.
    ///
    /// Güvenli alanda hiçbir şey tamponlanmıyor: kontrol burada da var, çünkü
    /// dokunma kaydı komuttan bağımsız geliyor.
    func record(_ r: KeyboardView.TouchRecord, shift: String) {
        dropIfSecure()
        guard let engine else { return }
        do { try engine.record(r.canonical(layout: layout, shift: shift)) }
        catch { release(reason: "\(error)") }
        if r.phase == .ended || r.phase == .cancelled {
            lastTouchID = r.touchID
        }
    }

    /// Alan bilgisi **her mutasyonda** motora ve yedek yola bildiriliyor.
    ///
    /// Alan koruması (e-posta, URL, sayı) ile parola alanı **ayrı** olgular:
    /// koruma literal'i düzeltmeden saklıyor, parola alanında ise kişisel
    /// sözlük hiçbir şey öğrenmiyor.
    private func syncFieldFlags() {
        let secure = host.fieldIsSecure
        engine?.fieldProtectsLiteral = host.fieldProtectsLiteral
        engine?.fieldIsSecure = secure
        fallback.fieldIsSecure = secure
    }

    /// Kayda girmeyen bir durum değişikliğinden sonra deneme devrediliyor.
    /// Devretme başarısızsa kaydedici bırakılıyor — `perform`'daki kuralın
    /// aynısı.
    func rollOver() {
        guard let recorder else { return }
        do { try recorder.rollOverIfNeeded() } catch { release(reason: "\(error)") }
    }

    /// Kaydediciyi bırakır ve **sebebini** saklar.
    ///
    /// Yarım kalan token yedek koordinatöre **devrediliyor**: yedek yol boş
    /// başlarsa `kal` yazılmışken gelen `em` tek başına düzeltilebiliyor ve
    /// `kalem` önerisi belgeyi `kalkalem` yapıyordu. Yüzey **ölen oturumdan**
    /// okunuyor (bırakmadan önce), belgeden ayrıştırılarak değil.
    private func release(reason: String) {
        let carried = engine?.composingSurface ?? ""
        recorder = nil
        failure = reason
        fallback.adoptDetachedSurface(carried)
    }

    // MARK: - Kayda girmeyen değişiklikler

    /// Klavye belgeye kendi yolundan başka bir şey yazmadan önce (panel,
    /// kısayol, kart, dikte) yazılmakta olan token kapanıyor ve deneme
    /// devrediliyor. Yedek yol da kapatıyor: önce yalnız kaydedici
    /// kapatılıyordu ve bozulmuş durumda eski token ekleme sonrasına taşınıyordu.
    func closeComposition() {
        host.withOwnEdit {
            if let engine { try? engine.invalidateComposing() } else { fallback.invalidateComposing() }
        }
        rollOver()
    }

    /// İmleç oynadı: yazılmakta olan token'ın belgedeki yeriyle ilgisi kalmadı.
    ///
    /// Kayıt bu hareketi **anlatamıyor**, deneme hemen kapatılıyor.
    /// `withOwnEdit` **yok**: belge değiştirilmiyor, yalnız oturum durumu düşüyor.
    func cursorMoved() {
        if let engine {
            engine.noteStateChangedOutsideTheLog()
            try? engine.invalidateComposing()
        } else {
            fallback.invalidateComposing()
        }
        rollOver()
    }

    /// Belge kaydın anlatmadığı bir yoldan değişti (yapay zeka kartı).
    func editedOutsideLog() {
        engine?.noteStateChangedOutsideTheLog()
        rollOver()
    }

    /// Host seçimi değişti — **hangi koordinatör yazıyorsa** o haberdar ediliyor.
    ///
    /// İkisi birden uyarılmıyor: `handleSelection` seçim varken belgeyi
    /// **değiştiriyor** ve iki koordinatör aynı düzenlemeyi iki kez uygulardı.
    /// Yalnız kaydedici uyarıldığında bozulmuş durumda yedek yolun token'ı
    /// belgede başka bir yeri anlatarak kalıyordu.
    func selectionChanged(_ selected: String?) -> String? {
        let note = host.withOwnEdit { () -> String? in
            if let engine { return (try? engine.selectionChanged(selected, into: host)) ?? nil }
            return fallback.handleSelection(selected, into: host)
        }
        rollOver()
        return note
    }

    // MARK: - Kayıt dilimi

    /// Kullanıcı düğmeye bastı: bellekteki dilim diske düşüyor. Sonuç
    /// kullanıcıya söylenecek cümle.
    func capture() -> String {
        // Güvenli alanda **hiçbir koşulda** yazılmıyor.
        guard !host.fieldIsSecure else { return "parola alanında kayıt yok" }
        guard let recorder, let dir = Self.captureDirectory else {
            // Sebep biliniyorsa söyleniyor: "hazır değil" kullanıcıya beklemek
            // mi başka bir şey yapmak mı gerektiğini bildirmiyor.
            return failure.map { "kayıt yok: \($0)" } ?? "kayıt hazır değil"
        }
        do {
            _ = try recorder.capture(note: nil, to: dir)
            return "kaydedildi ✓"
        } catch {
            return "kaydedilemedi: \(error)"
        }
    }

    // MARK: - Kalibrasyon

    func saveCalibration() { calibration.save(engine) }

    /// Token sınırı: kaydetme isteği ve bekleyen profil değişimi burada
    /// karşılanır (§5b snapshot swap). Profil değiştiyse `true`.
    func calibrationAtBoundary() -> Bool {
        if engine?.wantsCalibrationSave == true {
            saveCalibration()
            engine?.calibrationSaved()
        }
        return !isComposing && calibration.applyPending(engine: engine)
    }

    /// Ölçü değişti: profil isteniyor. Hemen geçildiyse `true`.
    func requestCalibrationProfile(_ key: CalibrationPersistence.ProfileKey) -> Bool {
        calibration.request(key, composing: isComposing, engine: engine)
    }

    // MARK: - Kişisel sözlük kalıcılığı (§8.7)

    /// Diskteki sözlük. Öğrenilen tarafın **kalıcılığı** yalnız kaydedicide —
    /// kalibrasyonla aynı bölüşüm; iki yazar split-brain üretirdi.
    private static func loadPersonalLexicon() -> PersonalLexicon {
        personalDirectory.map { PersonalLexiconStore.loadOrEmpty(from: $0) }
            ?? PersonalLexicon()
    }

    /// Kullanıcının metninden kelime öğrenir; **her iki** yol da öğreniyor.
    func ingestPersonal(tokens: [String]) -> PersonalLexicon.IngestReport {
        let report = engine?.ingestPersonal(tokens: tokens)
        let fallbackReport = fallback.ingestPersonal(tokens: tokens)
        personalLexiconChanged()
        return report ?? fallbackReport
    }

    /// Kullanıcı bir yüzeyi siliyor: **her iki** yoldan da düşüyor ve disk
    /// hemen güncelleniyor.
    func forgetPersonal(_ word: String) {
        engine?.forgetPersonal(word)
        fallback.forgetPersonal(word)
        personalLexiconChanged()
    }

    /// Sözlük kayıt dışı değişti: diske yazılıyor, motora bildiriliyor ve
    /// deneme devrediliyor (yeni koordinatör sözlüğü diskten okuyor).
    private func personalLexiconChanged() {
        savePersonal()
        engine?.personalSaved()
        rollOver()
    }

    /// Boş sözlükte dosya **siliniyor**: son kelime silindiğinde dosyanın
    /// kalması, klavyeyi bir sonraki açışta silinen kelimeyi geri getirirdi.
    private func savePersonal() {
        guard let dir = Self.personalDirectory, let engine else { return }
        if engine.personal.isEmpty {
            try? PersonalLexiconStore.delete(from: dir)
        } else {
            try? PersonalLexiconStore.save(engine.personal, to: dir)
        }
    }
}
