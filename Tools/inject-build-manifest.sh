#!/bin/bash
# Derleme manifestini uygulama paketine yazar — plan v8 §2.8.
#
# ## Neden gerekli
#
# `RecordingView.codeRevision` `Info.plist`'ten `BKCodeRevision` okuyordu ama
# o anahtarı **kimse yazmıyordu**: her kayıt `unknown` ile başlıyordu. Yani
# kaydın hangi koddan çıktığı hiç bilinmiyordu ve replay farkının "kod
# değişikliği mi, ortam mı" sorusu baştan cevapsızdı.
#
# ## Neden commit tek başına yetmiyor
#
# Temiz bir commit **tekil binary tanımlamıyor**: aynı kaynak farklı Swift
# sürümü, target triple, mimari ya da optimizasyon seviyesinde farklı sonuç
# verebilir — ve bu fark kod regresyonu sanılırdı. Kirli ağaç ise commit'in
# tamamen yalan söylediği durum.
#
# ## Neden `Info.plist` değil, ayrı dosya
#
# Xcode'un yapı sistemi görev tabanlı ve **faz sırası garanti değil**:
# `Info.plist`'e yazdığımız anahtarlar, sonradan koşan `ProcessInfoPlistFile`
# tarafından siliniyordu — sessizce, hatasız. Ayrı bir dosyayı ise başka hiçbir
# görev üretmiyor, dolayısıyla üzerine yazılamıyor.
set -euo pipefail

DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BuildManifest.plist"
mkdir -p "$(dirname "$DEST")"

cd "${SRCROOT}"

# `git` yoksa ya da burası bir depo değilse: **uydurmuyoruz**. `unknown`
# yazmak, bilinmeyeni bilinen gibi göstermekten iyi.
if REV=$(git rev-parse --short=12 HEAD 2>/dev/null); then
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        DIRTY="true"
        # Özet **içerikten** çıkarılıyor, `git status` çıktısından değil.
        # Dosya listesi aynı kaldığı sürece iki farklı değişiklik aynı digest'i
        # üretiyordu — yani `.dirty(digest:)` "hangi kirli ağaç" olgusunu hiç
        # taşımıyordu.
        #
        # `git diff --binary HEAD` staged + unstaged içeriği veriyor; takip
        # edilmeyen dosyalar orada yok, o yüzden yolları sıralı sırayla ve
        # içerikleriyle ekleniyor. Sıralama `LC_ALL=C` ile sabit: locale'e bağlı
        # sıra, aynı ağaçta farklı digest üretirdi.
        DIGEST=$(
            {
                git diff --binary HEAD
                git ls-files --others --exclude-standard -z \
                  | LC_ALL=C sort -z \
                  | while IFS= read -r -d '' f; do
                        printf '%s\0' "$f"
                        cat -- "$f" 2>/dev/null
                    done
            } | shasum -a 256 | cut -c1-16
        )
    else
        DIRTY="false"
        DIGEST=""
    fi
else
    REV="unknown"
    DIRTY="true"
    DIGEST=""
fi

# Xcode script fazlarında `CURRENT_ARCH` literal olarak `undefined_arch`
# geliyor: faz mimari başına değil, hedef başına bir kez koşuyor. Gerçek bilgi
# `ARCHS`'te.
ARCH="${CURRENT_ARCH:-}"
if [ -z "$ARCH" ] || [ "$ARCH" = "undefined_arch" ]; then ARCH="${ARCHS:-}"; fi

cat > "$DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>codeRevision</key><string>${REV}</string>
    <key>dirty</key><string>${DIRTY}</string>
    <key>sourceDigest</key><string>${DIGEST}</string>
    <key>swiftVersion</key><string>${SWIFT_VERSION:-}</string>
    <key>targetTriple</key><string>${LLVM_TARGET_TRIPLE_OS_VERSION:-}${LLVM_TARGET_TRIPLE_SUFFIX:-}</string>
    <key>arch</key><string>${ARCH}</string>
    <key>optimization</key><string>${SWIFT_OPTIMIZATION_LEVEL:-}</string>
    <key>xcodeVersion</key><string>${XCODE_VERSION_ACTUAL:-}</string>
</dict>
</plist>
PLIST

plutil -lint "$DEST" > /dev/null
echo "manifest: $REV dirty=$DIRTY ${SWIFT_OPTIMIZATION_LEVEL:-} $ARCH"
