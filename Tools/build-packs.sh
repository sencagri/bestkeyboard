#!/usr/bin/env bash
#
# Dil paketlerinin üretimi.
#
#   ./Tools/build-packs.sh
#
# Plan (hangi paket, hangi kaynaktan, hangi bayrakla) **packbuild'de**:
# `packbuild --all` onu koşturuyor, `packbuild --print-plan` listeliyor. Betik
# paket düzenini (klasörler, yerel adları, uzantılar) bilerek bilmiyor — o
# bilgi `PackPaths`'te ve burada yeniden yazılırsa bir ad değiştiğinde betik
# sessizce eski dosyaları üretirdi.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift run -c release --package-path "$REPO/Tools/packbuild" packbuild \
  --all "$REPO/LanguagePacks"
