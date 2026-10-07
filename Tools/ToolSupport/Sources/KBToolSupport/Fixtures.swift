import Foundation
import KBMorphology

/// Morfoloji **spike** kökleri — elle seçilmiş, her alternasyon sınıfından
/// bir örnek. Ölçek ölçümü değil (o gerçek `.bkr` ile yapılıyor); şema ve
/// mekanizma sondası.
///
/// Liste iki araçta ayrı ayrı yazılıyordu ve kökler kopyalar arasında aynı
/// kalmak zorundaydı (aynı maliyet, aynı alternasyon) — biri değişince iki
/// aracın "aynı kök" dediği şey ayrışırdı.
public enum SpikeRoots {

    /// Tam liste, sabit sırada. Kök indeksi sırayı izler; araçlar alt küme
    /// seçerken sıra korunur.
    public static let all: [Root] = [
        Root("kitap", pos: .noun, lexCost: 4.0, finalAlternation: .pToB),
        Root("kalem", pos: .noun, lexCost: 4.2),
        Root("çocuk", pos: .noun, lexCost: 4.4, finalAlternation: .kToĞ),
        Root("renk",  pos: .noun, lexCost: 5.2, finalAlternation: .kToG),
        Root("burun", pos: .noun, lexCost: 5.6, dropsVowel: true),
        Root("masa",  pos: .noun, lexCost: 4.7),
        Root("ev",    pos: .noun, lexCost: 4.1),
        Root("gel",   pos: .verb, lexCost: 4.0),
    ]

    /// Adı verilen kökler, `all` sırasıyla.
    public static func named(_ names: Set<String>) -> [Root] {
        all.filter { names.contains(String($0.surface)) }
    }
}
