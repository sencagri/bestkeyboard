import Foundation

// MARK: - İkili dosya sözleşmesi — tek yerde
//
// Paketler (`.bkt`, `.bkr`, `.bkc`, `.bkg`, `.bkx`) ve cihaz depoları (`.bkl`,
// `.bkp`) **aynı** sözleşmeyi paylaşıyor: açık byte offset'leri,
// little-endian, sınır kontrollü okuma, başlığın son 8 baytında yük üzerinden
// FNV-1a 64 checksum. Okuyucu ve yazıcı her formatta ayrı ayrı yazılıyordu;
// aynı döngünün yedi kopyası, birinde düzeltilen sınır hatasının diğer altısında
// yaşaması demekti. Paket biçimlerini okuyan her modül (`KBLexicon`,
// `KBMorphology`, `KBLearning`) en alt katmana bağımlı; ortak sözleşme orada.
//
// Swift `struct` yerleşimi bir dosya ABI'si **değildir**; okuma hizalama
// varsaymayan little-endian yüklemelerle yapılır, `unsafeBitCast` ile değil.

/// Bütün ikili formatların **ortak** hata durumları.
///
/// Formata özgü enum'lar yalnız kendi yapısal durumlarını taşıyor (ör. trie'de
/// ileri gitmeyen ark); magic, sürüm, checksum ve kesiklik her formatta aynı
/// anlama geliyor ve aynı tipte yakalanabilmeli.
public enum BinaryFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    case badMagic(UInt32)
    case unsupportedVersion(UInt16)
    case checksumMismatch(expected: UInt64, actual: UInt64)
    /// Okunacak alan verinin dışında.
    case truncated(need: Int, have: Int)
    /// Tam boyut eşitliği isteyen formatlarda fazlalık ya da eksik bayt.
    ///
    /// Fazlalığa izin vermek aynı içeriğin ikinci bir kanonik temsilini
    /// doğururdu ve checksum onu kapsadığı için fark sessizce geçerdi.
    case sizeMismatch(expected: Int, have: Int)
    case badScalar(UInt32)
    /// Alfabe kesin artan değil — sembol indeksleri üretimdekiyle aynı değil.
    case alphabetNotSorted(index: Int)
    case offsetsNotZeroBased(section: String, value: UInt32)
    case offsetsNotMonotone(section: String, index: Int, previous: UInt32, current: UInt32)
    case offsetsEndMismatch(section: String, last: UInt32, expected: Int)

    public var description: String {
        switch self {
        case let .badMagic(m):
            return "geçersiz magic: \(String(m, radix: 16))"
        case let .unsupportedVersion(v):
            return "desteklenmeyen sürüm: \(v)"
        case let .checksumMismatch(e, a):
            return "checksum uyuşmuyor: beklenen \(e), bulunan \(a)"
        case let .truncated(n, h):
            return "veri kesik: \(n) bayt gerekli, \(h) mevcut"
        case let .sizeMismatch(e, h):
            return "boyut uyuşmuyor: \(e) bayt beklenirken \(h) bayt"
        case let .badScalar(v):
            return "geçersiz Unicode skaler: \(v)"
        case let .alphabetNotSorted(i):
            return "alfabe sıralı değil: [\(i)]"
        case let .offsetsNotZeroBased(s, v):
            return "\(s) offset[0] = \(v), 0 olmalı"
        case let .offsetsNotMonotone(s, i, p, c):
            return "\(s) offset monoton değil: [\(i)] \(p) → \(c)"
        case let .offsetsEndMismatch(s, l, e):
            return "\(s) offset sonu \(l), \(e) olmalı"
        }
    }
}

// MARK: - Kontrolsüz little-endian yüklemeler (sıcak yol)

public extension UnsafeRawBufferPointer {
    /// Sınır **kontrolsüz** little-endian okuma. Yalnız sınırları önceden
    /// doğrulanmış veride (paket init'i bütün yapıyı bir kez tarıyor).
    @inlinable @inline(__always)
    func littleEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}

