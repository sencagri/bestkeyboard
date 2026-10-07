import Foundation
import Testing
import KBFoundation
import KBGeometry

/// Ortak ikili dosya katmanı — `BinaryContainer`, `ByteReader`, `ByteWriter`,
/// `ScalarAlphabet`, `AtomicFile`.
///
/// Yedi format bu katmandan geçiyor; burada bozulan bir sınır kontrolü yedisini
/// birden bozar. Format testleri ayrıca kendi yapısal durumlarını sınıyor.
@Suite("İkili dosya katmanı")
struct BinaryIOTests {

    private let format = BinaryContainer(magic: 0x3154_5354, version: 3, headerSize: 16)

    private func sealed(payload: [UInt8]) -> [UInt8] {
        var w = format.writer { $0.u16(0) }
        w.append(contentsOf: payload)
        return format.seal(w)
    }

    @Test("Başlık düzeni: magic · sürüm · alanlar · checksum (son 8 bayt)")
    func headerLayout() throws {
        let bytes = sealed(payload: [1, 2, 3])
        #expect(bytes.count == 19)
        #expect(Array(bytes[0..<4]) == [0x54, 0x53, 0x54, 0x31])
        #expect(Array(bytes[4..<6]) == [3, 0])
        let r = try format.open(Data(bytes))
        #expect(try r.u64(8) == FNV1a.hash([1, 2, 3] as [UInt8]))
    }

