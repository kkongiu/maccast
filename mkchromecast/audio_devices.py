# This file is part of mkchromecast.

import os
import subprocess

"""
These functions are used to switch input/out to BlackHole back and forth.

To call them:
    from mkchromecast.audio_devices import *
    name()
"""


def _audiodevice_path() -> str:
    """Percorso del binario `audiodevice` incluso nel pacchetto.

    Cerca prima accanto al pacchetto (indipendente dalla cwd), poi nella cwd.
    """
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for candidate in (
        os.path.join(root, "bin", "audiodevice"),
        os.path.join(os.getcwd(), "bin", "audiodevice"),
        os.path.join(os.getcwd(), "audiodevice"),
    ):
        if os.path.exists(candidate):
            return candidate
    return "audiodevice"


def _switch(port: str, device: str, blocking: bool) -> None:
    cmd = [f'{_audiodevice_path()} {port} "{device}"']
    if blocking:
        subprocess.call(cmd, shell=True)
    else:
        subprocess.Popen(cmd, shell=True)


def inputdev():
    _switch("input", "BlackHole 16ch", blocking=False)


def outputdev():
    _switch("output", "BlackHole 16ch", blocking=False)


def inputint():
    # "internal" e' un alias riconosciuto dal binario e valido in ogni lingua,
    # a differenza dei nomi localizzati dei dispositivi.
    _switch("input", "internal", blocking=True)


def outputint():
    _switch("output", "internal", blocking=True)
