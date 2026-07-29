#!/usr/bin/env bash
#
# Projeyi derleyip bağlı iPhone'a (kablolu veya kablosuz) yükler ve başlatır.
#
#   ./Tools/deploy.sh              → paketi yeniden üretir, derler, yükler, açar
#   ./Tools/deploy.sh --no-pack    → dil paketini yeniden üretme
#   ./Tools/deploy.sh --debug      → Debug (-Onone) — YALNIZ hata ayıklama için
#   ./Tools/deploy.sh --device ID  → belirli bir cihaz
#
# YAPILANDIRMA: varsayılan RELEASE. Eskiden Debug'dı ve bu ÖLÇÜLEBİLİR bir
# hataydı: decoder saf Swift beam search, `-Onone` altında tuş başına p50
# 12.44 ms / p95 19.21 ms ölçüldü — Release'te 0.95 / 1.41 ms. **13 kat**, ve
# sözleşmenin tuş başına p99 < 8 ms bütçesini 2.4 kat aşıyor. Yani günlük
# kullanılan telefona kurulan klavye, hissedilir biçimde yavaş bir derlemeydi.
# Debug hâlâ `--debug` ile alınabilir; hata ayıklarken sembol ve assertion
# gerekiyor.
#
# TEK SEFERLİK ÖN KOŞULLAR (script bunları yapamaz, kontrol eder):
#   1. iPhone'da "Bu bilgisayara güven"
#   2. iPhone: Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu → aç → yeniden başlat
#   3. Xcode → Settings → Accounts → Apple ID ekle (ücretsiz hesap yeterli)
#
# KABLOSUZ: Xcode 15+ eşleşmiş ve Geliştirici Modu açık cihazlarda ağ
# bağlantısını KENDİLİĞİNDEN kurar. "Connect via network" onay kutusu
# kaldırıldı; Devices listesinde cihaz adının yanındaki 🌐 simgesi bunu gösterir.
#
# NOT: ücretsiz (Personal Team) hesapla imzalanan uygulamalar 7 GÜN sonra
# açılmaz. Şirket/ücretli takımda 1 yıl.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/Apps/BestKeyboard.xcodeproj"
SCHEME="BestKeyboard"
APP_ID="com.sencagri.bestkeyboard"
CONFIG="Release"
BUILD_PACK=1
DEVICE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pack)  BUILD_PACK=0; shift ;;
    --debug)    CONFIG="Debug"; shift ;;
    # Geriye uyumluluk: eski çağrılar sessizce Debug'a düşmesin.
    --release)  CONFIG="Release"; shift ;;
    --device)   DEVICE_ID="$2"; shift 2 ;;
    -h|--help)  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bilinmeyen seçenek: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ─── 1. Ön koşullar ────────────────────────────────────────────────────────────

say "imzalama kimliği aranıyor"

# İPTAL EDİLMİŞ sertifikaları ele. Keychain'de eskimiş "Created via API"
# sertifikaları kalabiliyor ve ilk eşleşeni almak yanlış takımı seçtiriyor.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
           | grep "Apple Develop" \
           | grep -v "CSSMERR_TP_CERT_REVOKED" \
           | grep -v "CERT_EXPIRED" \
           | head -1)

