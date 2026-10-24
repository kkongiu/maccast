# Maccast

Trasmissione dello schermo, di video YouTube e di file locali dal Mac a
dispositivi Google Cast / Chromecast. Basato su
[mkchromecast](https://github.com/muammar/mkchromecast) (MIT), con un fix
per l'estrazione YouTube e un'interfaccia web locale.

## Requisiti

- macOS (testato su Apple Silicon)
- Homebrew + `ffmpeg`
- Python 3 con: `flask`, `pychromecast`, `requests`, `psutil`, `netifaces`, `yt-dlp`

## Installazione

```bash
brew install ffmpeg
pip3 install --user flask pychromecast requests psutil netifaces yt-dlp
```

## Uso rapido (CLI)

```bash
./maccast.sh ui                              # interfaccia web
./maccast.sh -d                              # elenca i dispositivi
./maccast.sh -y "https://youtu.be/XXX" --video   # YouTube
./maccast.sh --video --screencast            # schermo
./maccast.sh --video -i /percorso/video.mp4  # file locale
```

Opzioni utili: `--resolution 720p|1080p|1440p|uhd`, `-n "Nome dispositivo"`.

## Protocolli supportati

- **Google Cast (Chromecast)**: YouTube/video/file, screencast, storico.
- **DLNA (UPnP AVTransport)**: molte smart TV (es. Hisense VIDAA). Trasmette
  YouTube, link diretti e file locali; **non** fa mirroring dello schermo.
- **VIDAA / Hisense**: controllo della TV via MQTT-over-TLS (porta 36669):
  avvio app (YouTube, Netflix, RaiPlay…), telecomando (frecce/OK/Home/Back,
  play-pausa, volume, power), cambio sorgente. Richiede il **pairing con PIN**
  (libreria `vidaa-control`); la TV mostra un codice da confermare.
- **AirPlay**: se la TV lo supporta, si usa il mirroring nativo di macOS (non
  gestito da Maccast).

Nell'app scegli il tipo di destinazione (**Google Cast** / **DLNA**) nella card
"Dispositivo".

## App nativa macOS

Sul Desktop c'e' **`Maccast.app`**: una vera app SwiftUI (finestra nativa,
selettore file di sistema). Avvia da sola il backend Python e usa la sua API
locale su `127.0.0.1:8770`.

Ricompilarla (non serve Xcode, basta swiftc):

```bash
./macapp/build.sh            # produce ./Maccast.app
cp -R Maccast.app ~/Desktop/ # opzionale: copia sul Desktop
```

Al primo screencast concedi a **Maccast** il permesso *Registrazione schermo*
in *Impostazioni di Sistema > Privacy e Sicurezza*.

## Interfaccia web (alternativa)

```bash
./maccast.sh ui
```

Apre `http://127.0.0.1:8770/` con le stesse funzioni. Utile da browser o da
altre macchine della rete.


## Comando globale

Se hai creato il symlink:

```bash
maccast ui
maccast -y "https://youtu.be/XXX" --video
```

## Fix applicato (YouTube)

Il client web di default di yt-dlp fallisce su alcuni video con
`The page needs to be reloaded` (SABR/PO-token). In `mkchromecast/audio.py`
il comando YouTube ora usa:

- `--extractor-args "youtube:player_client=default,android"`
- `-f "best[ext=mp4]/best"` (stream combinato audio+video)
- `sys.executable -m yt_dlp` (nessun problema di PATH nel sottoprocesso)

## Permessi (macOS)

- **Registrazione schermo**: necessaria per lo screencast. Concedila in
  *Impostazioni di Sistema > Privacy e Sicurezza > Registrazione schermo* per
  l'app che avvia la trasmissione (Terminal o Maccast), poi riavvia quell'app.
  Se manca, ffmpeg cattura un video nero o si blocca.

## Problemi noti

- Lo screencast su macOS usa `avfoundation` (`Capture screen`); l'indice del
  dispositivo viene rilevato automaticamente. Override con la variabile
  `MKCHROMECAST_SCREEN_INDEX`.
- L'audio di sistema non e' catturato (servirebbe un loopback tipo BlackHole):
  lo screencast e' video-only.
- Porta di streaming: su macOS il default e' **5100** perche' AirPlay Receiver
  occupa la 5000. Si cambia con `-p <porta>`.
- Il backend `node` (audio di sistema) non e' installato: serve solo per il
  cast dell'audio, non per video/YouTube/screencast.
- `--control` richiede un terminale TTY.
- `bin/audiodevice` e' ricompilato per arm64. Per rigenerarlo:
  `./tools/audiodevice/build.sh` (sorgente incluso in `tools/audiodevice/`).

## Struttura

```
maccast/
├── maccast.sh        # launcher CLI/UI
├── webui.py          # interfaccia web (Flask)
├── templates/        # pagina web
├── bin/mkchromecast  # entry point
├── mkchromecast/     # pacchetto (con fix)
├── requirements.txt
└── tests/
```

## Licenza

Il codice di questo fork e' distribuito sotto licenza **MIT**: vedi
[`LICENSE`](LICENSE), che conserva il copyright originale di Muammar El Khatib
(2017) e aggiunge quello delle modifiche (2026 Gianluca Congiu). Il progetto
deriva da [mkchromecast](https://github.com/muammar/mkchromecast) (MIT);
l'elenco completo delle modifiche e' in [`UPSTREAM.md`](UPSTREAM.md).

Dipendenze e obblighi di terze parti: [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
Attenzione: **PyQt5** (GPL-3.0 o licenza commerciale) e **mutagen** (GPL-2.0+)
sono dipendenze runtime. Finche' distribuisci solo il sorgente e l'utente
installa le dipendenze, il repository resta MIT; un bundle che includa
PyQt5/mutagen (es. app PyInstaller) va invece distribuito secondo la GPL, con
il sorgente corrispondente.
