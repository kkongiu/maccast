# Third-party notices

This repository is a fork of **mkchromecast**, distributed under the MIT
license (see `LICENSE`). Original code © 2017 Muammar El Khatib; modifications
© 2026 Gianluca Congiu.

## Upstream

- **mkchromecast** — MIT. Copyright (c) 2017 Muammar El Khatib.
  https://github.com/muammar/mkchromecast

## Runtime dependencies (installed by the user, not vendored here)

| Component | License |
|---|---|
| PyQt5 | **GPL-3.0** or commercial (Riverbank) |
| mutagen | **GPL-2.0-or-later** |
| PyGObject | LGPL-2.1-or-later |
| pychromecast | MIT |
| soco | MIT |
| psutil | BSD-3-Clause |
| netifaces | MIT |
| requests | Apache-2.0 |
| Flask | BSD-3-Clause |
| vidaa-control | MIT |
| yt-dlp | Unlicense |

## Vendored / bundled code

- `nodejs/` — externally maintained JavaScript, with its own licenses; see
  `nodejs/package.json` and `nodejs/package-lock.json`. Its dependency
  `webcast-osx-audio` is MIT.
- `notifier/` — `terminal-notifier`, MIT, except `Terminal.icns`
  (https://github.com/julienXX/terminal-notifier#license).
- `mkchromecast/getch` — `py-getch`, MIT
  (https://github.com/joeyespo/py-getch).
- `archive/` — externally maintained code kept from upstream; read the
  licenses inside that directory, as their terms may differ.
- `bin/audiodevice` — compiled from `tools/audiodevice/` (sources included in
  this repository).

## Binary distribution (important)

Source distribution of this fork is MIT. However, if you ship a bundle that
includes **PyQt5** and/or **mutagen**, the combined binary must be distributed
under the **GPL** (GPL-3.0 for PyQt5, GPL-2.0-or-later for mutagen) and you
must make the corresponding source available. Do not label such a bundle as
MIT-only.

## Trademarks

"Google Cast", "Chromecast", "Sonos", "YouTube", "Netflix", "RaiPlay",
"WhatsApp", "AirPlay" and other names are trademarks of their respective
owners. They are used descriptively to state compatibility; this project is not
affiliated with or endorsed by them.
