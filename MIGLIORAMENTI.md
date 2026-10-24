# Miglioramenti possibili

Elenco delle direzioni di miglioramento per Maccast, ordinate per impatto.

## Performance

- **Server di streaming**: il relay usa il dev server Flask (werkzeug,
  single-thread). A bitrate molto alti può diventare un collo di bottiglia.
  Opzioni: `waitress`, un relay a socket nativo, `TCP_NODELAY`, chunk più
  grandi. A 1–10 Mbps non è un problema.
- **Encoder hardware**: usare `h264_videotoolbox` di default su macOS
  (meno CPU, meno calore), con fallback a `libx264`. Già supportato via
  `--vcodec`.
- **Latenza screencast**: frammenti MP4 corti (250 ms) e GOP 0.5 s sono già
  attivi; il limite residuo (~1–2 s) è il buffer del *Default Media Receiver*.
  Per scendere sotto serve un receiver personalizzato o WebRTC (fuori scope).
- **Bitrate adattivo**: abbassare risoluzione/fps automaticamente se l'encoder
  non tiene il realtime.

## Audio

- **Audio di sistema per lo screencast** via BlackHole (loopback):
  installazione (`brew install --cask blackhole-2ch`), routing e cattura
  `avfoundation`; richiede permessi e riavvio.
- **Multi-Output Device** per sentire l'audio in locale *e* trasmetterlo.

## Robustezza

- Cleanup automatico dei processi orfani già implementato (all'avvio, prima di
  ogni cast, allo stop). Estendere a `SIGINT`/`SIGTERM` con watchdog.
- **Permessi macOS**: rilevare lo stato di *Registrazione schermo* e mostrare
  un avviso chiaro nell'interfaccia invece di un video nero.
- **Porta di streaming configurabile** dalla UI (default 5100 per evitare il
  conflitto con AirPlay Receiver sulla 5000).

## Funzionalità

- **Coda/playlist**: trasmettere più contenuti di seguito.
- **Controlli dalla UI**: play/pausa e volume tramite il media controller Cast.
- **Sottotitoli** (già previsti da `--subtitles`).
- **Ricerche/cronologia**: filtri e cartelle recenti nel file picker.
- **HLS/DASH diretti** (`--source-url` con `.m3u8`/`.mpd`): verificare e
  documentare i codec supportati.

## Packaging e distribuzione

- **Impacchettare le dipendenze dentro l'app** (PyInstaller o Python embedded)
  così l'utente finale non deve installare nulla.
- **Firma e notarizzazione** dell'app per la distribuzione.
- **Homebrew tap/formula** per la versione patchata di mkchromecast.

## Qualità

- Test automatici unificati (in `tests/`) + CI (GitHub Actions).
- Lint/format automatico (`ruff`) e pre-commit.
- `CHANGELOG` e versionamento.

## Sicurezza

- Non salvare token/segreti nei file: usare variabili d'ambiente o il
  Portachiavi.
- Backend in ascolto solo su `127.0.0.1` (già così); valutare un token locale
  per l'API.
