# This file is part of mkchromecast.

"""Minimal DLNA / UPnP AVTransport support.

Allows pushing a media URL to a DLNA MediaRenderer (e.g. many smart TVs).
Includes a small HTTP server that serves local files (with Range support, for
seeking) and can proxy a yt-dlp stream on the fly.
"""

import http.server
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import xml.sax.saxutils as sx
from functools import partial

SSDP_ADDR = ("239.255.255.250", 1900)
MEDIA_RENDERER = "urn:schemas-upnp-org:device:MediaRenderer:1"
AVT = "urn:schemas-upnp-org:service:AVTransport:1"
RCS = "urn:schemas-upnp-org:service:RenderingControl:1"


# MARK: - Scoperta SSDP

def _msearch(st, timeout=4):
    msg = ("M-SEARCH * HTTP/1.1\r\n"
           "HOST: 239.255.255.250:1900\r\n"
           'MAN: "ssdp:discover"\r\n'
           f"MX: {timeout}\r\n"
           f"ST: {st}\r\n\r\n").encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(timeout)
    try:
        s.sendto(msg, SSDP_ADDR)
    except OSError:
        return []
    seen = {}
    t = time.time()
    while time.time() - t < timeout:
        try:
            data, addr = s.recvfrom(65507)
        except socket.timeout:
            break
        except OSError:
            break
        headers = {}
        for line in data.decode("utf-8", "replace").split("\r\n"):
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        loc = headers.get("location")
        usn = headers.get("usn") or loc or addr[0]
        if loc and usn not in seen:
            seen[usn] = loc
    s.close()
    return list(seen.values())


def _tag(xml, tag):
    m = re.search(rf"<{tag}[^>]*>(.*?)</{tag}>", xml, re.S)
    return m.group(1).strip() if m else None


def _control_url(location, xml, service):
    for block in re.findall(r"<service>(.*?)</service>", xml, re.S):
        if f":service:{service}:" in block:
            ctrl = _tag(block, "controlURL")
            if ctrl:
                return urllib.parse.urljoin(location, ctrl)
    return None


def discover(timeout=4):
    """Ritorna la lista dei MediaRenderer DLNA trovati."""
    renderers = []
    seen_ips = set()
    for loc in _msearch(MEDIA_RENDERER, timeout):
        host = urllib.parse.urlparse(loc).hostname
        if host in seen_ips:
            continue
        try:
            with urllib.request.urlopen(loc, timeout=4) as r:
                xml = r.read().decode("utf-8", "replace")
        except Exception:
            continue
        seen_ips.add(host)
        renderers.append({
            "name": _tag(xml, "friendlyName") or host,
            "location": loc,
            "av_control": _control_url(loc, xml, "AVTransport"),
            "rc_control": _control_url(loc, xml, "RenderingControl"),
            "ip": host,
        })
    return renderers


# MARK: - Controllo AVTransport

def soap(control_url, service, action, inner):
    if not control_url:
        raise ValueError("control URL mancante")
    env = (
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        f'<s:Body><u:{action} xmlns:u="{service}">{inner}</u:{action}>'
        '</s:Body></s:Envelope>')
    req = urllib.request.Request(
        control_url, data=env.encode(), method="POST",
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPAction": f'"{service}#{action}"',
        })
    with urllib.request.urlopen(req, timeout=8) as r:
        return r.read().decode("utf-8", "replace")


def didl(uri, title, mime="video/mp4"):
    return (
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        f'<dc:title>{sx.escape(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        f'<res protocolInfo="http-get:*:{mime}:*">{sx.escape(uri)}</res>'
        '</item></DIDL-Lite>')


def set_uri(av_control, uri, title="Maccast", mime="video/mp4"):
    inner = (
        '<InstanceID>0</InstanceID>'
        f'<CurrentURI>{sx.escape(uri)}</CurrentURI>'
        f'<CurrentURIMetaData>{sx.escape(didl(uri, title, mime))}'
        '</CurrentURIMetaData>')
    return soap(av_control, AVT, "SetAVTransportURI", inner)


def play(av_control, speed="1"):
    return soap(av_control, AVT, "Play",
                f'<InstanceID>0</InstanceID><Speed>{speed}</Speed>')


def pause(av_control):
    return soap(av_control, AVT, "Pause", '<InstanceID>0</InstanceID>')


def stop(av_control):
    return soap(av_control, AVT, "Stop", '<InstanceID>0</InstanceID>')


def transport_state(av_control):
    try:
        body = soap(av_control, AVT, "GetTransportInfo",
                    '<InstanceID>0</InstanceID>')
        return _tag(body, "CurrentTransportState")
    except Exception:
        return None


def set_volume(rc_control, volume):
    if not rc_control:
        return None
    return soap(rc_control, RCS, "SetVolume",
                '<InstanceID>0</InstanceID><Channel>Master</Channel>'
                f'<DesiredVolume>{int(volume)}</DesiredVolume>')


# MARK: - Server media locale (Range + proxy yt-dlp)

_YT_URL_RE = re.compile(r"^/yt\?url=(.+)$")


class _Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        m = _YT_URL_RE.match(self.path)
        if m:
            return self._proxy_yt(urllib.parse.unquote(m.group(1)))
        return self._serve_file()

    def do_HEAD(self):
        return self._serve_file(head=True)

    def _proxy_yt(self, url):
        try:
            import mkchromecast
            py = sys.executable
        except Exception:
            py = sys.executable
        cmd = [py, "-m", "yt_dlp", "-o", "-", "-f", "best[ext=mp4]/best",
               "--extractor-args", "youtube:player_client=default,android",
               url]
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "none")
        self.end_headers()
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        try:
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            proc.kill()

    def _serve_file(self, head=False):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().do_GET()
        try:
            fh = open(path, "rb")
        except OSError:
            self.send_error(404)
            return
        try:
            size = os.fstat(fh.fileno()).st_size
        except OSError:
            fh.close()
            self.send_error(404)
            return
        start, end = 0, size - 1
        range_header = self.headers.get("Range")
        m = re.match(r"bytes=(\d*)-(\d*)", range_header) if range_header else None
        if m:
            if m.group(1):
                start = int(m.group(1))
            if m.group(2):
                end = int(m.group(2))
            if start > end or start >= size:
                fh.close()
                self.send_error(416)
                return
        length = end - start + 1
        self.send_response(206 if m else 200)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if m:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head:
            fh.close()
            return
        fh.seek(start)
        remaining = length
        try:
            while remaining > 0:
                chunk = fh.read(min(65536, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            fh.close()


class MediaServer:
    """Server HTTP locale per servire file (seek) e stream yt-dlp."""

    def __init__(self, directory, port=0):
        handler = partial(_Handler, directory=directory)
        self._httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever,
                                        daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        try:
            self._httpd.shutdown()
            self._httpd.server_close()
        except Exception:
            pass
