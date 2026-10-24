# Upstream and changes

## Upstream

- Project: **mkchromecast**
- Repository: https://github.com/muammar/mkchromecast
- Author: Muammar El Khatib
- License: MIT (see `LICENSE`)
- Base commit: `aad239c9adb12fbed9a841d15d4a6d6ddc5de5e8` (2026-09-14,
  "Merge pull request #484 from brycesub/wayland")

This repository is a fork of that commit. Files not listed below are unchanged
from upstream, so `git blame` and `git log` still attribute them to their
original authors.

## Changes in this fork

### macOS support

- Platform plumbing: `video.py` passes the detected platform to the pipeline
  builder.
- `mkchromecast/pipeline_builder.py`: AVFoundation screen capture for macOS
  (`_macos_screencast_command`), automatic detection of the "Capture screen"
  device index, override via `MKCHROMECAST_SCREEN_INDEX`.
- `mkchromecast/_arg_parsing.py`: default streaming port is 5100 on Darwin
  (macOS AirPlay Receiver occupies 5000).
- `mkchromecast/audio_devices.py`: `audiodevice` is located relative to the
  package instead of the current working directory; helper refactor.
- `bin/audiodevice`: rebuilt for arm64 (Apple Silicon). Source and build script
  in `tools/audiodevice/`.
- `maccast.sh`: macOS launcher (CLI + web UI), resolves symlinks and adds
  Homebrew/pip user paths.
- `macapp/`: SwiftUI wrapper (`Maccast.app`) that starts the Python backend on
  `127.0.0.1:8770`.

### Streaming

- `mkchromecast/stream_infra.py`: video reads use at least 64 KiB blocks (the
  audio-tuned 64-byte default added seconds of latency); the monitor loop
  tolerates a missing pid file and falls back to `getppid()`.

### YouTube

- `mkchromecast/audio.py`: calls `sys.executable -m yt_dlp` (no PATH issues),
  requests a combined `best[ext=mp4]/best` stream and retries with the
  `android` player client, which fixes "The page needs to be reloaded"
  (SABR/PO-token) failures.

### New features

- `mkchromecast/dlna.py`: DLNA/UPnP AVTransport output.
- VIDAA/Hisense control (app launch, remote keys, sources) via MQTT-over-TLS.
- `webui.py`, `templates/index.html`, `ui-open.sh`: local Flask web UI on
  `127.0.0.1:8770`.
- `requirements.txt`: adds `vidaa-control` (MIT).
- `.gitignore`: ignores the built `Maccast.app/`.

### Documentation

- `README.maccast.md` (Italian usage notes), `MIGLIORAMENTI.md` (roadmap).
- `README.md`: fork banner added at the top; the rest is the upstream README.

### Deliberately not changed

- `archive/` and `images/` are kept as in upstream.
- `mkchromecast.desktop`, `mkchromecast.1`, `setup.py`, `version.py` keep the
  upstream identity (0.3.9) to stay mergeable with upstream.

## Syncing with upstream

```bash
git remote add upstream https://github.com/muammar/mkchromecast.git
git fetch upstream
git checkout maccast
git rebase upstream/master   # or merge
```

## License notes

The fork is MIT, like upstream. Two runtime dependencies are copyleft:
**PyQt5** (GPL-3.0 or commercial) and **mutagen** (GPL-2.0-or-later). Running
from source and letting the user install them keeps this repository MIT; a
distributed bundle that includes them must comply with the GPL, with the
corresponding source available. See `THIRD-PARTY-NOTICES.md`.