if [[ -z "$IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "REVOKED"; then
    die "yalnız İPTAL EDİLMİŞ sertifika var.
     Xcode → Settings → Accounts → hesabı seç → 'Manage Certificates…' →
     '+' → 'Apple Development' ile yenisini üret."
  fi
  die "imzalama kimliği yok.
     Xcode → Settings → Accounts → '+' → Apple ID ekle.
     Ücretsiz hesap yeterli; Xcode 'Apple Development' sertifikasını kendisi üretir."
fi

CERT_NAME=$(sed -n 's/.*"\(.*\)"$/\1/p' <<<"$IDENTITY")
say "sertifika: $CERT_NAME"

TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" ]]; then
  # Takım kimliğini sertifikanın OU (Organizational Unit) alanından oku —
  # ada gömülü parantez içi değere güvenmek yerine.
  TEAM=$(security find-certificate -c "$CERT_NAME" -p 2>/dev/null \
         | openssl x509 -noout -subject 2>/dev/null \
         | tr ',/' '\n\n' | sed -n 's/^ *OU *= *//p' | head -1)
fi
[[ -n "$TEAM" ]] || die "takım kimliği çözülemedi. DEVELOPMENT_TEAM=XXXXXXXXXX ile elle ver."
say "takım: $TEAM"

# ─── 2. Cihazı bul ─────────────────────────────────────────────────────────────

say "cihaz aranıyor"
TMP=$(mktemp -t devicectl).json
xcrun devicectl list devices --json-output "$TMP" >/dev/null 2>&1 || true

# Cihaz adı boşluk içerebiliyor ("Çağrı iPhonu'u"), bu yüzden alanlar SEKME ile
# ayrılıp IFS sekmeye sabitlenerek okunuyor. Boşlukla ayırmak alanları kaydırıyordu.
DEVICE_INFO=$(python3 - "$TMP" "$DEVICE_ID" <<'PY_EOF'
import json, sys
path, want = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
try:
    devs = json.load(open(path)).get("result", {}).get("devices", [])
except Exception:
    devs = []
best = None
for d in devs:
    ident = d.get("identifier", "")
    if want and ident != want:
        continue
    cp, dp = d.get("connectionProperties", {}), d.get("deviceProperties", {})
    row = (ident, dp.get("name", "?"), cp.get("transportType", "?"),
           cp.get("pairingState", "?"))
    if row[3] == "paired":
        best = best or row
    elif best is None:
        best = row
print("\t".join(best or ("", "", "", "")))
PY_EOF
)
IFS=$'\t' read -r DEVICE_ID DEVICE_NAME TRANSPORT PAIRING <<<"$DEVICE_INFO"
rm -f "$TMP"

[[ -n "$DEVICE_ID" ]] || die "bağlı cihaz bulunamadı. Kabloyu tak veya kablosuzu etkinleştir."
say "cihaz: ${DEVICE_NAME} (${TRANSPORT}, ${PAIRING})"

if [[ "$PAIRING" != "paired" ]]; then
  die "cihaz eşleşmemiş.
     Kabloyla bağla, iPhone'da 'Bu bilgisayara güven' → parola.
     Ayrıca Geliştirici Modu açık olmalı:
       Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu → aç → yeniden başlat"
fi

if [[ "$TRANSPORT" == "wired" ]]; then
  warn "şu an kabloyla bağlı. Kabloyu çıkarınca da çalışması gerekir —
     Xcode 15+ eşleşmiş cihazlarda ağ bağlantısını kendiliğinden kuruyor
     (Devices listesinde cihazın yanındaki 🌐 simgesi)."
fi

# ─── 3. Dil paketi ─────────────────────────────────────────────────────────────

if [[ "$BUILD_PACK" == 1 ]]; then
  # Üretim tanımı TEK yerde: `build-packs.sh`.
  #
  # Burada elle `packbuild` çağırmak beş paketten yalnız birini üretiyordu ve
  # `--informal` bayrağı yoktu — yani deploy çalıştığı anda argo katmanı
  # sessizce paketten düşüyor, kısaltmalar korumasız kalıyordu (§8.5).
  "$REPO/Tools/build-packs.sh"
fi

# ─── 4. Derle ──────────────────────────────────────────────────────────────────

say "derleniyor ($CONFIG)"
DERIVED="$REPO/.build/xcode"
LOG=$(mktemp -t xcodebuild).log

# `set -o pipefail` ile grep'in çıkış kodu maskelemesini engelliyoruz;
# önceki sürüm derleme BAŞARISIZ olsa da yüklemeye devam ediyordu.
set +e
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  build >"$LOG" 2>&1
BUILD_RC=$?
set -e

grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$LOG" | head -15 || true

if [[ $BUILD_RC -ne 0 ]]; then
  if grep -q "CodeSign.*failed" "$LOG"; then
    die "imzalama başarısız — codesign özel anahtara erişemedi.
     Çıkan şifre diyaloğu LOGIN KEYCHAIN şifresini istiyor (macOS giriş şifren;
     şifreni kurtarma yoluyla sıfırladıysan ESKİ şifre).

     En pratik çözüm: projeyi bir kez Xcode'dan çalıştır —
       open $PROJECT
     Cihazı seç (üstteki hedef menüsü) ve ⌘R. Xcode sertifikayı kendisi
     ürettiği için anahtara genelde sorunsuz erişir. Bir kez başarılı olduktan
     sonra bu script de çalışır.

     Tam günlük: $LOG"
  fi
  die "derleme başarısız (çıkış kodu $BUILD_RC). Tam günlük: $LOG"
fi

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/BestKeyboard.app"
[[ -d "$APP" ]] || die "derleme çıktısı yok: $APP"
rm -f "$LOG"

# ─── 5. Yükle ve aç ────────────────────────────────────────────────────────────

say "yükleniyor"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | tail -4

say "başlatılıyor"
xcrun devicectl device process launch --device "$DEVICE_ID" "$APP_ID" 2>&1 | tail -2

cat <<EOF

$(printf '\033[1;32m✓ tamam\033[0m')

Klavyeyi ilk kez kullanacaksan telefonda:
  Ayarlar → Genel → Klavye → Klavyeler → Yeni Klavye Ekle → BestKeyboard

Uygulama içindeki "Klavye tezgahını aç" ekranı uzantıyı etkinleştirmeden de
çalışır; her tuşta maliyet dökümü ve ms gösterir.

Kabloyu çıkarıp aynı komutu çalıştırabilirsin — Xcode 15+ ağ bağlantısını
kendiliğinden kuruyor.
EOF
