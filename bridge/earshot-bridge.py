#!/usr/bin/env python3
"""
Earshot Bridge - the local link between the browser extension and everything else.

The browser cannot write to your disk. It needs something local to talk to, and
there were two ways to arrange that:

  * a local HTTP server, which opens a port every other program on the machine
    can reach, needs its own authentication, and is one bad default away from
    being reachable from off the machine
  * native messaging, where the browser launches this program and talks to it
    over stdin and stdout

This is native messaging. There is no port, no listener, and nothing running
when the browser is closed. Only extension IDs allowlisted in the host manifest
can start it at all, which the browser enforces before this code runs.

What it accepts is deliberately tiny: an alert kind, and when it happened. It
never accepts a file path, a command, a URL, or any text to display. The worst a
compromised extension can do through this is play one of four sounds.

Protocol, as the browser defines it: a four byte little-endian length, then that
many bytes of JSON, on stdin. Replies go back the same way on stdout.
"""

import json
import os
import struct
import subprocess
import sys
import time

# The only kinds that may be requested. Anything else is dropped without
# comment: this is the allowlist that keeps the surface as small as it is.
ALLOWED = {'done', 'blocked', 'limit'}

# A rate limit of the mundane kind, so a misbehaving page cannot turn into a
# noise machine.
MIN_GAP_SECONDS = 3
_last_fired = [0.0]


def claude_dir():
    home = os.environ.get('HOME') or os.environ.get('USERPROFILE')
    return os.path.join(home, '.claude') if home else None


def read_message():
    """One message, or None at end of stream."""
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None
    length = struct.unpack('<I', header)[0]
    # A sane ceiling. Nothing legitimate sends anything close to this, and it
    # stops a malformed header asking for a gigabyte.
    if length > 64 * 1024:
        return None
    body = sys.stdin.buffer.read(length)
    if len(body) < length:
        return None
    try:
        return json.loads(body.decode('utf-8'))
    except Exception:
        return None


def write_message(obj):
    data = json.dumps(obj).encode('utf-8')
    sys.stdout.buffer.write(struct.pack('<I', len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def notify(kind):
    """Hand it to the notifier that is already installed.

    Reusing it rather than reimplementing playback means the browser and the
    terminal sound identical, obey the same mute, the same quiet hours and the
    same per-event volume, and land in the same log.
    """
    directory = claude_dir()
    if not directory:
        return 'no home directory'

    if os.name == 'nt':
        script = os.path.join(directory, 'claude-notify.ps1')
        if not os.path.exists(script):
            return 'notifier not installed'
        cmd = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', script, '-Kind', kind]
    else:
        script = os.path.join(directory, 'claude-notify.sh')
        if not os.path.exists(script):
            return 'notifier not installed'
        cmd = ['bash', script, kind]

    env = dict(os.environ)
    # Marks where it came from, so the log distinguishes a browser alert from a
    # terminal one.
    env['CLAUDE_NOTIFY_SOURCE'] = 'web'
    try:
        subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
    except Exception as exc:
        return 'could not run the notifier: %s' % exc
    return None


def handle(message):
    if not isinstance(message, dict):
        return {'ok': False, 'error': 'not an object'}

    kind = message.get('kind')
    if kind not in ALLOWED:
        return {'ok': False, 'error': 'unknown kind'}

    now = time.time()
    if now - _last_fired[0] < MIN_GAP_SECONDS:
        return {'ok': True, 'skipped': 'too soon'}
    _last_fired[0] = now

    error = notify(kind)
    if error:
        return {'ok': False, 'error': error}
    return {'ok': True}


def main():
    while True:
        message = read_message()
        if message is None:
            return 0
        try:
            reply = handle(message)
        except Exception:
            # Never die on one bad message: the browser would just relaunch it.
            reply = {'ok': False, 'error': 'internal'}
        try:
            write_message(reply)
        except Exception:
            return 0


if __name__ == '__main__':
    sys.exit(main())
