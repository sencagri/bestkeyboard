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
# gereksiz iş. Cihaz yalnız JSON yazar; paketleme burada.

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
  DEVICE_ID="$(python3 - "$TMP_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get("result",{}).get("devices",[]):
    state=x.get("connectionProperties",{}).get("tunnelState","")
    if state in ("connected","available"):
        print(x["identifier"]); break
PY
)"
  [[ -n "$DEVICE_ID" ]] || die "bağlı cihaz bulunamadı. --device ID ile elle ver."
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RAW="$OUT/$STAMP"
mkdir -p "$RAW"

say "kayıtlar çekiliyor ($DEVICE_ID)"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$APP_ID" \
  --source "Library/Application Support/typing-sessions" \
  --destination "$RAW" \
  --json-output "$TMP_JSON" >/dev/null 2>&1 \
  || die "çekme başarısız. Uygulama kurulu mu, hiç kayıt var mı?"

# Doğrulama: dosya sayısı ve JSON geçerliliği. Boş bir zip'i "başarılı" saymak
# en pahalı hata olurdu — cihaz verisi tekrar toplanamaz.
COUNT="$(find "$RAW" -name '*.json' | wc -l | tr -d ' ')"
[[ "$COUNT" -gt 0 ]] || die "hiç kayıt bulunamadı ($RAW boş)"

BAD=0
while IFS= read -r f; do
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null || {
    echo "  bozuk: $f" >&2; BAD=$((BAD+1))
  }
done < <(find "$RAW" -name '*.json')
[[ "$BAD" -eq 0 ]] || die "$BAD dosya bozuk — zip üretilmedi"

say "$COUNT kayıt doğrulandı"

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
