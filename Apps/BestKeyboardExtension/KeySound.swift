import AVFoundation

/// Basış sesi tipi. Ham değer kalıcı (ayar deposu) ve paket kaynağının adı.
enum KeySoundKind: String, CaseIterable {
    case none, tik, yumusak, mekanik, daktilo, damla

    var title: String {
        switch self {
        case .none:    return "Sessiz"
        case .tik:     return "Tık"
        case .yumusak: return "Yumuşak"
        case .mekanik: return "Mekanik"
        case .daktilo: return "Daktilo"
        case .damla:   return "Damla"
        }
    }
}

/// Bir ses kanalı: hangi ses, hangi şiddette.
///
/// İki kanal var — harf ve kelime sonu (boşluk, noktalama, `⏎`). Kelime
/// sonunu ayrı duymak, yazarken ritmi kulaktan takip etmeyi sağlıyor;
/// daktilonun satır sonu zili gibi.
struct KeySoundChannel: Equatable {
    var kind: KeySoundKind
    /// 0…1
    var volume: Double

    static let letterDefault = KeySoundChannel(kind: .tik, volume: 0.6)
    static let wordDefault = KeySoundChannel(kind: .daktilo, volume: 0.75)
}

/// Basış seslerini çalan motor.
///
/// ## Neden `playInputClick` değil
///
/// Sistem tık sesi tek bir ses ve şiddeti ayarlanamıyor; kullanıcı beş tip
/// ve kanal başına şiddet istedi. Sesler paketle geliyor (her biri ~8 KB,
/// 90 ms), `AVAudioEngine` üzerinde önceden belleğe alınıyor.
///
/// ## Gecikme
///
/// Dosyadan çalmak (`AVAudioPlayer`) ilk basışta onlarca ms gecikiyordu;
/// tamponlar burada bir kez çözülüyor ve bir sonraki basış yalnız bir
/// `scheduleBuffer`. Hızlı yazımda sesler üst üste binebilsin diye dört
/// çalıcı sırayla kullanılıyor — tek çalıcı bir öncekini kesip "tırtıklı"
/// bir ses üretirdi.
///
/// ## Oturum
///
/// `.ambient` + `mixWithOthers`: telefonun sessiz anahtarına uyuyor ve
/// kullanıcının dinlediği müziği kesmiyor. Klavye uzantısında iOS sesi
/// yalnız Tam Erişimle çıkarıyor; kapalıyken motor kuruluyor ama duyulmuyor.
final class KeySoundPlayer {
    static let shared = KeySoundPlayer()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [KeySoundKind: AVAudioPCMBuffer] = [:]
    private var next = 0
    private var started = false
    private var failed = false

    private init() {}

    /// Ses gerçekten çalınmadan önce çağrılabilir: ilk basışın gecikmesini
    /// basıştan önceye alıyor.
    func prepare() {
        guard !started, !failed else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            var format: AVAudioFormat?
            for kind in KeySoundKind.allCases where kind != .none {
                guard let url = Bundle(for: KeySoundPlayer.self)
                        .url(forResource: kind.rawValue, withExtension: "wav") else { continue }
                let file = try AVAudioFile(forReading: url)
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length))
                else { continue }
                try file.read(into: buf)
                buffers[kind] = buf
                format = file.processingFormat
            }
            guard let format else { failed = true; return }
            for _ in 0..<4 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
                players.append(p)
            }
            try engine.start()
            for p in players { p.play() }
            started = true
        } catch {
            // Ses bir süs; kurulamazsa klavye sessiz devam ediyor.
            failed = true
        }
    }

    func play(_ channel: KeySoundChannel) {
        guard channel.kind != .none, channel.volume > 0 else { return }
        prepare()
        guard started, let buf = buffers[channel.kind] else { return }
        if !engine.isRunning { try? engine.start(); for p in players { p.play() } }
        let p = players[next]
        next = (next + 1) % players.count
        p.volume = Float(min(max(channel.volume, 0), 1))
        p.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !p.isPlaying { p.play() }
    }
}