public extension Data {
    /// Sınır **kontrolsüz** little-endian okuma; `offset` verinin başına
    /// görelidir (dilimlerde `startIndex` sıfır olmayabilir).
    @inlinable @inline(__always)
    func littleEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.littleEndian(T.self, at: offset) }
    }
}

// MARK: - Okuyucu

/// Sınır kontrollü little-endian okuyucu.
///
/// Veriyi **kopyalamadan** tutar: `.mappedIfSafe` ile açılmış bir `Data`
/// verilirse sayfalar yalnız dokunuldukça resident olur.
public struct ByteReader: Sendable {
    public let data: Data
    public var count: Int { data.count }

    public init(_ data: Data) { self.data = data }
    public init(_ bytes: [UInt8]) { self.init(Data(bytes)) }

    /// `[offset, offset + size)` verinin içinde mi.
    ///
    /// Kontrol **taşmaya dayanıklı**: `offset + size <= count` biçimi, dosyadan
    /// gelen büyük bir değerde (`u64(Int.max)`) toplamanın kendisinde tuzağa
    /// düşüyordu, negatif bir boyutu da geçirip dilimlemede çöküyordu. Hata
    /// raporu çöküş değil, `truncated` olmalı.
    @inline(__always)
    private func require(_ offset: Int, _ size: Int) throws {
        guard offset >= 0, size >= 0, offset <= data.count,
              size <= data.count - offset else {
            throw BinaryFormatError.truncated(need: Self.saturatingSum(offset, size),
                                              have: data.count)
        }
    }

