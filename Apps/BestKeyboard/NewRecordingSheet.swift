import SwiftUI
import UIKit
import KBGeometry
import KBSpatial
import KBDecoder
import KBAssembly
import KBRuntime
import KBLearning
import KBSessions

/// Yeni kayıt — §12'nin 2. adımı: koşul, duruş ve hedef seçimi.
struct NewRecordingSheet: View {
    /// Manifest sırasındaki ilk kayıtsız prompt.
    let suggested: PromptCorpus.Prompt
    let onStart: (PromptCorpus.Prompt, CanonicalSession.Condition, CanonicalSession.Posture) -> Void

    @State private var condition: CanonicalSession.Condition = .calibrationReplay
    @State private var hands: CanonicalSession.Posture.Hands = .twoThumbs
    @State private var mobility: CanonicalSession.Posture.Mobility = .seated
    @State private var useManual = false
    @State private var manualText = ""
    @State private var selected: PromptCorpus.Prompt?
    @Environment(\.dismiss) private var dismiss

    private var unsupported: [Character] {
        PromptCorpus.unsupportedCharacters(in: manualText, layout: TurkishQ.layout())
    }

    /// Hedefte **yazılabilir harf** var mı.
    ///
    /// `unsupported` yetmiyordu: sembol ve rakamlar "yazılabilir" sayıldığı için
    /// `---` o kapıdan geçiyor, ama tokenizer boş dizi üretiyor.
    private var manualIsTypable: Bool {
        PromptTokenizer(layout: TurkishQ.layout()).isTypable(manualText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Koşul", selection: $condition) {
                        Text("Kalibrasyon").tag(CanonicalSession.Condition.calibrationReplay)
                        Text("Davranış").tag(CanonicalSession.Condition.behavior)
                    }.pickerStyle(.segmented)
                } footer: {
                    Text(condition == .calibrationReplay
                         ? "Hedef kelime kelime gelir, yazdığın GÖRÜNMEZ ve düzeltme "
                           + "uygulanmaz. Kendi hatanı göremediğin için düzeltmeye "
                           + "çalışmazsın — dokunma dağılımı temiz kalır."
                         : "Gerçek klavye: öneriler dokunulabilir, düzeltme uygulanır. "
                           + "Karar davranışını ölçmek için.")
                }

                Section("Duruş") {
                    Picker("El", selection: $hands) {
                        Text("İki başparmak").tag(CanonicalSession.Posture.Hands.twoThumbs)
                        Text("Tek başparmak").tag(CanonicalSession.Posture.Hands.oneThumb)
                        Text("İşaret parmağı").tag(CanonicalSession.Posture.Hands.indexFinger)
                    }
                    Picker("Hareket", selection: $mobility) {
                        Text("Otururken").tag(CanonicalSession.Posture.Mobility.seated)
                        Text("Ayakta").tag(CanonicalSession.Posture.Mobility.standing)
                        Text("Yürürken").tag(CanonicalSession.Posture.Mobility.walking)
                    }
                }

                Section("Hedef") {
                    Toggle("Kendi cümlemi yazayım", isOn: $useManual)
                    if useManual {
                        TextField("hedef cümle", text: $manualText, axis: .vertical)
                            .lineLimit(2...5)
                            .autocorrectionDisabled()
                        if !unsupported.isEmpty {
                            Text("Bu klavyede yazılamayan karakter: "
                                 + unsupported.map(String.init).joined(separator: " "))
                                .font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        Picker("Cümle", selection: Binding(
                            get: { selected ?? suggested },
                            set: { selected = $0 })) {
                            ForEach(PromptCorpus.all) { p in
                                Text("\(p.id) · \(p.text)").tag(p)
                            }
                        }
                        Text("Öneri: \(suggested.id) — manifest sırasındaki ilk "
                             + "kayıtsız prompt. Aynı prompt'u tekrar yazmak ezber "
                             + "yanlılığı üretir (§12.10).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Yeni kayıt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Başla") {
                        let p = useManual
                            ? PromptCorpus.Prompt(id: "manual-\(UUID().uuidString.prefix(4))",
                                                  text: manualText.trimmingCharacters(in: .whitespaces),
                                                  split: .dev)
                            : (selected ?? suggested)
                        onStart(p, condition,
                                .init(hands: hands, mobility: mobility))
                    }
                    // **Yazılabilir harf yoksa deneme başlamıyor** (§2.3):
                    // `---` gibi bir hedefte tokenizer boş dizi veriyor ve
                    // tamamlanma koşulu (`cursor == 0 == hedef sayısı`) daha
                    // başlamadan sağlanıyor — deneme hiçbir şey ölçmeden
                    // `completed` oluyordu.
                    .disabled(useManual && (manualText.trimmingCharacters(in: .whitespaces).isEmpty
                                            || !unsupported.isEmpty
                                            || !manualIsTypable))
                }
            }
        }
    }
}
