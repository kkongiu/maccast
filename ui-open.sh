#!/usr/bin/env bash
# Apre l'interfaccia Maccast. Se il server e' gia' attivo, apre solo il browser.
set -euo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="http://127.0.0.1:8770/"

if curl -s -o /dev/null --max-time 1 "$URL"; then
  [[ "${MACCast_NO_OPEN:-0}" == "1" ]] || open "$URL"
  exit 0
fi

cd "$DIR"
MACCast_NO_BROWSER=1 nohup ./maccast.sh ui >/tmp/maccast-ui.log 2>&1 &

for _ in $(seq 1 40); do
  sleep 0.5
  if curl -s -o /dev/null --max-time 1 "$URL"; then
    [[ "${MACCast_NO_OPEN:-0}" == "1" ]] || open "$URL"
    exit 0
  fi
done

echo "Impossibile avviare Maccast UI. Log: /tmp/maccast-ui.log"
open /tmp/maccast-ui.log
exit 1
