import Foundation
import KBGeometry
import KBSpatial
import KBDecoder
import KBLearning

/// Girdi motorunun cephe tipi — plan §Depo yapısı: *"KBRuntime/ InputEngine
/// facade + host senkronizasyonu"*.
///
/// ## Neden var
///
/// Bütün karar mantığı `UIInputViewController` içindeydi ve **hiç test
/// edilemiyordu**: commit kararı (`Δ > θ`), kalibrasyon öğrenmesinin hangi
/// yollarda çalıştığı, seçim kipinin diğerleriyle etkileşimi. Codex'in
/// istediği uçtan uca testi yazamamamın sebebi buydu.
///
/// Uzantı artık ince bir adaptör: dokunmayı iletiyor, sonucu çiziyor. Karar
/// burada ve `swift test` altında koşuyor.
///
/// ## Neyi kapsamaz
///
/// UIKit'e ait olan hiçbir şey: görünüm, zamanlayıcı, `UIInputViewController`
/// yaşam döngüsü, dosya sistemi. Kalibrasyonun **kalıcılığı** da dışarıda —
/// koordinatör öğrenir, saklamayı çağıran yapar.
public struct InputCoordinator {

    /// Kod çözme yeteneği. Protokol olmasının sebebi test değil: paket henüz
    /// yüklenmemişken de klavyenin yazabilmesi gerekiyor (§11.A iki aşamalı
    /// init), yani "decoder yok" meşru bir durum.
    public struct Engine {
        public var decoder: Decoder
        public var literalChannel: LiteralChannel

        public init(decoder: Decoder, literalChannel: LiteralChannel) {
            self.decoder = decoder
            self.literalChannel = literalChannel
        }
    }

    public private(set) var session = ComposingSession()
    public var calibration = CalibrationLearner()

    /// `nil` iken klavye yazar ama öneri üretmez ve düzeltme yapmaz.
    public private(set) var engine: Engine?
    private var incremental: IncrementalDecoder?

    public let layout: KeyLayout

    /// Sözlük dışı literal için commit eşiği (§8.1.1).
    ///
    /// `kbdiag --theta` gerçekçi dokunmalarla ölçtü: bu değerde typo'ların
    /// %82'si düzeliyor, doğru yazılmış sözlük dışı kelimelerin **%0'ı**
    /// bozuluyor. Muhafazakâr uç bilinçli (§5c asimetrisi).
    public var oovTheta = 17.0

    /// Öneri çubuğunda gösterim penceresi — **UI politikası**, skor
    /// sözleşmesinin parçası değil.
    public var suggestionWindow = 3.0

    /// Kaç örnekte bir kalıcılaştırma istenir.
    public var saveEvery = 60
    public private(set) var samplesSinceSave = 0
    /// Çağıranın kalibrasyonu diske yazması gerektiğini bildirir.
    public private(set) var wantsCalibrationSave = false

    public init(layout: KeyLayout) {
        self.layout = layout
    }

    // MARK: - Motor yaşam döngüsü

    public mutating func setEngine(_ e: Engine?) {
        engine = e
        rebuildIncremental()
    }

    /// Öğrenilen sapmayı uzamsal modele işler ve decoder'ı yeniden kurar.
    ///
    /// **Token sınırında** çağrılmalı: uzamsal model değişmesi `modelVersion`
    /// değişmesidir (§5b) ve artımlı beam yalnız model sabitken doğrudur.
    @discardableResult
    public mutating func applyCalibration() -> Bool {
        guard let old = engine else { return false }
        var model = SpatialModel(layout: layout)
        calibration.apply(to: &model)

        var fresh = Decoder(layout: layout, spatial: model,
                            lexicon: old.decoder.lexicon,
                            weights: old.decoder.weights,
                            beamWidth: old.decoder.beamWidth)
        fresh.languageModel = old.decoder.languageModel   // dil durumu korunur
        engine?.decoder = fresh
        rebuildIncremental()
        return true
    }

    // MARK: - Girdi

