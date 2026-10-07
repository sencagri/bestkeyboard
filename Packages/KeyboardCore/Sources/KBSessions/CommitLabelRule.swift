import Foundation
import KBGeometry

/// §12.5 etiket kuralı — **tek** uygulama.
///
/// Şema tipinin (`Commit.Label`) yanında değil ayrı dosyada: şema dosyası
/// "ne kaydediliyor" sorusunu, bu dosya "kayıttaki değer nasıl üretiliyor ve
/// doğrulanıyor" sorusunu yanıtlıyor. Yazıcı, golden replay, validator ve
/// analiz bu fonksiyonları çağırıyor.
public extension CanonicalSession.Action.Commit.Label {

    /// `cursor` konumundaki hedef kelime; dizinin dışındaysa `nil`.
    static func target(in promptTokens: [String], cursor: Int) -> String? {
        cursor >= 0 && cursor < promptTokens.count ? promptTokens[cursor] : nil
    }

    /// Literal hedefle eşleşiyor mu — **Türkçe** küçük harfle.
    ///
    /// Etiketi üreten (`RecordingEngine`), doğrulayan (`SessionValidator`) ve
    /// yanlış düzeltmeyi sayan (`RecordingAnalysis`) aynı kuralı kullanmak
    /// zorunda. İki kopya olsaydı biri `Locale`'i unutur ve `Ali`/`ali`
    /// karşılaştırması iki tarafta farklı sonuç verirdi — doğrulama da
    /// yazıcıyı onaylamış olurdu.
    static func literal(_ literal: String, matches target: String) -> Bool {
        TurkishText.equalIgnoringCase(literal, target)
    }

    /// §12.5 kuralı — **tek** uygulama.
    ///
    /// > `calibrationReplay` koşulunda, hedef kelime kelime kelime
    /// > gösterilmişse ve `literal == hedef` ise, o token `strong`
    /// > sayılabilir — çünkü niyet gözlemden değil **protokolden**
    /// > bilinir.
    ///
    /// Yazıcı (`RecordingEngine`) ve golden replay aynı fonksiyonu çağırıyor.
    /// İki kopya olsaydı golden kural değişikliğini **fark olarak göremezdi**:
    /// kendi kopyası da değişmediği sürece iki taraf da eski kuralı uygular ve
    /// regresyon görünmez kalırdı.
    static func make(literal: String,
                     promptTokens: [String]?,
                     cursor: Int,
                     alignmentIsConstructed: Bool,
                     diverged: Bool) -> Self {
        let target = promptTokens.flatMap { Self.target(in: $0, cursor: cursor) }
        let matches = target.map { Self.literal(literal, matches: $0) }
        guard alignmentIsConstructed else {
            return .init(source: .production, confidence: .weak,
                         targetWord: target, matchesTarget: matches)
        }
        // Sapma varsa protokolün verdiği kesinlik de gitmiştir: token artık
        // gösterilen kelimeye bağlı değil.
        let strong = !diverged && matches == true
        return .init(source: .protocol,
                     confidence: strong ? .strong : .weak,
                     targetWord: target, matchesTarget: matches)
    }
}
