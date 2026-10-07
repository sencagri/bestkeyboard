import SwiftUI

/// Geliştirici araçları › Yapay zeka günlüğü (tasarım 36).
struct AILogView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [AILog.Entry] = []
    @State private var filter: Filter = .all
    @State private var open: UUID?
    @State private var copied = false

    enum Filter: CaseIterable {
        case all, problems, ok
        var title: String {
            switch self {
            case .all: return "Hepsi"
            case .problems: return "Sorunlar"
            case .ok: return "Başarılı"
            }
        }
    }

    private var shown: [AILog.Entry] {
        switch filter {
        case .all: return entries
        case .problems: return entries.filter { $0.status != .ok }
        case .ok: return entries.filter { $0.status == .ok }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(Filter.allCases, id: \.self) { f in
                        let on = filter == f
                        Button { filter = f } label: {
                            Text(f.title).font(.footnote.weight(.bold))
                                .foregroundStyle(on ? .white : BK.ink)
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(on ? BK.accent : BK.card, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }

                BKCard(padding: 16) {
                    if shown.isEmpty {
                        Text(entries.isEmpty ? "Henüz kayıt yok. Klavyede ✦, paylaşımda BestKeyboard ✦ ya da bir Kestirme kullanınca burada görünür."
                                             : "Bu süzgece uyan kayıt yok.")
                            .font(.subheadline).foregroundStyle(BK.sub)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                        VStack(alignment: .leading, spacing: 0) {
                            if i > 0 { Divider().overlay(BK.line) }
                            row(e)
                        }
                    }
                }

                if !entries.isEmpty {
                    Button(role: .destructive) {
                        AILog.clear()
                        reload()
                    } label: {
                        Text("Günlüğü temizle").font(.headline).foregroundStyle(BK.pink.ink)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(BK.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }

                Text("Son \(AILog.limit) kayıt telefonda durur, hiçbir yere gönderilmez. Anahtarlar yazılmaz; mesaj metninin yalnız ilk 120 harfi tutulur. “Kopyala” ile bana yapıştırabilirsin.")
                    .font(.footnote).foregroundStyle(BK.sub).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Yapay zeka günlüğü")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "Kopyalandı" : "Kopyala") {
                    UIPasteboard.general.string = AILog.text(shown)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                .disabled(shown.isEmpty)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, p in if p == .active { reload() } }
        .refreshable { reload() }
    }

    private func reload() { entries = AILog.all() }

    private func row(_ e: AILog.Entry) -> some View {
        let isOpen = open == e.id
        return VStack(alignment: .leading, spacing: 8) {
            Button { open = isOpen ? nil : e.id } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(color(e.status)).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(e.action) · \(e.origin.title)").font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            Text(Self.time(e.date)).font(.footnote.monospacedDigit()).foregroundStyle(BK.sub)
                        }
                        Text(summary(e)).font(.footnote)
                            .foregroundStyle(e.status == .ok ? BK.sub : color(e.status))
                            .lineLimit(isOpen ? nil : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Ayrıntıyı kapat" : "Ayrıntıyı aç")

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    detail("Kaynak", "\(e.source) · \(e.textCount) harf")
                    if !e.textHead.isEmpty { detail("Metin", e.textHead + (e.textCount > e.textHead.count ? "…" : "")) }
                    detail("Servis", "\(e.provider) · \(e.model)")
                    detail("Ağ", e.network)
                    detail("Süre", "\(e.durationMs) ms" + (e.httpCode.map { " · HTTP \($0)" } ?? ""))
                    detail(e.status == .ok ? "Sonuç" : "Olay", e.detail)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                .padding(.leading, 20)
                .textSelection(.enabled)
            }
        }
        .padding(.vertical, 10)
    }

    private func detail(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.footnote).foregroundStyle(BK.sub).frame(width: 64, alignment: .leading)
            Text(v).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ e: AILog.Entry) -> String {
        let secs = SettingsFormat.seconds(Double(e.durationMs) / 1000, digits: 1)
        switch e.status {
        case .ok: return "\(e.httpCode ?? 200) · \(secs) · \(e.detail)"
        case .notFound: return "Bulunamadı · \(secs)"
        case .dismissed: return "Klavye kapandı, cevap gösterilemedi · \(secs)"
        case .error: return (e.httpCode.map { "Hata \($0) · " } ?? "Hata · ") + e.detail
        }
    }

    private func color(_ s: AILog.Status) -> Color {
        switch s {
        case .ok: return BK.green.ink
        case .notFound: return BK.orange.ink
        case .error, .dismissed: return BK.pink.ink
        }
    }

    private static func time(_ d: Date) -> String {
        DateFormats.turkish(Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "d MMM HH:mm").string(from: d)
    }
}

#if DEBUG
extension AILog {
    /// `-bkScreen yzgunluk -aiLogDemo`: tasarımdaki örnek kayıtlar (ekran görüntüsü için).
    static func seedDemoIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-aiLogDemo") else { return }
        clear()
        let now = Date()
        func e(_ ago: TimeInterval, _ o: Origin, _ a: String, _ src: String, _ text: String, _ st: Status,
               _ code: Int?, _ ms: Int, _ net: String, _ detail: String) -> Entry {
            Entry(date: now.addingTimeInterval(-ago), origin: o, action: a, source: src, textCount: text.count,
                  textHead: String(text.prefix(120)), provider: "Cerebras", model: "gpt-oss-120b", network: net,
                  status: st, httpCode: code, durationMs: ms, detail: detail)
        }
        let msg = "Cumartesi akşam 7'de Kadıköy'de buluşalım, 2 saat kadar otururuz"
        for x in [
            e(5400, .shortcut, "Hatırlatıcı", "Kestirme girdisi", "Eve gelirken ekmek ve süt al", .error, 401, 312, "Wi-Fi", "Anahtar geçersiz. Uygulamadan yeniden bağla."),
            e(4300, .share, "Çevir", "Paylaşılan mesaj", "Cumartesi akşam görüşürüz", .ok, 200, 512, "Wi-Fi", "See you Saturday evening"),
            e(1200, .keyboard, "Takvim", "Yazdığın", msg, .dismissed, 200, 3582, "Hücresel", "Cevap geldiğinde klavye ekranda değildi; sonuç gösterilemedi."),
            e(1186, .keyboard, "Takvim", "Yazdığın", "C", .notFound, 200, 722, "Hücresel", "Bu metinde etkinlik bulamadım: “C”."),
            e(60, .keyboard, "Takvim", "Yazdığın", msg, .ok, 200, 932, "Wi-Fi", "Kadıköy'de buluşma · Cmt 10 Eki · 19:00"),
        ] { append(x) }
    }
}
#endif
