import Foundation
import KBToolSupport

// MARK: - kbbench
//
// Sözleşme §9 ve §11.E: telefona dokunmadan algoritma iterasyonu yapabilmenin
// tek yolu. Planda Faz 0 çıktısıydı; performans borcu somutlaşınca yazıldı.
//
// Bu dosya yalnız **ayrıştırma ve dağıtım**: her ölçüm kendi dosyasında, ortak
// kurulum `BenchContext`'te. Kipler komut satırındaki sırayla koşuyor ve çıkış
// kodu en kötü kipin kodu — kayıt doğrulaması gibi kapı niteliğindeki bir kip
// başka bir kiple birlikte istendiğinde sonucu yutulmasın diye.
//
// ÖNEMLİ: doğruluk sayıları **simüle edilmiş** dokunmalardan gelir ve model
// doğrulaması DEĞİLDİR (§9). Buradaki değer regresyon tespiti ve parametre
// taramasıdır.

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let modes = options.resolvedModes
let context = BenchContext(options, needsWords: modes.contains { $0.needsWords })

var status: Int32 = 0
for mode in modes {
    let code: Int32
    switch mode {
    case .decode:             code = DecodeBench.run(context)
    case .pruningGap:         code = PruningGap.run(context)
    case .beamSweep:          code = BeamSweep.run(context)
    case .calibration:        code = CalibrationExperiment.run(context)
    case .bigramLatency:      code = BigramLatency.run(context)
    case .personal:           code = PersonalBench.run(context)
    case .lookup:             code = Lookup.run(context)
    case .sessions:           code = Sessions.run(context)
    case .writeLegacyFixture: code = LegacyFixture.run(context)
    }
    status = max(status, code)
}
exit(status)