    @Test("Ortak hatalar tek tipte: magic, sürüm, checksum, kesiklik")
    func commonErrors() throws {
        let good = sealed(payload: [9, 9])

        var magic = good; magic[0] ^= 0xFF
        #expect(throws: BinaryFormatError.badMagic(0x3154_53AB)) {
            try format.open(Data(magic))
        }
        var version = good; version[4] = 7
        #expect(throws: BinaryFormatError.unsupportedVersion(7)) {
            try format.open(Data(version))
        }
        var payload = good; payload[16] ^= 1
        #expect(throws: BinaryFormatError.self) { try format.open(Data(payload)) }
        // Checksum kapalıyken bozuk yük **geçer** — doğrulama çağıranın kararı.
        _ = try format.open(Data(payload), verifyChecksum: false)
        #expect(throws: BinaryFormatError.truncated(need: 16, have: 10)) {
            try format.open(Data(good.prefix(10)))
        }
    }

    @Test("Okuyucu sınır dışını hata olarak bildirir, çökmez")
    func readerBounds() throws {
        let r = ByteReader([1, 0, 0, 0] as [UInt8])
        #expect(try r.u32(0) == 1)
        #expect(throws: BinaryFormatError.truncated(need: 5, have: 4)) { try r.u16(3) }
        #expect(throws: BinaryFormatError.self) { try r.u8(-1) }
    }

    @Test("Dilimlenmiş Data: offset dilimin başına göreli")
    func slicedData() throws {
        let whole = Data([0xAA, 0x34, 0x12])
        let slice = whole[1...]
        #expect(ByteReader(slice).unchecked(UInt16.self, 0) == 0x1234)
        #expect(slice.littleEndian(UInt16.self, at: 0) == 0x1234)
    }

    @Test("Yazıcı little-endian, okuyucuyla gidiş-dönüş")
    func roundTrip() throws {
        var w = ByteWriter()
        w.u8(0xAB); w.u16(0x1234); w.u32(0xDEAD_BEEF); w.u64(0x0102_0304_0506_0708)
        w.f32(-1.5)
        #expect(Array(w.bytes[1..<3]) == [0x34, 0x12])
        let r = ByteReader(w.bytes)
        #expect(try r.u8(0) == 0xAB)
        #expect(try r.u16(1) == 0x1234)
        #expect(try r.u32(3) == 0xDEAD_BEEF)
        #expect(try r.u64(7) == 0x0102_0304_0506_0708)
        #expect(try r.f32(15) == -1.5)
    }

    @Test("Alfabe: sıralı üretim, kesin artan okuma")
    func alphabet() throws {
        let a = ScalarAlphabet([0x62, 0x61, 0x62, 0x131])
        #expect(a.values == [0x61, 0x62, 0x131])
        #expect(a.symbolOf[0x131] == 2)

        var w = ByteWriter()
        w.alphabet(a.values)
        #expect(try ByteReader(w.bytes).alphabet(at: 0, count: 3).map(\.value) == a.values)

        var unsorted = ByteWriter()
        unsorted.alphabet([0x62, 0x61])
        #expect(throws: BinaryFormatError.alphabetNotSorted(index: 1)) {
            try ByteReader(unsorted.bytes).alphabet(at: 0, count: 2)
        }
        var surrogate = ByteWriter()
        surrogate.u32(0xD800)
        #expect(throws: BinaryFormatError.badScalar(0xD800)) {
            try ByteReader(surrogate.bytes).alphabet(at: 0, count: 1)
        }
    }

    @Test("CSR offset'leri: sıfırdan başlar, monoton, sonu eleman sayısı")
    func offsets() throws {
        func reader(_ v: [UInt32]) -> ByteReader {
            var w = ByteWriter(); for x in v { w.u32(x) }; return ByteReader(w.bytes)
        }
        #expect(try reader([0, 2, 2, 5]).offsets(at: 0, count: 3, section: "t", end: 5) == 5)
        #expect(throws: BinaryFormatError.offsetsNotZeroBased(section: "t", value: 1)) {
            try reader([1, 2]).offsets(at: 0, count: 1, section: "t")
        }
        #expect(throws: BinaryFormatError.offsetsNotMonotone(section: "t", index: 2,
                                                             previous: 3, current: 2)) {
            try reader([0, 3, 2]).offsets(at: 0, count: 2, section: "t")
        }
        #expect(throws: BinaryFormatError.offsetsEndMismatch(section: "t", last: 3, expected: 4)) {
            try reader([0, 3]).offsets(at: 0, count: 1, section: "t", end: 4)
        }
        // Boş bölüm: tek sıfır.
        #expect(try reader([0]).offsets(at: 0, count: 0, section: "t", end: 0) == 0)
    }

    @Test("Sembol adımı bayt adımıyla aynı sabitleri kullanıyor")
    func fnvSymbolStep() {
        let h = FNV1a.step(FNV1a.offsetBasis, symbol: 0x0131)
        #expect(h == (FNV1a.offsetBasis ^ 0x0131) &* FNV1a.prime)
        #expect(FNV1a.step(FNV1a.offsetBasis, symbol: 7) == FNV1a.step(FNV1a.offsetBasis, 7))
    }

    /// Paket üreticisinin kopyası hedef yokken `replaceItemAt`'e düşüyordu.
    @Test("Atomik yayımlama: hedef yokken de, varken de")
    func atomicPublish() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-atomic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("nested/p.bin")

        try AtomicFile.publish(Data([1]), to: target)
        #expect(FileManager.default.contents(atPath: target.path) == Data([1]))
        try AtomicFile.publish(Data([2, 3]), to: target)
        #expect(FileManager.default.contents(atPath: target.path) == Data([2, 3]))
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: target.deletingLastPathComponent().path)
        #expect(leftovers == ["p.bin"], "geçici dosya kalmamalı")

        try AtomicFile.protectPersonalData(target)
        let excluded = try target.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(excluded.isExcludedFromBackup == true)

        try AtomicFile.removeIfExists(target)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try AtomicFile.removeIfExists(target)       // yokken sessiz
    }

    /// Sınır kontrolü **taşmaya ve negatife dayanıklı**: dosyadan gelen bir
    /// değer `offset + size` toplamını taşırınca tuzağa düşülüyordu, negatif
    /// uzunluk dilimlemede çöküyordu. İkisi de `truncated` olmalı.
    @Test("Taşan ve negatif offset/boyut hata, çöküş değil")
    func overflowingBoundsThrow() throws {
        let r = ByteReader([1, 2, 3, 4, 5, 6, 7, 8])
        #expect(throws: BinaryFormatError.self) { try r.u64(Int.max) }
        #expect(throws: BinaryFormatError.self) { try r.u32(Int.max - 2) }
        #expect(throws: BinaryFormatError.self) { try r.u8(-1) }
        #expect(throws: BinaryFormatError.self) { try r.requireRange(2, -1) }
        #expect(throws: BinaryFormatError.self) { try r.requireRange(9, 0) }
        #expect(throws: BinaryFormatError.self) { try r.utf8(4, length: -2) }
        #expect(throws: BinaryFormatError.self) {
            try r.requireArray(at: 0, count: Int.max / 2, stride: 4)
        }
        #expect(throws: BinaryFormatError.self) {
            try r.requireArray(at: 0, count: -1, stride: 4)
        }
        #expect(throws: BinaryFormatError.self) { try r.alphabet(at: 0, count: -1) }
        #expect(throws: BinaryFormatError.self) { try r.alphabet(at: 0, count: Int.max) }
        #expect(throws: BinaryFormatError.self) {
            try r.offsets(at: 0, count: Int.max, section: "x")
        }
        // Sınırda geçerli okumalar hâlâ çalışıyor.
        try r.requireRange(8, 0)
        try r.requireArray(at: 0, count: 2, stride: 4)
        #expect(try r.u64(0) == 0x0807_0605_0403_0201)
        // Negatif başlangıçlı checksum çökmüyor; tüm veriyi kapsıyor.
        #expect(r.checksum(from: -5) == r.checksum(from: 0))
    }
}
