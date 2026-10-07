import Foundation
import KBGeometry
import KBAssembly

/// Dil paketlerinin arka planda yüklenmesi ve süreç boyu önbelleği.
///
/// İki aşamalı init (§11.A): tuşlar önce çizilir ve anında yazılabilir;
/// leksikon arka planda yüklenir, öneriler hazır olunca yanar.
@MainActor
final class PackLoading {
    /// Yükleme kuşağı. Ölçü değişimi yeni bir yükleme başlatıyor ve eskisi
    /// iptal edilemiyor; kuşak kontrolü olmadan **geç biten eski** yükleme,
    /// yeni geometriyle kurulmuş motoru eskisiyle eziyordu — çizilen tuşlarla
    /// skorlanan tuşlar ayrışırdı.
    private var generation = 0

    /// Süreç boyu paket önbelleği — yalnız ana thread'den okunup yazılıyor.
    ///
    /// iOS klavyeyi her açışta **yeni** bir denetleyici kuruyor ama uzantı
    /// süreci çoğu zaman yaşıyor. Önbellek yokken her açılış paketi baştan
    /// yüklüyordu (cihazda ~650 ms) ve eski denetleyici henüz serbest
    /// kalmadıysa iki motor aynı anda bellekteydi. Uzantının bellek sınırı
    /// dar; aşılınca sistem uzantıyı öldürüp **önceki klavyeye** dönüyor —
    /// kullanıcıya "seçtim ama başka klavye geldi" diye görünen şey.
    ///
    /// Tek giriş tutuluyor: ölçü değişince eski motor bırakılıyor.
    /// `Loaded` tamamen değer tipi, denetleyiciler arasında paylaşmak güvenli.
    private static var cache: (fingerprint: String, loaded: PackLoader.Loaded)?

    /// `layout` için paketleri yükler. `completion` ana thread'de ve yalnız
    /// **son** istenen yükleme için çağrılıyor.
    func load(_ layout: KeyLayout, bundle: Bundle,
              completion: @escaping (Result<PackLoader.Loaded, Error>) -> Void) {
        generation += 1
        let generation = self.generation
        let fingerprint = layout.fingerprint
        if let cached = Self.cache, cached.fingerprint == fingerprint {
            // Yine bir tur sonra: kurulum her zaman görünüm ekrana girdikten
            // sonra olmuştu (alan bilgisi, güvenli alan kontrolü), sıra korunuyor.
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation else { return }
                completion(.success(cached.loaded))
            }
            return
        }
        // Eski ölçünün motoru yenisi yüklenirken önbellekte tutulmuyor: yeni
        // yükleme sürerken bellekte üç kopya (önbellek, canlı motor, yeni)
        // olmasın. Canlı motor zaten denetleyicide duruyor.
        Self.cache = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PackLoader.load(layout: layout, bundle: bundle) }
            DispatchQueue.main.async {
                // Klavye kapandıysa sonuç yine de saklanıyor — bir sonraki
                // açılış tam da onu istiyor. Geç biten eski kuşak ise
                // önbelleği ezmiyor.
                if case let .success(loaded) = result, self == nil || generation == self?.generation {
                    Self.cache = (fingerprint, loaded)
                }
                guard let self, generation == self.generation else { return }
                completion(result)
            }
        }
    }
}
