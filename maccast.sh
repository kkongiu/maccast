#!/usr/bin/env bash
# maccast - launcher per mkchromecast (macOS / Apple Silicon)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Risolve eventuali symlink (es. /opt/homebrew/bin/maccast)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  TMPDIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$TMPDIR/$SOURCE"
done
DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# yt-dlp installato con pip --user + Homebrew (ffmpeg)
export PATH="$HOME/Library/Python/3.9/bin:/opt/homebrew/bin:$PATH"

usage() {
  cat <<'EOF'
maccast - cast verso Google Cast / Chromecast da macOS

Uso:
  ./maccast.sh ui                              # apri l'interfaccia web
  ./maccast.sh -d                              # cerca i dispositivi
  ./maccast.sh --video --screencast            # trasmetti lo schermo
  ./maccast.sh -y "<URL youtube>" --video      # trasmetti un video YouTube
  ./maccast.sh --video -i /path/video.mp4      # trasmetti un file locale
  ./maccast.sh --source-url "<url>" --video --mtype video/mp4

Opzioni comuni:
  --resolution 1080p|720p|uhd ...   risoluzione video
  -n "<nome dispositivo>"           scegli il dispositivo per nome
  -s                                scegli il dispositivo interattivamente
  --control                         controlli interattivi (solo in un TTY)
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

if [[ "$1" == "ui" ]]; then
  exec python3 -u "$DIR/webui.py"
fi

exec python3 -u "$DIR/bin/mkchromecast" "$@"
