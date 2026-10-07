import SwiftUI
import UIKit
import KBGeometry
import KBSpatial
import KBDecoder
import KBAssembly
import KBRuntime
import KBLearning
import KBSessions

/// Kayıt oturumlarının listesi — §12'nin 3 adımının birincisi.
///
/// Abort oranı burada **görünür**: yalnız tamamlananları göstermek, kullanıcıya
/// da analize de tarafsız bir popülasyon varmış izlenimi verirdi (§12.6).
struct RecordingListView: View {
    /// Kayıtlar **tek okuyucudan** geliyor: eski `*.json` ve yeni `.bkj`
    /// birlikte listeleniyor. Yalnız birine bakmak, kullanıcının topladığı
    /// verinin yarısını görünmez yapardı.
    @State private var entries: [RecordingLibrary.Entry] = []
    /// Okunamayan dosyalar — **gizlenmiyor**. Sessizce atlamak bozuk bir kaydı
    /// hiç var olmamış gibi gösterip abort oranını bozardı.
    @State private var failures: [RecordingLibrary.Failure] = []
    @State private var showingNew = false
    @State private var active: ActiveRecording?
    @State private var confirmDeleteAll = false
    /// Notu düzenlenen kayıt.
    @State private var annotating: RecordingLibrary.Entry?
    @State private var annotationText = ""


    private struct ActiveRecording: Identifiable {
        let id = UUID()
        let prompt: PromptCorpus.Prompt
        let condition: CanonicalSession.Condition
        let posture: CanonicalSession.Posture
        let ordinal: Int
    }