    public mutating func insertLetter(_ ch: Character, touch: TouchSample,
                                      into editor: DocumentEditor) {
        apply(session.insertLetter(ch, touch: touch, into: editor))
    }

    public mutating func backspaceTap(into editor: DocumentEditor) {
        apply(session.backspaceTap(into: editor))
    }

    public mutating func backspaceRepeat(into editor: DocumentEditor) {
        apply(session.backspaceRepeat(into: editor))
    }

    public mutating func deleteWord(into editor: DocumentEditor) {
        apply(session.deleteWordBackward(into: editor))
    }

    public mutating func newline(into editor: DocumentEditor) {
        // Satır sonunda düzeltme yok: literal doğrudan commit ediliyor,
        // dolayısıyla kaydedilecek dil literal'in dilidir.
        let language = session.display.isEmpty
            ? nil : engine?.literalChannel.score(session.literal).language
        _ = session.finishToken(separator: "\n", into: editor)
        apply(session.invalidate())        // satır sonunu geçen geri dönüş yok
        remember(language: language)
    }

    /// Boşluk — skor sözleşmesi §8'in tek karar fonksiyonu:
    ///
    ///     Δ = cost(literal) − cost(bestCandidate)
    ///     değiştir  ⟺  Δ > θ(literal, ctx)
    public mutating func space(into editor: DocumentEditor,
                               fieldProtectsLiteral: Bool = false) {
        if session.isEditingSelection {
            // Türetilmiş kanıtta **otomatik uygulama yok**: elimizde uzamsal
            // gözlem değil, harflerin tuş merkezleri var. `Δ` gerçek bir parmak
            // kanıtını temsil etmiyor, dolayısıyla `θ` kararı anlamsız.
            let surface = session.selectionHasRealEvidence
                ? warrantedCorrection(fieldProtectsLiteral: fieldProtectsLiteral)
                : nil
            apply(session.commitSelectionEdit(surface, into: editor))
            return
        }

        // Örnekler `finishToken` durumu temizlemeden ÖNCE alınmalı.
        let touches = session.touches
        let literalText = session.literal

        var committedLanguage: UInt8?
        if let s = warrantedCorrection(fieldProtectsLiteral: fieldProtectsLiteral),
           session.replaceDisplay(with: s, into: editor) {
            committedLanguage = bestCandidate()?.language
        } else if !session.display.isEmpty {
            committedLanguage = engine?.literalChannel.score(session.literal).language
        }
        let committedText = session.display
        apply(session.finishToken(separator: " ", into: editor))

        remember(language: committedLanguage)
        // Otomatik commit **zayıf** etikettir: kullanıcı düzeltmeye üşenmiş
        // olabilir, "değiştirmedi" doğruluk kanıtı değildir (plan §3).
        learn(touches: touches, literal: literalText, committed: committedText,
              confidence: .weak)
    }

    /// Kullanıcı öneri çubuğundan bir adaya dokundu.
    public mutating func pickSuggestion(_ word: String, into editor: DocumentEditor) {
        guard !session.isDetached else { return }
        if session.isEditingSelection {
            apply(session.commitSelectionEdit(word, into: editor))
            return
        }
        let touches = session.touches
        let literalText = session.literal
        let language = candidates().first { $0.word == word }?.language

        session.replaceDisplay(with: word, into: editor)
        apply(session.finishToken(separator: " ", into: editor))

        remember(language: language)
        // Kullanıcı öneriye **açıkça dokundu** — hedef kesin biliniyor.
        // Hizalama ancak seçilen kelime literal'e EŞİTSE kayda dayanır;
        // farklıysa `observe` hiçbir şey toplamaz (döngüsellik koruması).
        learn(touches: touches, literal: literalText, committed: word,
              confidence: .strong)
    }

    // MARK: - Seçim

