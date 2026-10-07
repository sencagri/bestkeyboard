import Foundation
import KBAssembly
import KBGeometry
import KBLexicon
import KBRuntime
import KBToolSupport

/// Dil paketlerinin **tek** üretim tanımı.
///
/// Altı paket var ve hepsi aynı yerden üretilmeli:
///
/// | Paket | Ne | Kaynak |
/// |---|---|---|
/// | `tr-TR.bkt` | form listesi + gayrıresmî katman (BİRLEŞİK, §7) | `wordlist.tsv` + `informal.tsv` |
/// | `tr-TR.bkr` | kök sözlüğü (morfoloji) | `roots.tsv` |
/// | `tr-TR.bkc` | literal kanalı karakter n-gram modeli | `wordlist.tsv` |
/// | `tr-TR.bkx` | genişletme haritası | `expansions.tsv` |
/// | `en-US.bkt` | ikinci dil | `wordlist.tsv` |
/// | `en-US.bkc` | ikinci dilin karakter modeli | `wordlist.tsv` |
///
/// Neden burada: `deploy.sh` paketleri kendi içinde üretiyordu ve yalnız
/// `tr-TR.bkt`'yi, üstelik `--informal` bayrağı olmadan — argo katmanı sessizce
/// paketten düşüyor ve kısaltmalar korumasız kalıyordu (§8.5: `slm`'nin
/// otomatik açılmamasının tek güvencesi sözlükte olması). Sonra plan
/// `build-packs.sh`'e taşındı ama orada paket düzenini (klasör, yerel adı,
/// uzantı) **yeniden** yazıyordu. Çıktı yolları artık `PackPaths`'ten geliyor.
enum BuildPlan {

    struct Step {
        let title: String
        let locale: PackLocale
        let role: PackRole
        let output: String
        let run: () -> Void

        var summary: String { "\(locale.rawValue)\t\(role.rawValue)\t\(output)\t\(title)" }
    }

    /// Paket ağacının kaynak dosyası: `<kök>/<yerel>/<ad>`.
    static func source(_ locale: PackLocale, _ name: String, root: String) -> String {
        "\(PackPaths.directory(locale, root: root))/\(name)"
    }

    static func steps(root: String) -> [Step] {
        func out(_ l: PackLocale, _ r: PackRole) -> String { PackPaths.file(l, r, root: root) }
        let trWords = PackPaths.wordlist(.turkish, root: root)
        let enWords = PackPaths.wordlist(.english, root: root)
        return [
            Step(title: "form listesi + gayrıresmî katman", locale: .turkish, role: .forms,
                 output: out(.turkish, .forms)) {
                buildFormPack(input: trWords, output: out(.turkish, .forms),
                              maxSurfaceLen: LexiconLimits.maxSurfaceLength,
                              informalPath: source(.turkish, "informal.tsv", root: root),
                              allowInvalid: false)
            },
            Step(title: "kök sözlüğü", locale: .turkish, role: .roots,
                 output: out(.turkish, .roots)) {
                buildRootPack(input: source(.turkish, "roots.tsv", root: root),
                              output: out(.turkish, .roots))
            },
            Step(title: "literal kanalı (tr)", locale: .turkish, role: .charModel,
                 output: out(.turkish, .charModel)) {
                buildCharNGramPack(input: trWords, output: out(.turkish, .charModel))
            },
            Step(title: "genişletme haritası", locale: .turkish, role: .expansions,
                 output: out(.turkish, .expansions)) {
                buildExpansionMap(input: source(.turkish, "expansions.tsv", root: root),
                                  output: out(.turkish, .expansions))
            },
            Step(title: "ikinci dil (en)", locale: .english, role: .forms,
                 output: out(.english, .forms)) {
                buildFormPack(input: enWords, output: out(.english, .forms),
                              maxSurfaceLen: LexiconLimits.maxSurfaceLength,
                              informalPath: nil, allowInvalid: false)
            },
            Step(title: "literal kanalı (en)", locale: .english, role: .charModel,
                 output: out(.english, .charModel)) {
                buildCharNGramPack(input: enWords, output: out(.english, .charModel))
            },
        ]
    }
}

/// Planı sırayla koşar; ilk hata (`fail`) üretimi durdurur.
func buildAll(root: String) {
    for step in BuildPlan.steps(root: root) {
        print("\u{1B}[1;36m▸ \(step.title)\u{1B}[0m")
        step.run()
    }
    print("\u{1B}[1;32m✓ tüm paketler üretildi\u{1B}[0m")
}
