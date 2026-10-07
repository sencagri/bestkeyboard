import Foundation
import KBAssembly
import KBDecoder
import KBGeometry
import KBLearning
import KBRuntime
import KBSessions
import KBToolSupport

/// Cihaz kayıtları (§12)
///
/// Kayıt formatı yazıcıyla birlikte gitmeli: okuyucu olmadan şema hataları ancak
/// pahalı cihaz verisi toplandıktan SONRA bulunur ve o veri tekrar toplanamaz.
enum Sessions {

    static func run(_ ctx: BenchContext) -> Int32 {
        let opt = ctx.options
        guard let dir = opt.sessionsPath else { fail("--sessions klasör ister") }
        let layout = ctx.layout
        let lexicon = ctx.lexicon
        print("\n=== cihaz yazım kayıtları ===")

        // Okuyucu `RecordingLibrary` — iki biçimi de tanıyan **tek** giriş.
        //
        // Eskiden `SessionReplay.load` yalnız `*.json` glob'luyordu. v3 kayıtları
        // `.bkj` uzantılı ve araç onları hiç görmüyordu: klasör doluyken
        // "okunabilir kayıt yok" diyip çıkıyordu. Analiz aracının sessizce boş
        // dönmesi veri toplanmamış olmakla aynı sonucu veriyor — ama toplanmıştı.
        let root = URL(fileURLWithPath: BenchContext.resolve(dir), isDirectory: true)
        if opt.recoverStale {
            // Nihai metin **türetiliyor**: mutasyon zinciri her adımda kendi özetini
            // tutturuyor, dolayısıyla yazılan şey gözlenmiş mutasyonların zorunlu
            // sonucu. Türetilemiyorsa kayıt kapatılmıyor ve sebebi basılıyor.
            let r = RecordingRecovery.closeStale(in: root)
            if !r.closed.isEmpty {
                print("  \(r.closed.count) yarım kalmış kayıt interrupted olarak kapatıldı")
            }
            for s in r.skipped { print("  ⚠︎ kapatılamadı — \(s)") }
        }
        let (records, failures) = RecordingAnalysis.read(directory: root,
                                                        layout: layout)
        // Okunamayan dosyalar **atlanmıyor**: bozuk kaydı görmezden gelmek
        // vazgeçme oranını olduğundan iyi gösterirdi (§12.6).
        if !failures.isEmpty {
            print("  ⚠︎ \(failures.count) dosya okunamadı:")
            for f in failures.prefix(10) { print("     \(f)") }
            if failures.count > 10 { print("     … \(failures.count - 10) tane daha") }
        }
        guard !records.isEmpty else {
            print("  klasörde okunabilir kayıt yok: \(dir)")
            return failures.isEmpty ? 0 : 1
        }

        let sum = RecordingAnalysis.summarize(records)
        // **Kayıtların** geometrisi: tuş indeksleri ona göre. Varsayılan
        // layout'u kullanmak tuş adlarını ve tuş sayısını yanlış basıyordu —
        // kapsayış satırı bunu zaten düzeltmişti, kalibrasyon özeti hâlâ
        // varsayılanı kullanıyordu.
        let recordsLayout = records.first(where: { $0.layoutResolved })?.layout
            ?? layout
        func count(_ s: CanonicalSession.Status) -> Int { sum.byStatus[s] ?? 0 }
        print("  \(sum.total) deneme"
              + " · \(count(.completed)) tamam"
              + " · \(count(.aborted)) vazgeçildi"
              + " · \(count(.invalid)) geçersiz"
              + " · \(count(.interrupted)) yarıda kaldı"
              + " · \(count(.recording)) hâlâ açık"
              // Üretimden yakalanan dilimler: `total`'a giriyorlardı ama dökümde
              // görünmüyordu, dolayısıyla basılan sayıların toplamı tutmuyordu ve
              // vazgeçme oranı olduğundan küçük görünüyordu.
              + " · \(count(.captured)) yakalandı")
        let journals = sum.byOrigin[.journal] ?? 0
        let legacy = sum.byOrigin[.legacyJSON] ?? 0
        print("  biçim: \(journals) günlük (v3) · \(legacy) eski JSON (v2)")
        if sum.layoutUnresolved > 0 {
            print("  ⚠︎ \(sum.layoutUnresolved) kaydın geometrisi çözülemedi —")
            print("     tuş merkezleri kaydın anlattığı yerde değil; kalibrasyon ve")
            print("     golden sonuçları o kayıtlar için yorumlanamaz.")
        }
        if sum.truncatedTails > 0 {
            // Kırpılmış kuyruk = güç kaybında kaybolan son frame. Sessiz kalırsa
            // eksik bir deneme tam deneme gibi sayılır.
            print("  ⚠︎ \(sum.truncatedTails) kaydın son frame'i yarım kalmış (kuyruk atıldı)")
        }
        if sum.debugBuilds > 0 {
            print("  ⚠︎ \(sum.debugBuilds) deneme DEBUG derlemesiyle kaydedilmiş —")
            print("     gecikme ve davranış ölçümü için geçersiz (deploy.sh --debug).")
        }
        if sum.unconfigured > 0 {
            print("  ⚠︎ \(sum.unconfigured) kayıtta motor anlık görüntüsü yok —")
            print("     replay kurulamaz (v2 kaydı ya da yükleme bitmeden yarıda kalmış).")
        }
        // Abort oranı raporlanmak ZORUNDA (§12.6): yalnız tamamlananları saymak,
        // elde kalan kümeyi tarafsız bir popülasyonmuş gibi gösterir.
        if let rate = sum.abortRate {
            print(String(format: "  vazgeçme oranı: %.0f%%", 100 * rate))
        }

        // Yapısal doğrulama: kayıt kendi değişmezlerini tutuyor mu.
        //
        // Bu adım eskiden hiç yoktu; şema ihlalleri ancak replay sırasında dolaylı
        // olarak görünüyordu. Validator olguyu doğrudan sınıyor.
        print("\n  yapısal doğrulama:")
        if sum.recordsWithFindings == 0 && sum.documentFailures == 0 {
            print("    ✓ \(sum.total) kaydın hepsi tutarlı")
        } else {
            print("    ✗ \(sum.recordsWithFindings)/\(sum.total) kayıtta toplam "
                  + "\(sum.findings) bulgu")
            for r in records where !r.findings.isEmpty {
                print("      \(r.url.lastPathComponent):")
                for f in r.findings.prefix(5) { print("        \(f)") }
                if r.findings.count > 5 {
                    print("        … \(r.findings.count - 5) bulgu daha")
                }
            }
        }
        if sum.documentFailures > 0 {
            print("    ✗ \(sum.documentFailures) kayıt kendi metnini üretemiyor:")
            for r in records {
                if case let .failed(why) = r.document {
                    print("      \(r.url.lastPathComponent): \(why)")
                }
            }
        }
        if sum.documentUnverifiable > 0 {
            print("    ⚠︎ \(sum.documentUnverifiable) kayıtta belge deltası eksik "
                  + "(v2 migrasyonu) — metin türetimi kısmi")
        }

        // Kullanıcı notları **önce** basılıyor: ölçümün açıklayamadığı şeyi taşıyan
        // tek alan bu ve raporun sonuna gömülürse hiç okunmaz.
        let noted = records.compactMap { r -> (String, String, String?, String?)? in
            guard r.session.note != nil || r.annotation != nil else { return nil }
            return (r.url.lastPathComponent, r.session.promptText,
                    r.session.note, r.annotation)
        }
        if !noted.isEmpty {
            print("\n  kullanıcı notları (ölçüm değil, anlatı):")
            for (file, target, note, annotation) in noted {
                print("    \(file)")
                if !target.isEmpty { print("      hedef  : \(target)") }
                // İkisi ayrı basılıyor: "o an mı yazdı, sonradan mı" ayrımı
                // analizde de korunmalı.
                if let note { print("      o anda : \(note)") }
                if let annotation { print("      sonra  : \(annotation)") }
            }
        }

        print("\n  dokunma sonuçları (kullanıcının 'bastım ama olmadı' sorusu):")
        print("    toplam \(sum.touchesTotal)"
              + " · hiç isabet etmeyen \(sum.touchesNeverHit)"
              + " · sürüklenip düşen \(sum.touchesLeftBounds)"
              + " · sistem iptali \(sum.touchesCancelled)")
        if !sum.droppedByReason.isEmpty {
            // Hiçbir token'a girmeyen dokunmalar: "boşluk çalışmadı" şikâyetinin
            // ölçülebilir hâli. Gerekçesiz toplam sayı hangi düzeltmenin
            // gerektiğini söylemiyordu.
            let parts = sum.droppedByReason.sorted { $0.value > $1.value }
                .map { "\($0.key.rawValue) \($0.value)" }
            print("    token'a girmeyen dokunma: " + parts.joined(separator: " · "))
        }

        print("\n  token: \(sum.tokens) · hedefiyle birebir yazılan \(sum.tokensMatchingTarget)")
        let kinds = sum.byCommitKind.sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \($0.value)" }
        print("    commit türü: " + (kinds.isEmpty ? "yok" : kinds.joined(separator: " · ")))
        print("    DOĞRUYU BOZAN düzeltme: \(sum.wrongAutocorrects)"
              + " · θ=∞ ile korunan: \(sum.literalProtected)")
        if sum.tokensAfterDivergence > 0 || sum.tokensInvalidated > 0
            || sum.tokensTouchCountMismatch > 0 {
            print("    hiza bozulduktan sonra \(sum.tokensAfterDivergence)"
                  + " · geçersiz kılınan \(sum.tokensInvalidated)"
                  + " · dokunma sayısı uyuşmayan \(sum.tokensTouchCountMismatch)")
        }

        print("\n  kalibrasyon örneği: \(sum.calibrationSamples)")
        // Dışlama oranı raporlanmak ZORUNDA: dışlama, ölçülmek istenen olgunun
        // kendisiyle korelasyonlu (uzun/kısa yazılan token'lar rastgele değil).
        print("    dışlanan token: uzunluk uyuşmazlığı \(sum.excludedLengthMismatch)"
              + " · hizalaması delinmiş \(sum.excludedDiverged)"
              + " · etiketi zayıf \(sum.excludedWeakLabel)"
              + " · dokunma sayısı tutmayan \(sum.excludedTouchCountMismatch)")
        // **Tamamen** dışlanan kayıtlar ayrı: token sayaçları bunlarda sıfır kalıyor
        // ve yalnız onlara bakan bir rapor "hiç dışlama yok" diyordu.
        if !sum.excludedSessions.isEmpty {
            print("    tamamen dışlanan kayıt: \(sum.excludedSessions.count)")
            for e in sum.excludedSessions.prefix(5) {
                print("      \(e.url.lastPathComponent): \(e.reason)")
            }
            if sum.excludedSessions.count > 5 {
                print("      … \(sum.excludedSessions.count - 5) tane daha")
            }
        }
        print("    hedeften sapıp HEDEF tuşa kurtarılan dokunma: \(sum.recoveredDriftedTouches)")
        print("    (bu sayı hedefli kaydın üretim verisine üstünlüğüdür — §8.3'ün")
        print("     kesme yanlılığı tam olarak bu dokunmaları dışarıda bırakıyordu)")
        if sum.calibrationSamples > 0 {
            // Kapsayış **kayıtların** layout'undan okunuyor: tuş indeksleri
            // geometriye göre; varsayılan layout'un harf sırasıyla listelemek
            // yanlış tuş adları basardı.
            let coverageLayout = recordsLayout
            let gate = HierarchicalCalibration.minKeySamples
            let under = coverageLayout.keys.indices
                .filter { (sum.keyCoverage[$0] ?? 0) < gate }
            print("    tuş başına eşiğin (\(gate)) altında kalan: "
                  + (under.isEmpty ? "yok"
                     : under.map { String(coverageLayout.keys[$0].char) }
                         .joined(separator: " ")))
        }

        // MARK: Golden doğrulama
        //
        // Motor **kayıttan** kuruluyor (`ReplayEngineFactory`), buradaki bench
        // decoder'ından değil: bench'in kendi ağırlıkları, kendi paketleri ve
        // kalibrasyonsuz uzamsal modeli var. Onunla karşılaştırmak farkı "kod
        // değişti" diye okunamaz hâle getiriyordu — fark kurulumdan geliyordu.
        print("\n  golden doğrulama (kayıt ↔ bugünkü kod):")
        let packSource = DirectoryPackSource(
            root: URL(fileURLWithPath: BenchContext.resolve(opt.packsDir), isDirectory: true))
        /// Kaydın geometrisinde **üretimle aynı** motor (`PackLoader`); paketler
        /// yüklenemezse çağıran bench sözlüğüne düşüyor.
        func loadPacks(_ l: KeyLayout) -> PackLoader.Loaded? {
            try? PackLoader.load(layout: l, source: packSource, beamWidth: opt.beamWidth)
        }
        var compared = 0, diverged = 0, unverifiable = 0
        var clean = 0
        var envBlocked: [(String, String)] = []
        var failed: [(String, String)] = []
        for r in records {
            let name = r.url.lastPathComponent
            do {
                // **Kaydın kendi geometrisi.** Kayıt ekranı kullanıcının günlük
                // ölçülerinde yazdırıyor; varsayılan layout'la replay kurmak her
                // kaydı "ortam uyuşmuyor" kovasına atıyordu (28 gerçek kayıtta
                // ölçüldü: 0 yorumlanabilir karşılaştırma).
                let rep = try GoldenReplay.run(r.session, layout: r.layout,
                                               packs: packSource,
                                               currentRevision: opt.currentRevision)
                compared += rep.compared
                diverged += rep.divergences.count
                unverifiable += rep.unverifiable.count
                if rep.isClean { clean += 1 }
                let env = rep.environment
                if !env.isVerifiable {
                    var why: [String] = []
                    if !env.packMismatches.isEmpty {
                        why.append("paket farkı: " + env.packMismatches.joined(separator: ","))
                    }
                    if !env.missingPacks.isEmpty {
                        why.append("eksik paket: " + env.missingPacks.joined(separator: ","))
                    }
                    if env.layoutMismatch { why.append("layout parmak izi farklı") }
                    if !env.unknownFacts.isEmpty {
                        why.append("bilinmeyen olgu: " + env.unknownFacts.joined(separator: ","))
                    }
                    envBlocked.append((name, why.joined(separator: " · ")))
                }
                for d in rep.divergences.prefix(3) { print("    \(name): \(d)") }
            } catch {
                failed.append((name, "\(error)"))
            }
        }
        print("    \(compared) nokta karşılaştırıldı · \(diverged) fark"
              + " · \(unverifiable) doğrulanamaz action")
        if !failed.isEmpty {
            print("    ⚠︎ \(failed.count) kayıtta replay kurulamadı:")
            for f in failed.prefix(5) { print("       \(f.0): \(f.1)") }
        }
        if !envBlocked.isEmpty {
            // §12.1: ortam eşleşmiyorsa fark "kod değişti" diye yorumlanamaz. Bunu
            // raporlamadan yeşil basmak, doğrulanmamışı doğrulanmış göstermek olur.
            print("    ⚠︎ \(envBlocked.count) kayıtta ORTAM eşleşmiyor — fark kod farkı"
                  + " diye okunamaz:")
            for e in envBlocked.prefix(5) { print("       \(e.0): \(e.1)") }
        }
        if clean == records.count {
            print("    ✓ \(clean)/\(records.count) kayıt bugünkü kodla birebir yeniden üretiliyor")
        } else {
            // "Fark yok" ile "doğrulanamadı" **aynı şey değil** ve tek satıra
            // indirilirse ikincisi birinci gibi okunur. Ortamı eşleşmeyen bir
            // kayıtta sıfır fark, kodun doğru olduğunu değil karşılaştırmanın
            // yapılmadığını gösterir (§12.1).
            print("    \(clean)/\(records.count) kayıt temiz — geri kalanı yukarıda")
            if diverged == 0 && (!envBlocked.isEmpty || unverifiable > 0
                                 || !failed.isEmpty) {
                print("    ⚠︎ fark BULUNMADI ama doğrulama tamamlanmadı — yeşil değil")
            }
        }

        // Dil öncelinin düzeltme kararına etkisi.
        if opt.languagePrior {
            print("\n  dil önceli — düzeltme kararı ne kadar değişiyor:")
            let probe = LanguagePriorProbe.run(records: records) { l, previous in
                guard let loaded = loadPacks(l) else {
                    return .init(decoder: ctx.makeDecoder(layout: l),
                                 literalChannel: LiteralChannel(vocabulary: lexicon,
                                                                charModels: []),
                                 expansions: nil)
                }
                var engine = InputCoordinator.Engine(
                    decoder: loaded.decoder, literalChannel: loaded.literalChannel,
                    expansions: loaded.expansions)
                // **Tek değişen şey** bu: aynı dokunmalar, aynı paketler, aynı
                // ağırlıklar. Başka bir şey değişseydi fark ona da yazılabilirdi.
                // Decoder ile kanal **birlikte** — koordinatörün kullandığı setter.
                engine.context.previousLanguage = previous
                return engine
            }
            if probe.tokens == 0 {
                print("    ⚠︎ değerlendirilebilir token yok — ölçüm YAPILMADI")
            } else {
                print(String(format: "    %d token · %d'sinde karar DEĞİŞTİ (%%%.0f)",
                             probe.tokens, probe.flips.count, 100 * probe.flipRate))
                print("      Türkçe öncelde düzelirdi, İngilizce öncelde düzelmiyor: "
                      + "\(probe.lostCorrections)")
                print("      tersi (İngilizce öncelde düzeltme başlıyor): "
                      + "\(probe.gainedCorrections)")
                for f in probe.flips.prefix(8) {
                    print("      \(f.literal) → tr: \(f.withTurkish)"
                          + "\(f.correctedTurkish ? " (düzeltildi)" : "")"
                          + " · en: \(f.withEnglish)"
                          + "\(f.correctedEnglish ? " (düzeltildi)" : "")"
                          + (f.target.map { " · hedef \($0)" } ?? ""))
                }
                if probe.flips.count > 8 {
                    print("      … \(probe.flips.count - 8) tane daha")
                }
            }
            for (why, k) in probe.skipped.sorted(by: { $0.value > $1.value }) {
                print("    değerlendirilemeyen: \(why) — \(k)")
            }
        }

        // Held-out kol karşılaştırması (§12.8).
        if opt.calibrationArms {
            print("\n  kalibrasyon kolları — HELD-OUT (§12.8):")
            // Motor **kayıttaki paketlerle** kuruluyor; bench'in kendi sözlüğüyle
            // ölçmek başka bir klavyeyi ölçmek olurdu.
            let armReport = CalibrationArms.compare(records: records) { l, spatial in
                guard let loaded = loadPacks(l) else {
                    return ctx.makeDecoder(layout: l, spatial: spatial)
                }
                // `with(spatial:)`: kurulumun taşıdığı bigram paketi ve dil
                // durumu da kolda kalıyor — elle yeniden kurmak onları düşürüyordu.
                return loaded.decoder.with(spatial: spatial)
            }
            print("    eğitim \(armReport.trainRecords) kayıt · "
                  + "değerlendirme \(armReport.testRecords) kayıt")
            if armReport.arms.first?.evaluated ?? 0 == 0 {
                print("    ⚠︎ değerlendirilebilir token yok — ölçüm YAPILMADI")
            } else {
                print("    " + pad("kol", 26) + pad("top-1", 12) + pad("eğitim örneği", 15)
                      + pad("kurtarılan kayma", 18) + "kendi katmanı olan tuş")
                for a in armReport.arms {
                    print("    " + pad(a.name, 26)
                          + pad(String(format: "%.0f%% (%d/%d)", 100 * a.accuracy,
                                       a.correct, a.evaluated), 12)
                          + pad(a.trainingSamples > 0 ? "\(a.trainingSamples)" : "—", 15)
                          + pad(a.recoveredDrift > 0 ? "\(a.recoveredDrift)" : "—", 18)
                          + (a.trainingSamples > 0 ? "\(a.keysWithOwnLayer)" : "—"))
                }
                // Dar bir değerlendirme kümesi **söylenmek zorunda**: 34 token'da
                // birkaç puanlık fark gürültüden ayırt edilemez.
                let n = armReport.arms.first?.evaluated ?? 0
                print(String(format: "    NOT: n = %d token. Bir token ≈ %.1f puan;",
                             n, 100.0 / Double(max(n, 1))))
                print("    bu genişlikte küçük farklar gürültüdür.")
            }
            for (why, k) in armReport.skipped.sorted(by: { $0.value > $1.value }) {
                print("    değerlendirilemeyen: \(why) — \(k)")
            }
        }

        // Üç kollu ölçüm ancak yeterli kalibrasyon örneği varsa anlamlı.
        if sum.calibrationSamples >= CalibrationLearner.minStrongSamples {
            print("\n  kalibrasyon kolları (gerçek dokunmalarla):")
            let learner = RecordingAnalysis.learner(from: records)
            let e = learner.hierarchicalEstimate(layout: recordsLayout)
            print(String(format: "    güçlü örnek %d · kendi d_c'si olan tuş %d/%d · geçiş %d",
                         e.strongSamples, e.keysWithOwnLayer, recordsLayout.keys.count,
                         e.passes))
            let w = recordsLayout.minKeyWidth
            print(String(format: "    global sapma: (%+.4f, %+.4f) = tuşun %%%.0f'i",
                         e.globalX, e.globalY, 100 * abs(e.globalX) / w))
            print("    NOT: doğruluk karşılaştırması için held-out gerekiyor;")
            print("    tek oturumda öğrenip aynı oturumda ölçmek kendini doğrulamadır (§12.8).")
        } else {
            print("\n  kalibrasyon kolları atlandı: \(sum.calibrationSamples) örnek,"
                  + " eşik \(CalibrationLearner.minStrongSamples).")
        }
        // Çıkış kodu olguyu taşıyor: CI'da "okundu ama bozuk" ile "her şey yolunda"
        // aynı koda düşerse doğrulama hiçbir şeyi korumaz.
        //
        // **Doğrulanamamak da başarısızlık**: ortamı eşleşmeyen ya da olgusu eksik
        // bir kayıtta sıfır fark bulmak hiçbir şey kanıtlamıyor ve sıfır dönmek onu
        // kanıtlanmış gibi gösterirdi. Eksik veri sessiz kalmasın diye kapı sıkı.
        let verified = clean == records.count
            && sum.recordsWithFindings == 0 && sum.documentFailures == 0
            && failures.isEmpty && failed.isEmpty
        return verified ? 0 : 1
    }
}
