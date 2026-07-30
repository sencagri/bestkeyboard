#!/usr/bin/env bash
#
# Cihazdaki yazım kayıtlarını Mac'e indirir ve zip'ler.
#
#   ./Tools/pull-sessions.sh                → varsayılan cihazdan çek
#   ./Tools/pull-sessions.sh --device ID    → belirli bir cihaz
#   ./Tools/pull-sessions.sh --out DIR      → hedef klasör (varsayılan: Data/sessions)
#   ./Tools/pull-sessions.sh --keep         → zip'ledikten sonra ham klasörü silme
#
# Kayıtlar uygulamanın `Application Support/typing-sessions` klasöründe durur
# (sözleşme §12.9: ham dokunma koordinatı kişisel veridir, `Documents` değil).
#
# NEDEN ZIP MAC'TE ÜRETİLİYOR: uygulamanın zip üretmesi gereksiz kod ve
# gereksiz iş. Cihaz yalnız kaydı yazar; paketleme burada.
#
# İKİ BİÇİM: eski kayıtlar `*.json` (şema v2), yenileri `*.bkj` (append-only
# konteyner, şema v3). Yalnız birine bakmak diğerini GÖRÜNMEZ yapardı —
# kullanıcının topladığı veri sessizce zip'in dışında kalırdı.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="com.sencagri.bestkeyboard"
DEVICE_ID=""
OUT="$REPO/Data/sessions"
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_ID="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bilinmeyen seçenek: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null || die "xcrun yok"

# Cihaz seçimi — deploy.sh ile aynı mantık, JSON üzerinden (stdout ayrıştırmak
# Xcode sürümleri arasında kırılgan).
TMP_JSON="$(mktemp -t bk-devices).json"
trap 'rm -f "$TMP_JSON"' EXIT

if [[ -z "$DEVICE_ID" ]]; then
  say "cihaz aranıyor"
  xcrun devicectl list devices --json-output "$TMP_JSON" >/dev/null 2>&1 \
    || die "cihaz listesi alınamadı"
  # Ölçüt **eşleşme**, tünel durumu değil — `deploy.sh` ile aynı kural.
  #
  # Önce `tunnelState in (connected, available)` aranıyordu. Kablosuz bir cihazda
  # tünel kullanılmadığı sürece `disconnected` duruyor ve `devicectl` onu ilk
  # çağrıda kendisi kuruyor: yani deploy başarılı olduktan hemen sonra çekme
  # "bağlı cihaz bulunamadı" diyordu. İki scriptin farklı ölçüt kullanması,
  # kaydı toplayıp çekemediğimiz bir durum üretiyordu.
  DEVICE_ID="$(python3 - "$TMP_JSON" <<'PY_DEV'
import json,sys
try:
    devs=json.load(open(sys.argv[1])).get("result",{}).get("devices",[])
except Exception:
    devs=[]
best=""
for x in devs:
    ident=x.get("identifier","")
    if not ident:
        continue
    if x.get("connectionProperties",{}).get("pairingState")=="paired":
        best=best or ident
    elif not best:
        best=ident
print(best)
PY_DEV
)"
  [[ -n "$DEVICE_ID" ]] || die "bağlı cihaz bulunamadı. --device ID ile elle ver."
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RAW="$OUT/$STAMP"
mkdir -p "$RAW"

# **İki konteyner.** Kayıt ekranı uygulamanın kabına, klavyenin yakaladığı
# dilimler uzantınınkine yazıyor. Uzantı "Full Access" istemiyor (ağ erişimi ve
# iOS'un uyarısı gereksiz), dolayısıyla app group da yok ve iki kap ayrı.
# `devicectl` ikisine de erişebiliyor.
say "kayıtlar çekiliyor ($DEVICE_ID)"
PULLED=0
for CONTAINER in "$APP_ID" "$APP_ID.keyboard"; do
  DEST="$RAW"
  [[ "$CONTAINER" == "$APP_ID" ]] || DEST="$RAW/keyboard"
  mkdir -p "$DEST"
  if xcrun devicectl device copy from \
      --device "$DEVICE_ID" \
      --domain-type appDataContainer \
      --domain-identifier "$CONTAINER" \
      --source "Library/Application Support/typing-sessions" \
      --destination "$DEST" \
      --json-output "$TMP_JSON" >/dev/null 2>&1; then
    PULLED=$((PULLED + 1))
  else
    # Kabın olmaması **hata değil**: klavyeden hiç dilim yakalanmamış olabilir.
    rmdir "$DEST" 2>/dev/null || true
  fi
done
[[ $PULLED -gt 0 ]] || die "çekme başarısız. Uygulama kurulu mu, hiç kayıt var mı?"

# Doğrulama: dosya sayısı ve **yapısal** geçerlilik. Boş bir zip'i "başarılı"
# saymak en pahalı hata olurdu — cihaz verisi tekrar toplanamaz.
#
# Burada yapılan yalnız yüzeysel kontrol: JSON ayrışıyor mu, konteyner sihirli
# sayıyı taşıyor mu. Derin doğrulama (frame checksum'ları, şema, katlama)
# `kbbench`in işi ve o `RecordingLibrary`yi kullanıyor — biçimi kabukta
# yeniden uygulamak, iki okuyucunun sessizce ayrışması demekti.
JSON_COUNT="$(find "$RAW" -name '*.json' | wc -l | tr -d ' ')"
BKJ_COUNT="$(find "$RAW" -name '*.bkj' | wc -l | tr -d ' ')"
COUNT=$((JSON_COUNT + BKJ_COUNT))
[[ "$COUNT" -gt 0 ]] || die "hiç kayıt bulunamadı ($RAW boş)"

BAD=0
while IFS= read -r f; do
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null || {
    echo "  bozuk (json): $f" >&2; BAD=$((BAD+1))
  }
done < <(find "$RAW" -name '*.json')

while IFS= read -r f; do
  # `BKJ1` + konteyner sürümü + şema = 8 bayt başlık; altındaki her şey yarım
  # yazılmış bir dosya demek.
  MAGIC="$(head -c 4 "$f" 2>/dev/null || true)"
  SIZE="$(wc -c < "$f" | tr -d ' ')"
  if [[ "$MAGIC" != "BKJ1" || "$SIZE" -lt 8 ]]; then
    echo "  bozuk (konteyner): $f" >&2; BAD=$((BAD+1))
  fi
done < <(find "$RAW" -name '*.bkj')

[[ "$BAD" -eq 0 ]] || die "$BAD dosya bozuk — zip üretilmedi"

say "$COUNT kayıt doğrulandı ($JSON_COUNT eski JSON · $BKJ_COUNT konteyner)"

ZIP="$OUT/typing-sessions-$STAMP.zip"
(cd "$RAW" && zip -qr "$ZIP" .)
[[ -f "$ZIP" ]] || die "zip üretilemedi"

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$RAW"; fi

python3 - "$ZIP" "$COUNT" <<'PY'
import sys, os
z, n = sys.argv[1], sys.argv[2]
print("\n\033[1;32m✓ tamam\033[0m\n")
print(f"  {n} kayıt · {os.path.getsize(z)/1024:.0f} KB")
print(f"  {z}\n")
print("  İncelemek için:  swift run -c release --package-path Tools/kbbench kbbench --sessions <klasör>")
PY