    /// `count` öğelik, öğe başına `stride` baytlık dizi `offset`'ten sığıyor mu.
    ///
    /// Çarpım da taşabilir; ayrı bir giriş, çağıranın `count * stride`'ı kendi
    /// başına hesaplayıp taşırmasına gerek bırakmıyor.
    @inline(__always)
    private func require(_ offset: Int, count: Int, stride: Int) throws {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: stride)
        guard count >= 0, stride >= 0, !overflow else {
            throw BinaryFormatError.truncated(need: .max, have: data.count)
        }
        try require(offset, bytes)
    }

    /// Hata raporu için: taşarsa `Int.max`, negatif parça sıfır sayılır.
    private static func saturatingSum(_ a: Int, _ b: Int) -> Int {
        let (r, o) = max(a, 0).addingReportingOverflow(max(b, 0))
        return o ? .max : r
    }

    /// `[offset, offset + size)` verinin içinde mi — toplu okumadan önce bir kez.
    public func requireRange(_ offset: Int, _ size: Int) throws { try require(offset, size) }

    /// `count × stride` baytlık dizi `offset`'ten sığıyor mu — taşmaya dayanıklı.
    public func requireArray(at offset: Int, count: Int, stride: Int) throws {
        try require(offset, count: count, stride: stride)
    }

    public func u8(_ off: Int) throws -> UInt8 { try require(off, 1); return unchecked(UInt8.self, off) }
    public func u16(_ off: Int) throws -> UInt16 { try require(off, 2); return unchecked(UInt16.self, off) }
    public func u32(_ off: Int) throws -> UInt32 { try require(off, 4); return unchecked(UInt32.self, off) }
    public func u64(_ off: Int) throws -> UInt64 { try require(off, 8); return unchecked(UInt64.self, off) }
    public func f32(_ off: Int) throws -> Float { Float(bitPattern: try u32(off)) }

    /// Kontrolsüz okuma — çağıran sınırı `requireRange` ile önceden doğruladı.
    @inline(__always)
    public func unchecked<T: FixedWidthInteger>(_ type: T.Type, _ off: Int) -> T {
        data.littleEndian(type, at: off)
    }

    /// `[offset, offset + length)` baytları UTF-8 olarak.
    public func utf8(_ off: Int, length: Int) throws -> String? {
        try require(off, length)
        return data.withUnsafeBytes {
            String(bytes: UnsafeRawBufferPointer(rebasing: $0[off..<(off + length)]),
                   encoding: .utf8)
        }
    }

    /// `offset`'ten sona kadar olan baytların FNV-1a 64 özeti.
    public func checksum(from off: Int) -> UInt64 {
        let start = Swift.max(0, Swift.min(off, data.count))
        return data.withUnsafeBytes { FNV1a.hash($0[start...]) }
    }

    // MARK: Ortak bölümler

    /// Alfabe: `count × u32` Unicode skaler, **kesin artan**.
    ///
    /// Sıralılık sembol eşlemesinin paket üretimindekiyle aynı olduğunun ucuz
    /// kanıtı; bozulursa tablo indeksleri kayar ve hata **sessiz** olur (yanlış
    /// maliyet, çökme yok). Bütün üreticiler sıralı yazıyor (`ScalarAlphabet`).
    public func alphabet(at off: Int, count: Int) throws -> [Unicode.Scalar] {
        try require(off, count: count, stride: 4)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let v = unchecked(UInt32.self, off + i * 4)
            guard let sc = Unicode.Scalar(v) else { throw BinaryFormatError.badScalar(v) }
            if let last = out.last, sc.value <= last.value {
                throw BinaryFormatError.alphabetNotSorted(index: i)
            }
            out.append(sc)
        }
        return out
    }

    /// CSR offset dizisi: `count + 1` × u32, **sıfırdan başlayan** ve monoton.
    ///
    /// Checksum'ı geçen ama bozuk bir paket, doğrulama olmadan sıcak yolda
    /// sınır dışı okumaya götürebilir; checksum bozulmayı yakalar, üretim
    /// hatasını yakalamaz.
    ///
    /// - Parameter end: verilirse son değer ona eşit olmalı (toplam eleman sayısı).
    /// - Returns: son offset.
    @discardableResult
    public func offsets(at off: Int, count: Int, section: String,
                        end: Int? = nil) throws -> UInt32 {
        let (entries, overflow) = count.addingReportingOverflow(1)
        guard count >= 0, !overflow else {
            throw BinaryFormatError.truncated(need: .max, have: data.count)
        }
        try require(off, count: entries, stride: 4)
        let first = unchecked(UInt32.self, off)
        guard first == 0 else {
            throw BinaryFormatError.offsetsNotZeroBased(section: section, value: first)
        }
        var prev: UInt32 = 0
        for i in stride(from: 1, through: count, by: 1) {
            let cur = unchecked(UInt32.self, off + i * 4)
            guard cur >= prev else {
                throw BinaryFormatError.offsetsNotMonotone(section: section, index: i,
                                                           previous: prev, current: cur)
            }
            prev = cur
        }
        if let end, Int(prev) != end {
            throw BinaryFormatError.offsetsEndMismatch(section: section, last: prev, expected: end)
        }
        return prev
    }
}

// MARK: - Yazıcı

