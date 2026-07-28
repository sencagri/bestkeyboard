#!/usr/bin/env bash
#
# codesign'ın imzalama anahtarına Xcode'suz erişmesini sağlar.
#
#   ./Tools/fix-signing.sh
#
# NEDEN GEREKLİ
# Xcode bir imzalama sertifikası ürettiğinde, özel anahtarın erişim listesine
# (ACL) yalnız kendi araçlarını ekleyebiliyor. Terminal'den çağrılan
# /usr/bin/codesign bu listede olmadığı için macOS her seferinde bir onay
# diyaloğu açıyor ve "Her Zaman İzin Ver" seçilmediyse imzalama başarısız oluyor.
#
# `security set-key-partition-list` anahtarın bölüm listesine `codesign:`
# ekleyerek bu diyaloğu kalıcı olarak kaldırır. CI ortamlarında standart çözüm.
#
# Şifre TERMİNALDE sorulur, ekrana yazılmaz ve hiçbir yere kaydedilmez.

set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

say()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$KEYCHAIN" ]] || die "login keychain bulunamadı: $KEYCHAIN"

say "imzalama kimlikleri"
security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /' || true
echo

# ─── 1. Şifre doğru mu? ────────────────────────────────────────────────────────
#
# Bu adım GUI diyaloğunu tamamen atlar. Başarısız olursa sorun şifrenin
# kendisidir; başarılı olursa sorun yalnızca ACL'dir.

cat <<'EOF'
Login keychain şifresi sorulacak.

  • Bu normalde macOS GİRİŞ ŞİFRENDİR.
  • Şifreni bir zamanlar Apple ID / kurtarma modu / başka bir admin hesabıyla
    SIFIRLADIYSAN keychain eski şifrede kalmıştır — o zaman ESKİ şifredir.
  • Yazarken ekranda hiçbir şey görünmez, bu normaldir.

EOF

read -r -s -p "Login keychain şifresi: " PW
echo

if ! security unlock-keychain -p "$PW" "$KEYCHAIN" 2>/dev/null; then
  unset PW
  die "şifre kabul edilmedi — keychain şifresi macOS şifrenden AYRIŞMIŞ.

     Düzeltme yolları:

     A) Eski şifreni hatırlıyorsan hizala:
          security set-keychain-password $KEYCHAIN
        (önce eski, sonra yeni olarak macOS şifreni gir)

     B) Hatırlamıyorsan keychain'i sıfırla — İÇİNDEKİ TÜM KAYITLI ŞİFRELER
        VE SERTİFİKALAR SİLİNİR:
          Anahtar Zinciri Erişimi → Ayarlar → Varsayılan Anahtar Zincirlerimi Sıfırla
        Sonra imzalama sertifikasını yeniden üretmek gerekir:
          Xcode → Settings → Accounts → Manage Certificates… → '+' → Apple Development

     Not: (B) yolunda Xcode'a bir kez daha ihtiyaç var; başka yolu yok çünkü
     sertifikayı Apple'ın sunucusundan yalnız o alabiliyor."
fi

ok "şifre doğru, keychain açıldı"

# ─── 2. ACL'yi düzelt ──────────────────────────────────────────────────────────

say "codesign'a anahtar erişimi veriliyor"
if security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s -k "$PW" "$KEYCHAIN" >/dev/null 2>&1; then
  ok "erişim verildi — codesign artık diyalog açmayacak"
else
  unset PW
  die "set-key-partition-list başarısız. Tam hata için elle çalıştır:
       security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <şifre> $KEYCHAIN"
fi
unset PW

# ─── 3. Doğrula ────────────────────────────────────────────────────────────────

say "gerçek bir imzalama denemesi"
TMPBIN=$(mktemp -d)/test
cp /bin/echo "$TMPBIN"
IDENT=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Develop" | grep -v REVOKED | head -1 \
        | awk '{print $2}')

if [[ -z "$IDENT" ]]; then
  warn "geçerli sertifika bulunamadı, doğrulama atlandı"
else
  if codesign --force --sign "$IDENT" "$TMPBIN" 2>/dev/null; then
    ok "imzalama çalışıyor — Xcode'a gerek yok"
    echo
    echo "Şimdi:  ./Tools/deploy.sh"
  else
    die "imzalama hâlâ başarısız. Elle dene ve hatayı gör:
       codesign --force --sign $IDENT $TMPBIN"
  fi
fi
rm -rf "$(dirname "$TMPBIN")"
