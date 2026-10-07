import Foundation
import KBRuntime

extension SessionValidator {

    // MARK: - Token kimliği

    /// Kimlikler **monoton, tekil ve yeniden kullanılmaz** olmalı.
    ///
    /// Geri açılıp yeniden commit edilen token **yeni** kimlik alır; eskisini
    /// geri vermek, kaydı okuyan tarafta iki farklı yazım denemesini tek token
    /// sanmaya yol açardı.
    static func validateTokenIdentity(_ session: CanonicalSession)
        -> [Finding] {
        var out: [Finding] = []
        var seen = Set<Int>()
        var last = Int.min
        for a in session.actions {
            guard a.kind.closesToken else { continue }
            guard let commit = a.commit else {
                out.append(.init(kind: .boundaryWithoutCommit,
                                 actionID: a.actionID,
                                 detail: "\(a.kind.rawValue) commit taşımıyor"))
                continue
            }
            // Boş token gerçek bir token değil; kimlik tüketmez ve kimliği
            // `.notApplicable` olmalı — `.unknown` "vardı ama bilmiyoruz"
            // demek olurdu.
            guard commit.kind != .empty else {
                if commit.tokenID != .notApplicable {
                    out.append(.init(kind: .tokenIDNotMonotonic,
                                     actionID: a.actionID,
                                     detail: "boş token kimlik taşıyor"))
                }
                continue
            }
            guard let id = commit.tokenID.value?.raw else { continue }
            if !seen.insert(id).inserted {
                out.append(.init(kind: .tokenIDNotMonotonic, actionID: a.actionID,
                                 detail: "kimlik \(id) yeniden kullanıldı"))
            }
            if id <= last {
                out.append(.init(kind: .tokenIDNotMonotonic, actionID: a.actionID,
                                 detail: "kimlik \(id) monoton değil (önceki \(last))"))
            }
            last = id
        }
        // Hedefli etkiler yalnız **var olan** kimliklere atıf yapabilir.
        for a in session.actions {
            guard let e = a.effect.value else { continue }
            var referenced = e.restoredToken.map { [$0.raw] } ?? []
            for span in e.deleted {
                switch span {
                case let .editedToken(id), let .removedToken(id):
                    referenced.append(id.raw)
                case .separator, .unattributed:
                    continue
                }
            }
            for id in referenced where !seen.contains(id) {
                out.append(.init(kind: .tokenIDNotMonotonic, actionID: a.actionID,
                                 detail: "kimlik \(id) hiç commit edilmemiş"))
            }
        }
        return out
    }

    // MARK: - Yerel v3 bütünlüğü

    /// **v3 hiçbir `.unknown` üretmez.** `.unknown` yalnız v2 migrasyonundan
    /// çıkar; yerel bir kayıtta görünmesi yazıcının bir olguyu atladığı
    /// anlamına gelir ve o kayıt sessizce kalibrasyondan düşerdi.
    static func validateNativeCompleteness(_ session: CanonicalSession)
        -> [Finding] {
        guard session.sourceSchema == CanonicalSession.currentSchema else {
            return []
        }
        var out: [Finding] = []
        func check(_ isUnknown: Bool, _ name: String, _ id: Int? = nil) {
            guard isUnknown else { return }
            out.append(.init(kind: .unknownFactInNativeRecord, actionID: id,
                             detail: name))
        }
        check(session.promptTokens.isUnknown, "promptTokens")
        check(session.geometry.layoutFingerprint.isUnknown, "layoutFingerprint")
        check(session.engine.build.codeRevision.isUnknown, "build.codeRevision")
        check(session.engine.build.provenance.isUnknown, "build.provenance")
        check(session.engine.policy.feedbackVisible.isUnknown, "policy.feedbackVisible")
        check(session.engine.policy.suggestionsVisible.isUnknown,
              "policy.suggestionsVisible")
        check(session.engine.policy.correction.isUnknown, "policy.correction")
        if let cfg = session.engine.configuration.value {
            check(cfg.scoring.isUnknown, "scoring")
            check(cfg.calibration.sigma.isUnknown, "calibration.sigma")
            for p in cfg.packs {
                check(p.sha256.isUnknown, "pack.sha256(\(p.name))")
                check(p.topology.isUnknown, "pack.topology(\(p.name))")
            }
        }
        for a in session.actions {
            check(a.event.isUnknown, "event", a.actionID)
            check(a.effect.isUnknown, "effect", a.actionID)
            check(a.document.isUnknown, "document", a.actionID)
            check(a.candidates.isUnknown, "candidates", a.actionID)
            check(a.shown.isUnknown, "shown", a.actionID)
            if let c = a.commit {
                check(c.tokenID.isUnknown, "commit.tokenID", a.actionID)
                check(c.cursorBefore.isUnknown, "commit.cursorBefore", a.actionID)
            }
        }
        return out
    }
}
