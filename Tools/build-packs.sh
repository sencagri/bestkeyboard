#!/usr/bin/env bash
#
# Dil paketlerinin **tek** üretim tanımı.
#
#   ./Tools/build-packs.sh
#
# Neden ayrı bir betik: `deploy.sh` paketleri kendi içinde üretiyordu ve
# yalnız `tr-TR.bkt`'yi, üstelik `--informal` bayrağı olmadan. Yani deploy
# çalıştığı anda argo katmanı sessizce paketten düşüyor ve kısaltmalar
# korumasız kalıyordu (§8.5: `slm`'nin otomatik açılmamasının tek güvencesi
# sözlükte olması).
#
# Altı paket var ve hepsi aynı yerden üretilmeli:
#
#   tr-TR.bkt           form listesi + gayrıresmî katman (BİRLEŞİK, §7)
#   tr-TR.bkr           kök sözlüğü (morfoloji)
#   tr-TR.bkc           literal kanalı karakter n-gram modeli
#   tr-TR.bkx           genişletme haritası
#   en-US.bkt           ikinci dil
#   en-US.bkc           ikinci dilin karakter modeli

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PB=("swift" "run" "-c" "release" "--package-path" "$REPO/Tools/packbuild" "packbuild")
LP="$REPO/LanguagePacks"

say() { printf "\033[1;36m▸ %s\033[0m\n" "$1"; }

say "form listesi + gayrıresmî katman"
"${PB[@]}" "$LP/tr-TR/wordlist.tsv" "$LP/tr-TR/tr-TR.bkt" \
  --informal "$LP/tr-TR/informal.tsv" | tail -4

say "kök sözlüğü"
"${PB[@]}" --roots "$LP/tr-TR/roots.tsv" "$LP/tr-TR/tr-TR.bkr" | tail -3

say "literal kanalı (tr)"
"${PB[@]}" --charngram "$LP/tr-TR/wordlist.tsv" "$LP/tr-TR/tr-TR.bkc" | tail -3

say "genişletme haritası"
"${PB[@]}" --expansions "$LP/tr-TR/expansions.tsv" "$LP/tr-TR/tr-TR.bkx" | tail -3

say "ikinci dil (en)"
"${PB[@]}" "$LP/en-US/wordlist.tsv" "$LP/en-US/en-US.bkt" | tail -3
"${PB[@]}" --charngram "$LP/en-US/wordlist.tsv" "$LP/en-US/en-US.bkc" | tail -3

printf "\033[1;32m✓ tüm paketler üretildi\033[0m\n"
