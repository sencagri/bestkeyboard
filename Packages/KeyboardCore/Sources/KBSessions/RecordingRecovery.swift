import Foundation
import KBRuntime

/// Yarım kalmış kayıtları kapatır — sözleşme §12.6.
///
/// ## Neden gerekiyor
///
/// Uygulama arka plana atılıp öldürüldüğünde ya da güç kesildiğinde terminal
/// frame hiç yazılmıyor ve kayıt sonsuza dek `recording` kalıyor. Cihazda
/// gözlendi: çekilen kayıt "hâlâ açık" diyordu, oysa onu yazan süreç çoktan
/// yoktu.
///
/// Bu tek başına bir veri kaybı değil ama **sayılamaz** bir kayıt üretiyor:
/// §12.6 vazgeçme oranını raporlamayı şart koşuyor ve `recording` durumundaki
/// bir deneme ne tamamlanmış ne vazgeçilmiş sayılabiliyor. Her tüketicinin
/// "dosya eski, demek ki kesilmiş" çıkarımını kendi başına yapması gerekiyordu
/// — biri atlarsa sayı sessizce bozuluyor.
///
/// ## Neden `RecordingLibrary` yapmıyor
///
/// Okuma ile yazma ayrı: `list` çağrısının yan etkisi olarak dosya değiştirmek,
/// analiz aracının kayıtları incelerken onları **değiştirmesi** demekti. Karar
/// açıkça verilmeli, okumanın yan ürünü olmamalı.
///
/// ## Neden `finalText` uydurma değil
///
/// Kayda yazılan metin `DocumentMutation` zincirinden türetiliyor ve zincir
/// **her adımda kendi özetini** tutturuyor (`DocumentReconstruction`). Yani
/// yazdığımız şey gözlenmiş mutasyonların zorunlu sonucu, tahmin değil.
/// Türetim doğrulanamıyorsa (v2 migrasyonunda delta yok) kayıt **kapatılmıyor**:
/// doğrulanamayan bir metni nihai metin diye yazmak tam olarak kaçındığımız şey.
public enum RecordingRecovery {

    public struct Closed: Equatable, Sendable {
        public let url: URL
        public let attemptID: String
        /// Türetilen nihai metin.
        public let finalText: String
        /// Kaydın son eyleminin zamanı — terminal buraya konuyor.
        public let at: TimeInterval
    }

    public struct Skipped: Error, Equatable, Sendable, CustomStringConvertible {
        public let url: URL
        public let reason: String
        public var description: String { "\(url.lastPathComponent): \(reason)" }
    }

    public struct Outcome: Equatable, Sendable {
        public var closed: [Closed] = []
        /// Kapatılamayanlar — **atlanmıyor, raporlanıyor**.
        public var skipped: [Skipped] = []
    }

    /// Dizindeki yarım kalmış her kaydı `interrupted` olarak kapatır.
    ///
    /// - Note: `.json` (v2) kayıtlar dokunulmuyor — append-only konteyner
    ///   değiller ve yerinde değiştirmek eski biçimi yeniden yazmak olurdu.
    @discardableResult
    public static func closeStale(in directory: URL) -> Outcome {
        var out = Outcome()
        for entry in RecordingLibrary.stale(in: directory) {
            guard entry.origin == .journal else {
                out.skipped.append(.init(url: entry.url,
                                         reason: "v2 JSON; konteyner değil"))
                continue
            }
            switch close(entry) {
            case let .success(c): out.closed.append(c)
            case let .failure(s): out.skipped.append(s)
            }
        }
        return out
    }

    static func close(_ entry: RecordingLibrary.Entry) -> Result<Closed, Skipped> {
        let session = entry.session

        // Yarım kuyruk: son frame eksik. Arkasına yazmak bozuk baytların
        // ardına sağlam bir frame koymak olur ve okuyucu **kaydın tamamını**
        // reddeder. Kurtarmanın veri kaybetmesi kabul edilemez.
        guard !entry.truncatedTail else {
            return .failure(.init(url: entry.url,
                                  reason: "son frame yarım kalmış; kapatmak "
                                    + "kaydı okunamaz yapardı"))
        }

        let text: String
        do {
            switch try DocumentReconstruction.replay(session) {
            case let .complete(t):
                text = t
            case let .unverifiable(_, from):
                return .failure(.init(url: entry.url,
                                      reason: "belge \(from). action'dan itibaren "
                                        + "doğrulanamıyor; nihai metin yazılamaz"))
            }
        } catch {
            return .failure(.init(url: entry.url,
                                  reason: "belge türetimi çelişti: \(error)"))
        }

        // Terminal zamanı **son eylemden** geliyor, "şimdi"den değil: kurtarma
        // ne zaman koştuğu kaydın bir olgusu değil ve `at` süresi olmayan bir
        // beklemeyi denemenin süresine eklerdi. Hiç eylem yoksa sıfır.
        let at = session.actions.last?.t ?? 0
        let state = SessionEventReducer.reduce(session)
        let terminal = SessionJournal.Terminal(
            reason: CanonicalSession.Status.interrupted.rawValue,
            at: at, finalText: text, cursor: state.cursor,
            promptTokenCount: session.promptTokens.value?.count ?? -1,
            violations: state.violations.map(\.description),
            unverifiable: state.unverifiable)

        do {
            let writer = try FileJournalWriter(appendingTo: entry.url)
            let payload = try SessionCodec.encoder.encode(terminal)
            // **Dayanıklı**: terminal kaybolursa kayıt yine `recording` kalır ve
            // bir sonraki açılış aynı işi tekrar dener — ama arada çekilen kopya
            // hâlâ sayılamaz bir kayıt olur.
            try writer.append(.init(type: .terminal, payload: payload),
                              durable: true)
            try writer.closeFile()
        } catch {
            return .failure(.init(url: entry.url, reason: "\(error)"))
        }

        return .success(.init(url: entry.url, attemptID: session.attemptID,
                              finalText: text, at: at))
    }
}
