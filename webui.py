#!/usr/bin/env python3
"""Maccast Web UI.

Semplice interfaccia web locale per pilotare mkchromecast:
  - scoperta dispositivi Google Cast
  - trasmissione YouTube / schermo / file locale
  - stop e log in tempo reale

Avvio:
    python3 webui.py
oppure:
    ./maccast.sh ui
"""

import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
import json
import urllib.parse

from mkchromecast import dlna

from flask import Flask, jsonify, render_template, request

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ENTRY = os.path.join(BASE_DIR, "bin", "mkchromecast")
HOST = "127.0.0.1"
PORT = 8770
# Porta usata da mkchromecast per lo streaming (default su macOS).
STREAM_PORT = 5100

# Storico degli ultimi contenuti trasmessi (YouTube/file).
HISTORY_PATH = os.path.join(os.path.expanduser("~"), ".maccast", "history.json")
HISTORY_MAX = 3

# Cartelle esplorabili dal file picker (limita l'accesso a home, volumi, tmp).
ALLOWED_ROOTS = [
    os.path.realpath(os.path.expanduser("~")),
    "/Users",
    "/Volumes",
    "/tmp",
    "/private/tmp",
]

VIDEO_EXTS = {
    ".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v",
    ".mpg", ".mpeg", ".ts", ".flv", ".wmv", ".ogv",
}

# MIME per gli URL media diretti (--source-url).
MIME_BY_EXT = {
    ".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime",
    ".webm": "video/webm", ".mkv": "video/x-matroska", ".ts": "video/mp2t",
    ".m3u8": "application/x-mpegURL", ".mpd": "application/dash+xml",
    ".mp3": "audio/mpeg", ".aac": "audio/aac", ".ogg": "audio/ogg",
    ".oga": "audio/ogg", ".flac": "audio/flac", ".wav": "audio/wav",
    ".m4a": "audio/mp4",
}


def _guess_mime(url: str) -> str:
    path = urllib.parse.urlparse(url).path
    ext = os.path.splitext(path)[1].lower()
    return MIME_BY_EXT.get(ext, "video/mp4")


def _is_allowed(path: str) -> bool:
    real = os.path.realpath(path)
    return any(real == root or real.startswith(root + os.sep)
               for root in ALLOWED_ROOTS)

DEVICE_RE = re.compile(r"^\s*(\d+)\s*\t\s*(\S+)\s*\t\s*(.+?)\s*$")


def _build_env():
    env = dict(os.environ)
    extra = os.path.expanduser("~/Library/Python/3.9/bin") + ":/opt/homebrew/bin"
    env["PATH"] = extra + ":" + env.get("PATH", "")
    return env