    /// Host'ta bir metin seçildi (ya da seçim kalktı).
    ///
    /// Önce **gerçek** kanıt aranır: kelimeyi bu oturumda biz yazdıysak ve
    /// konumu doğrulanıyorsa kullanıcının kendi dokunmaları kullanılır.
    /// Bulunamazsa yüzeyden **türetilmiş** kanıtla yine öneri üretilir.
    ///
    /// - Returns: seçim düzenleme kipine girildiyse seçilen yüzey.
    @discardableResult
    public mutating func handleSelection(_ selected: String?,
                                         into editor: DocumentEditor) -> String? {
        let trimmed = selected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let sel = selected, !trimmed.isEmpty {
            apply(session.beginEditingSelection(sel, into: editor))

            // Türetilmiş yol yalnız seçimin **kendisi** tek kelimeyse açılır:
            // kırpılmışla açmak, aday uygulanırken `insertText`'in host'un tüm
            // seçimini (kenar boşlukları dahil) değiştirmesine yol açardı.
            if !session.isEditingSelection, sel == trimmed,
               let ts = syntheticTouches(for: sel) {
                apply(session.beginEditingSelectionSynthetic(sel, touches: ts))
            }
            return session.isEditingSelection ? sel : nil
        }

        if session.isEditingSelection {
            apply(session.endEditingSelection())
            return nil
        }

        // İmleç taşındıysa hangi karakterlerin bizim token'ımıza ait olduğunu
        // artık bilmiyoruz — ama **ne yazdığımızı** biliyoruz. Geçmiş korunur
        // (§8.4: çift dokunuşun ilk dokunuşu geçmişi siliyordu).
        if !session.agreesWithHost(editor) {
            apply(session.invalidateComposing())
        }
        return nil
    }

    // MARK: - Öneriler

    public func candidates(topK: Int = 3) -> [DecodeResult] {
        guard let inc = incremental, !session.touches.isEmpty else { return [] }
        return inc.results(topK: topK)
    }

    /// Gösterilecek adaylar — kazanandan çok geride kalanlar elenir.
    public func shownCandidates() -> [DecodeResult] {
        let r = candidates()
        guard let best = r.first else { return [] }
        return r.filter { $0.cost - best.cost <= suggestionWindow }
    }

    // MARK: - Commit kararı

    private func bestCandidate() -> DecodeResult? { candidates(topK: 1).first }

    /// Uygulanması gereken düzeltme, yoksa `nil`.
    private func warrantedCorrection(fieldProtectsLiteral: Bool) -> String? {
        // Kanıtı kopmuş token'a dokunulmaz: elde yüzeyin tamamını değil yalnız
        // bir parçasını açıklayan dokunmalar var.
        guard !session.isDetached, !session.display.isEmpty,
              let engine, let best = bestCandidate(),
              best.word != session.display else { return nil }

        // Kanal bir kez sorgulanır: `matches(ofSurface:)` morfoloji üzerinde
        // yüzey yürüyüşü yapıyor, iki kez çağırmak o işi boşuna tekrarlardı.
        let literal = engine.literalChannel.score(session.literal)
        let delta = costOfLiteral(literal, engine: engine) - best.cost
        return delta > theta(literal, fieldProtectsLiteral: fieldProtectsLiteral)
            ? best.word : nil
    }

    /// `cost(literal)` — §0 açık-vocabulary literal kanalı üzerinden.
    private func costOfLiteral(_ score: LiteralChannel.Score, engine: Engine) -> Double {
        let literal = Array(session.literal)
        // `ComposingSession` değişmezi: dokunma `i`, literal karakter `i`'nin
        // kanıtıdır.
        assert(session.touches.count == literal.count)
        let spatial = zip(session.touches, literal).reduce(0.0) { acc, pair in
            let (t, ch) = pair
            guard let k = layout.keyIndex(for: ch) else { return acc }
            return acc + engine.decoder.spatial.negLogP(t, keyIndex: k)
        }
        // `w_lex · F_lex + F_lang` — decoder'ın aday maliyetiyle aynı terimler.
        return spatial + engine.literalChannel.totalLexicalCost(score)
            + engine.decoder.weights.wLen * Double(literal.count)
    }

