import SwiftUI
import KBGeometry
import KBSessions

/// **Hızlı kayıt** — sorunu yaşadığın anda kayda geçmek.
///
/// ## Neden korpus akışından ayrı
///
/// `RecordingListView` sıradaki prompt'u dayatıyor ve §12.10'un toplama
/// reçetesini yürütüyor: manifest sırası, prompt başına bir deneme, kapsayış
/// hedefi. O akış **veri toplamak** için doğru.
///
/// Ama "şu kelimeyi yazmaya çalıştım, olmadı" derdi sıradaki prompt'la ilgili
/// değil. O anda gereken şey: aklındaki cümleyi yaz, kaydet, sonra ne olduğunu
/// anlat. Aynı zincir, farklı giriş.
///
/// ## Neden hedef önce yazılıyor
///
/// Hedef **kayda giriyor** ve etiketi protokolden güçlü yapan tek şey o
/// (§12.5). Sonradan "şunu yazmak istiyordum" demek hedefi gözlemden değil
/// hatırlamadan kurmak olurdu.
struct QuickRecordingView: View {

    @State private var intended = ""
    @State private var condition = CanonicalSession.Condition.behavior
    @State private var active: Prompt?

    /// Başlatılmış deneme.
    private struct Prompt: Identifiable {
        let id = UUID()
        let prompt: PromptCorpus.Prompt
        let condition: CanonicalSession.Condition
        let ordinal: Int
    }

    private var layout: KeyLayout { TurkishQ.layout() }

    private var unsupported: [Character] {
        PromptCorpus.unsupportedCharacters(in: intended, layout: layout)
    }
    private var tokens: [String] {
        PromptTokenizer(layout: layout).tokens(of: intended)
    }

    var body: some View {
        Form {
            Section {
                TextField("yazmak istediğin cümle", text: $intended, axis: .vertical)
                    .lineLimit(2...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !unsupported.isEmpty {
                    Text("klavyede olmayan karakter: "
                         + unsupported.map(String.init).joined(separator: " "))
                        .font(.caption).foregroundStyle(.red)
                } else if !tokens.isEmpty {
                    // Hedef dizisi **gösteriliyor**: kayda giren şey bu ve
                    // tokenizer'ın ne yaptığını görmeden "yanlış hizalandı"
                    // demek mümkün olmuyordu.
                    Text("hedef: " + tokens.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Aklındaki cümle")
            } footer: {
                Text("Bu cümle hedef olarak kayda giriyor; klavyenin ne yapması "
                     + "gerektiğini bilen tek şey o. Sonra kelime kelime yazacaksın.")
            }

            Section("Koşul") {
                Picker("Koşul", selection: $condition) {
                    Text("Davranış — gerçek klavye")
                        .tag(CanonicalSession.Condition.behavior)
                    Text("Kalibrasyon — düzeltme kapalı")
                        .tag(CanonicalSession.Condition.calibrationReplay)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(condition == .behavior
                     ? "Öneri çubuğu ve otomatik düzeltme açık — \"düzeltmedi\" ya "
                       + "da \"yanlış düzeltti\" derdi için bu."
                     : "Düzeltme ve geri bildirim kapalı — dokunma dağılımı için bu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Kaydı başlat") { start() }
                    .disabled(tokens.isEmpty || !unsupported.isEmpty)
            } footer: {
                Text("Bitirince ne olduğunu anlatacağın bir not alanı çıkacak.")
            }
        }
        .navigationTitle("Hızlı kayıt")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $active) { rec in
            NavigationStack {
                RecorderScreen(prompt: rec.prompt, condition: rec.condition,
                               posture: .init(hands: .twoThumbs, mobility: .seated),
                               participantID: RecordingIdentity.participantID,
                               sessionOrdinal: rec.ordinal) {
                    active = nil
                    intended = ""
                }
            }
        }
    }

    private func start() {
        let ordinal = RecordingIdentity.nextOrdinal()
        active = Prompt(
            prompt: .init(id: "quick-\(UUID().uuidString.prefix(4))",
                          text: intended.trimmingCharacters(in: .whitespaces),
                          split: .dev),
            condition: condition, ordinal: ordinal)
    }
}

/// Deneme bitince açılan not sayfası.
///
/// **Ölçüm değil anlatı.** Şemanın geri kalanı klavyenin ürettiği olgular; bu
/// alan ölçümün açıklayamadığını taşıyor. Boş bırakılabilir — zorunlu kılmak,
/// söyleyecek şeyi olmayan denemede uydurma bir cümle üretirdi.
struct RecordingNoteSheet: View {
    @Binding var note: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ne oldu?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Ne yazmak istedin, ne oldu?")
                } footer: {
                    Text("Örnek: \"boşluğa bastım ama 'n' yazdı\", \"kelimeyi "
                         + "tanımadı\", \"doğru yazmıştım, bozdu\". Boş "
                         + "bırakabilirsin.")
                }
            }
            .navigationTitle("Not")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitir") { onDone() }.bold()
                }
            }
        }
    }
}

/// Kayıt kimliği — katılımcı ve oturum sırası. Kayıt listesi ve hızlı kayıt
/// **aynı** sayacı kullanıyor: önce biri "kullan sonra artır", öbürü "artır
/// sonra kullan" yapıyordu ve art arda kullanılınca aynı sıra iki oturuma
/// veriliyordu (oturum-ayrık split bozulur, §12.8).
enum RecordingIdentity {
    private static let participantKey = "participantID"
    private static let ordinalKey = "sessionOrdinal"
    private static var store: UserDefaults { .standard }

    /// Kararlı ve anonim katılımcı kimliği; cihaz başına bir kez üretilir.
    static var participantID: String {
        if let id = store.string(forKey: participantKey), !id.isEmpty { return id }
        let id = UUID.short
        store.set(id, forKey: participantKey)
        return id
    }

    /// Yeni oturumun sırası — **monoton**: silinen bir kayıt yüzünden yeniden
    /// kullanılmıyor.
    static func nextOrdinal() -> Int {
        let n = store.integer(forKey: ordinalKey)
        store.set(n + 1, forKey: ordinalKey)
        return n
    }
}