def _pids_from(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
    except Exception:
        return []
    return [int(p) for p in out.split() if p.strip().isdigit()]


def _kill_pids(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    if pids:
        time.sleep(0.4)
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass


def _cleanup_leftovers():
    """Termina cast/server rimasti da esecuzioni precedenti.

    Evita il conflitto sulla porta di streaming quando l'interfaccia viene
    riavviata mentre un cast e' ancora attivo.
    """
    pids = set(_pids_from(["lsof", "-tnP", f"-iTCP:{STREAM_PORT}",
                           "-sTCP:LISTEN"]))
    pids.update(_pids_from(["pgrep", "-f", "bin/mkchromecast"]))
    pids.discard(os.getpid())
    _kill_pids(sorted(pids))


def _load_history():
    try:
        with open(HISTORY_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, list):
            return data
    except (OSError, ValueError):
        pass
    return []


def _save_history(items):
    try:
        os.makedirs(os.path.dirname(HISTORY_PATH), exist_ok=True)
        with open(HISTORY_PATH, "w", encoding="utf-8") as fh:
            json.dump(items, fh, indent=2)
    except OSError:
        pass


def _add_history(kind, value, label=None):
    value = (value or "").strip()
    if not value:
        return
    items = [it for it in _load_history()
             if not (it.get("kind") == kind and it.get("value") == value)]
    items.insert(0, {
        "kind": kind,
        "value": value,
        "label": label or value,
        "ts": time.time(),
    })
    _save_history(items[:HISTORY_MAX])


app = Flask(__name__, template_folder=os.path.join(BASE_DIR, "templates"))


class Caster:
    """Gestisce il processo mkchromecast in background."""

    def __init__(self):
        self._proc = None
        self._log = []
        self._kind = None
        self._lock = threading.Lock()

    def running(self):
        return self._proc is not None and self._proc.poll() is None

    def _reader(self, proc):
        for line in iter(proc.stdout.readline, ""):
            with self._lock:
                self._log.append(line.rstrip("\n"))
                if len(self._log) > 800:
                    del self._log[: len(self._log) - 800]
        proc.stdout.close()

    def start(self, args, kind):
        if self.running():
            raise RuntimeError("Una trasmissione e' gia' in corso")
        # Libera eventuali server rimasti da esecuzioni precedenti.
        _cleanup_leftovers()
        with self._lock:
            self._log = []
        cmd = [sys.executable, "-u", ENTRY] + args
        proc = subprocess.Popen(
            cmd,
            cwd=BASE_DIR,
            env=_build_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        self._proc = proc
        self._kind = kind
        threading.Thread(target=self._reader, args=(proc,), daemon=True).start()

    def stop(self):
        proc = self._proc
        was_running = proc is not None and proc.poll() is None
        if proc is not None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        self._proc = None
        # Rimuove anche eventuali processi di streaming rimasti orfani.
        _cleanup_leftovers()
        return was_running

    def state(self):
        return {
            "running": self.running(),
            "kind": self._kind if self.running() else None,
            "log": list(self._log),
        }


caster = Caster()


# MARK: - DLNA

_dlna = {"renderers": [], "active": None, "server": None, "dir": None}


def _local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def _dlna_server():
    if _dlna["server"] is None:
        directory = tempfile.mkdtemp(prefix="maccast-dlna-")
        server = dlna.MediaServer(directory)
        server.start()
        _dlna["server"] = server
        _dlna["dir"] = directory
    return _dlna["server"], _dlna["dir"]


def discover_devices(timeout=20):
    proc = subprocess.Popen(
        [sys.executable, "-u", ENTRY, "-d"],
        cwd=BASE_DIR,
        env=_build_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
    devices = []
    for line in out.splitlines():
        m = DEVICE_RE.match(line)
        if not m:
            continue
        idx, typ, name = m.groups()
        if name.strip().lower() in {"friendly name", "============="}:
            continue
        devices.append({"index": int(idx), "type": typ, "name": name.strip()})
    return devices


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/devices")
def api_devices():
    try:
        return jsonify({"ok": True, "devices": discover_devices()})
    except Exception as exc:  # noqa: BLE001
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/status")
def api_status():
    return jsonify({"ok": True, **caster.state()})


@app.route("/api/history")
def api_history():
    return jsonify({"ok": True, "items": _load_history()})


@app.route("/api/history/clear", methods=["POST"])
def api_history_clear():
    _save_history([])
    return jsonify({"ok": True})


@app.route("/api/dlna/devices")
def api_dlna_devices():
    try:
        _dlna["renderers"] = dlna.discover(timeout=4)
        return jsonify({"ok": True, "devices": _dlna["renderers"]})
    except Exception as exc:  # noqa: BLE001
        return jsonify({"ok": False, "error": str(exc)}), 500


def _dlna_pick_renderer(data):
    av = (data.get("av_control") or "").strip()
    if av:
        return av
    renderers = _dlna["renderers"] or dlna.discover(timeout=4)
    _dlna["renderers"] = renderers
    if not renderers:
        return None
    idx = int(data.get("index") or 0)
    if idx < 0 or idx >= len(renderers):
        idx = 0
    return renderers[idx]["av_control"]


@app.route("/api/dlna/cast", methods=["POST"])
def api_dlna_cast():
    data = request.get_json(force=True, silent=True) or {}
    kind = data.get("kind")
    title = (data.get("title") or "Maccast").strip()
    av = _dlna_pick_renderer(data)
    if not av:
        return jsonify({"ok": False, "error": "Nessun renderer DLNA"}), 400

    if kind == "url":
        uri = (data.get("url") or "").strip()
        if not uri:
            return jsonify({"ok": False, "error": "URL mancante"}), 400
        dlna.set_uri(av, uri, title, _guess_mime(uri))
        dlna.play(av)
    elif kind == "file":
        path = (data.get("path") or "").strip()
        if not path or not os.path.exists(path):
            return jsonify({"ok": False, "error": "File non trovato"}), 400
        server, directory = _dlna_server()
        name = os.path.basename(path)
        link = os.path.join(directory, name)
        try:
            if os.path.lexists(link):
                os.remove(link)
            os.symlink(os.path.abspath(path), link)
        except OSError as exc:
            return jsonify({"ok": False, "error": f"Errore: {exc}"}), 500
        uri = (f"http://{_local_ip()}:{server.port}/"
               + urllib.parse.quote(name))
        dlna.set_uri(av, uri, title or name)
        dlna.play(av)
    elif kind == "youtube":
        url = (data.get("url") or "").strip()
        if not url:
            return jsonify({"ok": False, "error": "URL mancante"}), 400
        server, _ = _dlna_server()
        uri = (f"http://{_local_ip()}:{server.port}/yt?url="
               + urllib.parse.quote(url, safe=""))
        dlna.set_uri(av, uri, title or "YouTube")
        dlna.play(av)
    else:
        return jsonify({"ok": False, "error": "Tipo non valido"}), 400

    _dlna["active"] = av
    return jsonify({"ok": True})


@app.route("/api/dlna/stop", methods=["POST"])
def api_dlna_stop():
    av = _dlna.get("active")
    if av:
        try:
            dlna.stop(av)
        except Exception:  # noqa: BLE001
            pass
    return jsonify({"ok": True})


@app.route("/api/dlna/pause", methods=["POST"])
def api_dlna_pause():
    av = _dlna.get("active")
    if av:
        try:
            dlna.pause(av)
        except Exception:  # noqa: BLE001
            pass
    return jsonify({"ok": True})


# MARK: - VIDAA (Hisense)

VIDAA_FILE = os.path.join(os.path.expanduser("~"), ".maccast", "vidaa.json")
_vidaa = {"host": None, "tv": None, "lock": threading.Lock()}


def _vidaa_host():
    if _vidaa["host"] is None:
        try:
            with open(VIDAA_FILE, encoding="utf-8") as fh:
                _vidaa["host"] = json.load(fh).get("host")
        except (OSError, ValueError):
            _vidaa["host"] = None
    return _vidaa["host"]


def _vidaa_save(host):
    try:
        os.makedirs(os.path.dirname(VIDAA_FILE), exist_ok=True)
        with open(VIDAA_FILE, "w", encoding="utf-8") as fh:
            json.dump({"host": host}, fh)
    except OSError:
        pass
    _vidaa["host"] = host


def _vidaa_tv():
    """Ritorna (riconnettendo se serve) il client VIDAA, o None."""
    host = _vidaa_host()
    if not host:
        return None
    tv = _vidaa["tv"]
    if tv is not None and tv.is_connected:
        return tv
    try:
        from vidaa.cli import create_tv_client
    except ImportError:
        return None
    tv = create_tv_client(None, host)
    if tv.connect(timeout=10):
        _vidaa["tv"] = tv
        return tv
    return None


def _vidaa_run(fn):
    with _vidaa["lock"]:
        tv = _vidaa_tv()
        if tv is None:
            return {"ok": False,
                    "error": "TV VIDAA non configurata o non raggiungibile"}
        try:
            return {"ok": True, "result": fn(tv)}
        except Exception as exc:  # noqa: BLE001
            _vidaa["tv"] = None
            return {"ok": False, "error": str(exc)}


@app.route("/api/vidaa/devices")
def api_vidaa_devices():
    try:
        from vidaa import discovery
        found = discovery.discover_all(timeout=5)
        return jsonify({"ok": True, "devices": sorted(found.keys()),
                        "host": _vidaa_host()})
    except Exception as exc:  # noqa: BLE001
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/vidaa/set", methods=["POST"])
def api_vidaa_set():
    data = request.get_json(force=True, silent=True) or {}
    host = (data.get("host") or "").strip()
    if not host:
        return jsonify({"ok": False, "error": "host mancante"}), 400
    with _vidaa["lock"]:
        if _vidaa["tv"] is not None:
            try:
                _vidaa["tv"].disconnect()
            except Exception:  # noqa: BLE001
                pass
        _vidaa["tv"] = None
        _vidaa_save(host)
        ok = _vidaa_tv() is not None
    return jsonify({"ok": ok, "host": host,
                    "error": None if ok else "Connessione fallita"})


@app.route("/api/vidaa/apps")
def api_vidaa_apps():
    def fn(tv):
        apps = tv.get_apps() or []
        return [a.get("name") for a in apps if a.get("name")]
    return jsonify(_vidaa_run(fn))


@app.route("/api/vidaa/launch", methods=["POST"])
def api_vidaa_launch():
    data = request.get_json(force=True, silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"ok": False, "error": "app mancante"}), 400
    return jsonify(_vidaa_run(lambda tv: tv.launch_app(name)))


@app.route("/api/vidaa/key", methods=["POST"])
def api_vidaa_key():
    data = request.get_json(force=True, silent=True) or {}
    key = (data.get("key") or "").strip()
    if not key:
        return jsonify({"ok": False, "error": "tasto mancante"}), 400
    return jsonify(_vidaa_run(lambda tv: tv.send_key(key)))


@app.route("/api/vidaa/volume", methods=["POST"])
def api_vidaa_volume():
    data = request.get_json(force=True, silent=True) or {}
    action = (data.get("action") or "").strip()

    def fn(tv):
        if action == "up":
            return tv.volume_up()
        if action == "down":
            return tv.volume_down()
        if action == "mute":
            return tv.mute()
        if action == "set":
            return tv.set_volume(int(data.get("value") or 20))
        return tv.get_volume()

    return jsonify(_vidaa_run(fn))


@app.route("/api/vidaa/source", methods=["POST"])
def api_vidaa_source():
    data = request.get_json(force=True, silent=True) or {}
    source = (data.get("source") or "").strip()
    if not source:
        return jsonify({"ok": False, "error": "sorgente mancante"}), 400
    return jsonify(_vidaa_run(lambda tv: tv.set_source(source)))


@app.route("/api/stop", methods=["POST"])
def api_stop():
    return jsonify({"ok": True, "stopped": caster.stop()})


@app.route("/api/browse")
def api_browse():
    raw = request.args.get("path") or os.path.expanduser("~")
    path = os.path.realpath(raw)
    if not _is_allowed(path):
        return jsonify({"ok": False, "error": "Percorso non consentito"}), 403
    if not os.path.isdir(path):
        path = os.path.dirname(path)

    try:
        names = sorted(os.listdir(path), key=str.lower)
    except (PermissionError, FileNotFoundError):
        return jsonify({"ok": False, "error": "Cartella non accessibile"}), 403

    entries = []
    for name in names:
        if name.startswith("."):
            continue
        full = os.path.join(path, name)
        try:
            is_dir = os.path.isdir(full)
            size = 0 if is_dir else os.path.getsize(full)
        except OSError:
            continue
        ext = os.path.splitext(name)[1].lower()
        entries.append({
            "name": name,
            "path": full,
            "is_dir": is_dir,
            "is_video": (not is_dir and ext in VIDEO_EXTS),
            "size": size,
        })
    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))

    parent = os.path.dirname(path)
    if parent == path or not _is_allowed(parent):
        parent = None

    return jsonify({"ok": True, "path": path, "parent": parent,
                    "entries": entries})


@app.route("/api/cast", methods=["POST"])
def api_cast():
    data = request.get_json(force=True, silent=True) or {}
    kind = data.get("kind")
    device = (data.get("device") or "").strip()
    resolution = (data.get("resolution") or "1080p").strip()

    if kind == "youtube":
        url = (data.get("url") or "").strip()
        if not url:
            return jsonify({"ok": False, "error": "URL YouTube mancante"}), 400
        args = ["-y", url, "--video", "--resolution", resolution]
    elif kind == "screencast":
        args = ["--video", "--screencast", "--resolution", resolution]
    elif kind == "file":
        path = (data.get("path") or "").strip()
        if not path or not os.path.exists(path):
            return jsonify({"ok": False, "error": "File non trovato"}), 400
        args = ["--video", "-i", path, "--resolution", resolution]
    elif kind == "sourceurl":
        url = (data.get("url") or "").strip()
        if not url:
            return jsonify({"ok": False, "error": "URL mancante"}), 400
        args = ["--source-url", url, "--video", "--mtype", _guess_mime(url)]
    else:
        return jsonify({"ok": False, "error": "Tipo non valido"}), 400

    if device:
        args += ["-n", device]

    try:
        caster.start(args, kind)
    except RuntimeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 409

    if kind == "youtube":
        _add_history("youtube", url)
    elif kind == "file":
        _add_history("file", path)
    elif kind == "sourceurl":
        _add_history("sourceurl", url)

    return jsonify({"ok": True})


def main():
    # Libera l'eventuale cast/servers rimasti da un'esecuzione precedente.
    _cleanup_leftovers()
    url = f"http://{HOST}:{PORT}/"
    if os.environ.get("MACCast_NO_BROWSER") != "1":
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    print(f"Maccast UI in ascolto su {url}")
    print("Premi Ctrl-C per chiudere.")
    app.run(host=HOST, port=PORT, debug=False, threaded=True)


if __name__ == "__main__":
    main()