    /// `θ(literal, ctx)` — artan koruma eşiği (§8).
    private func theta(_ score: LiteralChannel.Score,
                       fieldProtectsLiteral: Bool) -> Double {
        // Bilinen kelime bozulmaz; uzunluk sınırını aşan token literal korumaya
        // düşer; kalibre edilmemiş OOV de korunur. Üçü de kanalın kendi kararı.
        if score.demandsProtection { return .infinity }
        // Kod/literal token koruma kuralları (§5c A/B).
        if Self.isProtectedToken(session.literal) { return .infinity }
        if fieldProtectsLiteral { return .infinity }
        return oovTheta
    }

    /// §5c A: rakam/`_`/`.`/`/`/`\`/`:`/`-` içeren, karışık büyük-küçük harfli,
    /// kısa TAMAMI BÜYÜK, `@`/`#` ile başlayan token'lar düzeltilmez.
    public static func isProtectedToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        if s.hasPrefix("@") || s.hasPrefix("#") { return true }
        if s.contains(where: { "0123456789_./\\:-".contains($0) }) { return true }
        let hasUpper = s.contains { $0.isUppercase }
        let hasLower = s.contains { $0.isLowercase }
        if hasUpper && hasLower { return true }
        if hasUpper && !hasLower && s.count <= 4 { return true }
        return false
    }

    // MARK: - Dil ve öğrenme

    private mutating func remember(language: UInt8?) {
        guard let language else { return }
        engine?.decoder.languageModel.previous = language
        engine?.literalChannel.languageModel.previous = language
        rebuildIncremental()
    }

    /// Commit edilen token'dan kalibrasyon örneği toplar.
    ///
    /// **Seçim düzenlemesi bu yoldan geçmez**: o token'ın dokunmaları ilk
    /// yazıldığında zaten öğrenildi, tekrar eklemek aynı kanıtı iki kez saymak
    /// olurdu. Türetilmiş kanıt da asla buraya ulaşmaz — gerçek gözlem değil.
    private mutating func learn(touches: [TouchSample], literal: String,
                                committed: String,
                                confidence: CalibrationLearner.Confidence) {
        let added = calibration.observe(touches: touches, literal: literal,
                                        committed: committed, layout: layout,
                                        confidence: confidence)
        guard added > 0 else { return }
        samplesSinceSave += added
        guard samplesSinceSave >= saveEvery else { return }
        wantsCalibrationSave = true
    }

    /// Çağıran kalibrasyonu diske yazdıktan sonra bunu çağırır.
    public mutating func calibrationSaved() {
        wantsCalibrationSave = false
        samplesSinceSave = 0
        applyCalibration()      // yeni tahmini yürürlüğe al
    }

    /// Profil değişiminde yeni learner yüklenir.
    public mutating func replaceCalibration(_ c: CalibrationLearner) {
        calibration = c
        samplesSinceSave = 0
        wantsCalibrationSave = false
        applyCalibration()
    }

    // MARK: - İç

    /// Oturumun sonucunu decoder'a çevirir.
    ///
    /// Artımlı kod çözme yalnız `.appended`'de korunur (§11.C.1); dokunma
    /// dizisi başka türlü değiştiyse beam bayat kalacağı için yeniden kurulur.
    private mutating func apply(_ outcome: ComposingSession.Outcome) {
        switch outcome {
        case .unchanged:
            break
        case .appended:
            if let last = session.touches.last { incremental?.append(last) }
        case .rebuilt, .cleared:
            rebuildIncremental()
        }
    }

    private mutating func rebuildIncremental() {
        guard let e = engine else { incremental = nil; return }
        var inc = IncrementalDecoder(decoder: e.decoder)
        for t in session.touches { inc.append(t) }
        incremental = inc
    }

    /// Bir yüzeyden **türetilmiş** dokunma dizisi: her harf kendi tuşunun
    /// merkezinde. Gerçek gözlem değil (§8.4).
    private func syntheticTouches(for word: String) -> [TouchSample]? {
        var out: [TouchSample] = []
        out.reserveCapacity(word.count)
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { return nil }
            out.append(TouchSample(down: layout.keys[k].center, timestamp: 0))
        }
        return out
    }
}