    var body: some View {
        List {
            Section {
                if entries.isEmpty {
                    Text("Henüz kayıt yok. Sağ üstteki + ile başla.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.url) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.session.promptText).lineLimit(1)
                            Spacer()
                            Text(statusMark(entry.session.status))
                                .foregroundStyle(color(entry.session.status))
                        }
                        Text(summary(entry))
                            .font(.caption).foregroundStyle(.secondary)
                        // Not **listede görünüyor**: kayda girip görünmeyen bir
                        // şey, yazmaya değmediği izlenimi verirdi.
                        if let note = entry.session.note {
                            Text(note).font(.caption).italic()
                                .foregroundStyle(.orange).lineLimit(3)
                        }
                        // **Sonradan** eklenen not ayrı renkte: "o an mı yazdı,
                        // sonradan mı" sorusu listede de cevaplı kalıyor.
                        if let a = entry.annotation {
                            Text(a).font(.caption).italic()
                                .foregroundStyle(.blue).lineLimit(3)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { annotating = entry }
                }
                .onDelete { idx in
                    for i in idx { try? RecordingLibrary.delete(entries[i]) }
                    reload()
                }
                ForEach(failures, id: \.url) { f in
                    Text("okunamadı: \(f.description)")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Kayıtlar — \(completedCount)/\(entries.count) tamamlandı")
            } footer: {
                Text("Vazgeçilen denemeler de kayıtta kalır: yalnız tamamlananları "
                     + "saklamak seçim yanlılığı üretir (§12.6).")
            }

            Section {
                let done = completedPromptIDs
                Text("\(done.count)/\(PromptCorpus.all.count) prompt tamamlandı")
                    .font(.caption)
                let missing = collectedUnderCovered
                if missing.isEmpty && !done.isEmpty {
                    Text("Toplanan veride her tuş eşiği geçti.")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    // §12.10: bitiş ölçütü ÖLÇÜLÜR, tahmin edilmez. Önceki
                    // sürüm korpusun statik potansiyelini gösteriyordu —
                    // toplanan veriyle ilgisi yoktu.
                    Text("Toplanan veride eşiğin (20) altında: "
                         + (missing.isEmpty ? "—" : missing.map(String.init).joined(separator: " ")))
                        .font(.caption)
                }
                Text("q, w, x Türkçede yok; eşiği hiç geçmeyecekler ve kendi "
                     + "katmanları açılmayacak (satır/global katmandan beslenirler).")
                    .font(.caption2).foregroundStyle(.secondary)
            } header: {
                Text("Toplama ilerlemesi (§12.10)")
            }

            Section {
                Button("Tüm kayıtları sil", role: .destructive) { confirmDeleteAll = true }
            } footer: {
                Text("Kayıtlar ham dokunma koordinatı içerir ve kişisel veridir; "
                     + "yedeğe gitmez, cihaz kilitliyken korunur (§12.9).")
            }
        }
        .navigationTitle("Yazım kayıtları")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewRecordingSheet(suggested: nextUnrecorded) { prompt, condition, posture in
                showingNew = false
                active = ActiveRecording(prompt: prompt, condition: condition,
                                         posture: posture, ordinal: RecordingIdentity.nextOrdinal())
            }
        }
        .fullScreenCover(item: $active) { rec in
            NavigationStack {
                RecorderScreen(prompt: rec.prompt, condition: rec.condition,
                               posture: rec.posture,
                               participantID: RecordingIdentity.participantID,
                               sessionOrdinal: rec.ordinal) {
                    active = nil
                    reload()
                }
            }
        }
        .sheet(item: $annotating) { entry in
            RecordingNoteSheet(note: $annotationText) {
                try? RecordingLibrary.setAnnotation(annotationText, for: entry)
                annotating = nil
                reload()
            }
            .onAppear { annotationText = entry.annotation ?? "" }
        }
        .alert("Tüm kayıtlar silinsin mi?", isPresented: $confirmDeleteAll) {
            Button("Sil", role: .destructive) { try? RecordingLibrary.deleteAll(); reload() }
            Button("Vazgeç", role: .cancel) {}
        }
        .onAppear {
            // Çökme sonrası yarım kalanlar burada kapanır.
            // Yarım kalmış kayıtlar **işaretlenmiyor**: append-only bir
            // günlükte dosyayı yerinde değiştirmek mümkün değil ve olmamalı da.
            // Liste onları `recording` olarak gösteriyor — dürüst olan bu.
            reload()
        }
    }

    /// Kuyruk eksikliği **görünür**: güç kaybında kaybolan bir action'ı
    /// gizlemek, kaydı olduğundan sağlam göstermek olurdu.
    private func summary(_ e: RecordingLibrary.Entry) -> String {
        let s = e.session
        return "\(s.condition.rawValue) · \(s.split) · "
            + "\(s.touches.count) dokunma · \(s.actions.count) eylem"
            + (e.truncatedTail ? " · kuyruk eksik" : "")
    }

    private var completedCount: Int {
        entries.filter { $0.session.status == .completed }.count
    }
    /// Kurtarma **okumadan önce** koşuyor.
    ///
    /// Uygulama arka planda öldürüldüğünde terminal frame hiç yazılmıyor ve
    /// kayıt sonsuza dek `recording` kalıyor: ne tamamlanmış ne vazgeçilmiş
    /// sayılabiliyor, yani §12.6'nın vazgeçme oranı onu hangi kovaya koyacağını
    /// söyleyemiyor. Cihazda tam olarak bu gözlendi.
    ///
    /// `finalText` uydurulmuyor: mutasyon zincirinden türetiliyor ve zincir her
    /// adımda kendi özetini tutturuyor. Türetilemiyorsa kayıt **kapatılmıyor** ve
    /// sebebi listede görünüyor.
    private func reload() {
        let recovery = RecordingRecovery.closeStale(in: RecordingLibrary.directory)
        let listing = RecordingLibrary.list()
        entries = listing.entries
        // Kapatılamayan kayıtlar da okunamayanlarla aynı yerde görünüyor:
        // sessizce `recording` kalan bir deneme sayılamaz bir veri noktası.
        failures = listing.failures + recovery.skipped.map {
            .init(url: $0.url, reason: "kapatılamadı: \($0.reason)")
        }
    }

    /// Tamamlanmış denemelerin prompt kimlikleri.
    private var completedPromptIDs: Set<String> {
        Set(entries.map(\.session).filter { $0.status == .completed }.map(\.promptID))
    }

    /// **Toplanan** veride eşiğin altında kalan tuşlar.
    private var collectedUnderCovered: [Character] {
        let layout = TurkishQ.layout()
        var counts: [Int: Int] = [:]
        for e in entries where e.session.status == .completed {
            for smp in CalibrationExtraction.extract(e.session, layout: layout).samples {
                counts[smp.keyIndex, default: 0] += 1
            }
        }
        return layout.keys.indices
            .filter { (counts[$0] ?? 0) < HierarchicalCalibration.minKeySamples }
            .map { layout.keys[$0].char }
    }

    /// Sıradaki **kayıtsız** prompt — manifest sırasıyla (§12.10).
    ///
    /// Varsayılan `all[0]` idi; kullanıcı farkında olmadan aynı prompt'u
    /// tekrar tekrar yazabiliyordu ve eksik ancak import'ta anlaşılıyordu.
    var nextUnrecorded: PromptCorpus.Prompt {
        let done = completedPromptIDs
        return PromptCorpus.all.first { !done.contains($0.id) } ?? PromptCorpus.all[0]
    }

    private func statusMark(_ s: CanonicalSession.Status) -> String {
        switch s {
        case .completed: return "tamam"
        case .aborted: return "vazgeçildi"
        case .interrupted: return "kesildi"
        case .invalid: return "geçersiz"
        // Üretimde saklanan dilim: hedef yok, tamamlanma ölçülmüyor.
        case .captured: return "yakalandı"
        // Yarım kalmış kayıt **işaretlenmiyor**, olduğu gibi gösteriliyor:
        // append-only bir günlükte dosyayı yerinde değiştirmek mümkün değil
        // ve kurtarma kararı zaman/bağlam gerektiriyor.
        case .recording: return "yarım"
        }
    }
    private func color(_ s: CanonicalSession.Status) -> Color {
        s == .completed ? .green : (s == .invalid ? .red : .orange)
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
