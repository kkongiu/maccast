#!/usr/bin/env bash
# Ricompila bin/audiodevice per l'architettura corrente (es. arm64 su Apple Silicon).
# Uso: ./tools/audiodevice/build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/bin/audiodevice"

clang -o "$OUT" \
  "$HERE/audiodevice.m" "$HERE/SSAudioDeviceCenter.m" \
  -fno-objc-arc \
  -framework Foundation -framework CoreAudio -framework Cocoa -framework IOKit \
  -Wno-deprecated-declarations

echo "Compilato: $OUT"
file "$OUT"
