#!/usr/bin/env python3
"""
Generate the bundled alert sounds.

Sounds are synthesised rather than sourced, so they are reproducible from this
file, carry no licensing question, and stay small enough to embed in a
single-file installer. Run this only when changing the sound design:

    python build/make-sounds.py

Output goes to sounds/default/, which is committed. The installers embed every
pack under sounds/ as base64, so a machine with no system sound theme at all
still gets real audio instead of a terminal bell.

A pack is just a folder: add sounds/<name>/ with the same filenames and it is
installed alongside the default and selectable with SOUND_PACK.

Format is 16-bit mono PCM WAV at 11025 Hz, which every player in the fallback
chain handles, including aplay, which cannot decode .oga.

Size matters more than fidelity here, because these are embedded as base64 in
installers that people pipe from a URL. PCM tones are high entropy and gzip only
takes about 4% off, so the savings have to come from the rate and the length
rather than from compression. 11025 Hz puts Nyquist at 5512 Hz, so the pitch set
below is chosen to keep every harmonic underneath it: the highest chime is G6 at
1568 Hz, whose third harmonic lands at 4704 Hz.
"""

import io
import math
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'sounds', 'default')
RATE = 11025


def envelope(i, n, attack=0.01, release=0.35):
    """Attack-decay shape. Without this every tone clicks at both ends."""
    t = i / float(n)
    a = min(1.0, t / attack) if attack > 0 else 1.0
    r = 1.0 if t < (1.0 - release) else max(0.0, (1.0 - t) / release)
    return a * r


def tone(freq, ms, harmonics=(1.0, 0.35, 0.12), gain=0.55, decay=6.0):
    """A struck-bell-ish tone: a few harmonics under an exponential decay."""
    n = int(RATE * ms / 1000.0)
    out = []
    for i in range(n):
        t = i / float(RATE)
        v = 0.0
        for h, amp in enumerate(harmonics, start=1):
            v += amp * math.sin(2.0 * math.pi * freq * h * t)
        v *= math.exp(-decay * t) * envelope(i, n) * gain
        out.append(v)
    return out


def sweep(f0, f1, ms, gain=0.5, decay=4.0):
    """A tone gliding between two pitches. Reads as an alert rather than a chime."""
    n = int(RATE * ms / 1000.0)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / float(RATE)
        f = f0 + (f1 - f0) * (i / float(n))
        phase += 2.0 * math.pi * f / RATE
        v = (math.sin(phase) + 0.3 * math.sin(2 * phase))
        v *= math.exp(-decay * t) * envelope(i, n) * gain
        out.append(v)
    return out


def mix(*layers):
    n = max(len(x) for x in layers)
    out = [0.0] * n
    for layer in layers:
        for i, v in enumerate(layer):
            out[i] += v
    return out


def silence(ms):
    return [0.0] * int(RATE * ms / 1000.0)


def trim(samples, floor=0.02):
    """Drop the inaudible tail. These sounds decay exponentially, so most of
    their length is silence that would otherwise cost real bytes in the
    installers."""
    peak = max(0.0001, max(abs(v) for v in samples))
    cut = len(samples)
    while cut > 1 and abs(samples[cut - 1]) < peak * floor:
        cut -= 1
    # Fade the last few milliseconds so the truncation cannot click.
    out = samples[:cut]
    fade = min(len(out), int(RATE * 0.006))
    for i in range(fade):
        out[len(out) - fade + i] *= 1.0 - (i / float(fade))
    return out


def write_wav(path, samples):
    samples = trim(samples)
    # Normalise to just under full scale, so nothing clips and every sound sits
    # at a comparable loudness.
    peak = max(0.0001, max(abs(v) for v in samples))
    scale = 0.89 / peak
    frames = b''.join(
        struct.pack('<h', int(max(-32767, min(32767, v * scale * 32767))))
        for v in samples
    )
    with open(path, 'wb') as f:
        f.write(b'RIFF')
        f.write(struct.pack('<I', 36 + len(frames)))
        f.write(b'WAVEfmt ')
        f.write(struct.pack('<IHHIIHH', 16, 1, 1, RATE, RATE * 2, 2, 16))
        f.write(b'data')
        f.write(struct.pack('<I', len(frames)))
        f.write(frames)


# The set. Six finish chimes so PROJECT_PITCH has real range, and one distinct
# sound per alert kind. Names are what the config file refers to.
def build():
    s = {}

    # Finish chimes, ascending. Short and soft: these fire most often.
    for name, f in [
        ('chime-glass',  1318.51),   # E6
        ('chime-soft',   1046.50),   # C6
        ('chime-bright', 1567.98),   # G6
        ('chime-low',     783.99),   # G5
        ('chime-warm',    880.00),   # A5
        ('chime-mid',    1174.66),   # D6
    ]:
        s[name] = tone(f, 340, decay=9.0, gain=0.5)

    # Needs you: a rising two-note figure. Unfinished sounding, on purpose.
    s['alert-attention'] = mix(
        tone(659.25, 150, decay=11.0),
        silence(110) + tone(987.77, 260, decay=9.0),
    )

    # Rate limited: a falling minor third, which reads as "stopped".
    s['alert-limit'] = mix(
        tone(440.00, 180, decay=9.0, gain=0.6),
        silence(140) + tone(369.99, 340, decay=7.0, gain=0.6),
    )

    # Error: a short downward sweep with a rougher timbre.
    s['alert-error'] = mix(
        sweep(520, 240, 320, gain=0.6, decay=6.5),
        tone(220.00, 320, harmonics=(1.0, 0.5, 0.3), decay=7.5, gain=0.35),
    )

    return s


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)

    sounds = build()
    total = 0
    for name in sorted(sounds):
        path = os.path.join(OUT, name + '.wav')
        write_wav(path, sounds[name])
        size = os.path.getsize(path)
        total += size
        print('  %-18s %6d bytes' % (name + '.wav', size))
    print('  %-18s %6d bytes total, about %d KB as base64'
          % ('', total, total * 4 / 3 / 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main())