/// Little-endian yazıcı.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public var count: Int { bytes.count }
    public var data: Data { Data(bytes) }

    public mutating func reserveCapacity(_ n: Int) { bytes.reserveCapacity(n) }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { append(v) }
    public mutating func u32(_ v: UInt32) { append(v) }
    public mutating func u64(_ v: UInt64) { append(v) }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func append<S: Sequence>(contentsOf s: S) where S.Element == UInt8 {
        bytes.append(contentsOf: s)
    }

    /// Alfabe: skaler değerleri sırayla `u32` olarak.
    public mutating func alphabet<S: Sequence>(_ values: S) where S.Element == UInt32 {
        for v in values { u32(v) }
    }

    public mutating func replaceU64(at off: Int, _ v: UInt64) {
        for i in 0..<8 { bytes[off + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
    }
}

// MARK: - Ortak konteyner

/// Bütün formatların ortak çerçevesi.
///
/// ```
/// Başlık (headerSize bayt)
///   0              magic     u32
///   4              version   u16
///   6 …            formata özgü alanlar
///   headerSize−8   checksum  u64   FNV-1a, yük (headerSize…) üzerinden
/// ```
///
/// Formatlar yalnız **alanlarını** tanımlıyor; magic/sürüm/checksum doğrulaması
/// ve checksum'ın yazılması burada. Yedi formatın yedi ayrı doğrulayıcısı,
/// her birinde kesiklik kontrolünün ayrı ayrı doğru yazılmasına bel bağlamaktı.
public struct BinaryContainer: Sendable {
    public let magic: UInt32
    public let version: UInt16
    public let headerSize: Int

    public init(magic: UInt32, version: UInt16, headerSize: Int) {
        precondition(headerSize >= 14, "başlık magic + sürüm + checksum'ı taşımalı")
        self.magic = magic
        self.version = version
        self.headerSize = headerSize
    }

    /// Checksum başlığın **son** sekiz baytında.
    public var checksumOffset: Int { headerSize - 8 }

    /// Başlığı yazar: magic, sürüm, formata özgü alanlar, checksum yeri.
    ///
    /// `fields` sürümden sonraki alanları yazar; toplam başlık boyu tutmazsa
    /// üretim **durur** — yanlış boyda başlık okuyucuda her offset'i kaydırır.
    public func writer(fields: (inout ByteWriter) -> Void) -> ByteWriter {
        var w = ByteWriter()
        w.u32(magic)
        w.u16(version)
        fields(&w)
        w.u64(0)
        precondition(w.count == headerSize,
                     "başlık \(w.count) bayt, \(headerSize) olmalı")
        return w
    }

    /// Checksum'ı yük üzerinden hesaplayıp başlığa yazar.
    public func seal(_ w: ByteWriter) -> [UInt8] {
        var w = w
        w.replaceU64(at: checksumOffset, FNV1a.hash(w.bytes[headerSize...]))
        return w.bytes
    }

    /// Başlığı doğrular: boyut, magic, sürüm ve (isteğe bağlı) checksum.
    public func open(_ data: Data, verifyChecksum: Bool = true) throws -> ByteReader {
        let r = ByteReader(data)
        guard r.count >= headerSize else {
            throw BinaryFormatError.truncated(need: headerSize, have: r.count)
        }
        let m = try r.u32(0)
        guard m == magic else { throw BinaryFormatError.badMagic(m) }
        let v = try r.u16(4)
        guard v == version else { throw BinaryFormatError.unsupportedVersion(v) }
        if verifyChecksum {
            let stored = try r.u64(checksumOffset)
            let actual = r.checksum(from: headerSize)
            guard actual == stored else {
                throw BinaryFormatError.checksumMismatch(expected: stored, actual: actual)
            }
        }
        return r
    }
}

// MARK: - Alfabe üretimi

/// Sembol alfabesi: skaler değerler **sıralı**, sembol kimliği = indeks.
///
/// Okuyucu (`ByteReader.alphabet`) kesin artan sıra istiyor; üreticilerin
/// hepsi aynı kuralla kurması ancak kural tek yerdeyse garanti.
public struct ScalarAlphabet: Sendable {
    public let values: [UInt32]
    public let symbolOf: [UInt32: UInt16]

    public init<S: Sequence>(_ scalars: S) where S.Element == UInt32 {
        values = Array(Set(scalars)).sorted()
        var m = [UInt32: UInt16](minimumCapacity: values.count)
        for (i, v) in values.enumerated() { m[v] = UInt16(truncatingIfNeeded: i) }
        symbolOf = m
    }

    public var count: Int { values.count }
    public var scalars: [Unicode.Scalar] { values.compactMap(Unicode.Scalar.init) }
}
