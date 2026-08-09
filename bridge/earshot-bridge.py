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
compromised extension can do through this is play one of four sounds, or set a
countdown to a time it claims your usage window resets.

Protocol, as the browser defines it: a four byte little-endian length, then that
many bytes of JSON, on stdin. Replies go back the same way on stdout.
"""

import datetime
import json
import os
import re
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


ISO = re.compile(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?'
                 r'(Z|[+-]\d{2}:?\d{2})?$')
ACCOUNT = re.compile(r'^[0-9a-f]{6,32}$')


def window_or_none(value):
    """Validate one usage window, or reject it.

    Only two fields survive: a percentage and a reset time. Everything else the
    endpoint returns, including anything to do with money, is dropped here
    rather than being carried around and then ignored.
    """
    if not isinstance(value, dict):
        return None
    pct = value.get('utilization')
    at = value.get('resets_at')
    if not isinstance(pct, (int, float)) or not 0 <= pct <= 100:
        return None
    if not isinstance(at, str) or not ISO.match(at):
        return None
    # The pattern only proves the shape. "2026-13-45T99:99:99" passes it and is
    # not a date, so it gets parsed for real, and then sanity checked: a reset
    # is soon, and a bogus far-future time would silently mean no alert ever.
    try:
        when = datetime.datetime.fromisoformat(at.replace('Z', '+00:00'))
        if when.tzinfo is None:
            when = when.replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    ahead = (when - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
    if ahead < -3600 or ahead > 8 * 24 * 3600:
        return None
    return {'used': int(pct), 'resets_at': at}


def store_limits(message):
    """Record limits the browser observed, kept apart by account.

    Claude Code and the browser may be signed into different accounts, and the
    window is per account, so a reset time learned in one place is simply wrong
    for the other. Each source writes its own file, tagged with the account it
    saw, and nothing merges them. Two honest countdowns beat one confident
    wrong one.

    The account is a hash the extension computed, never the organisation id
    itself: enough to tell two accounts apart, not an identifier sitting in a
    file.
    """
    account = message.get('account')
    if not isinstance(account, str) or not ACCOUNT.match(account):
        return {'ok': False, 'error': 'bad account'}

    five = window_or_none(message.get('five_hour'))
    week = window_or_none(message.get('seven_day'))
    if not five and not week:
        return {'ok': False, 'error': 'no usable window'}

    directory = claude_dir()
    if not directory:
        return {'ok': False, 'error': 'no home directory'}
    target = os.path.join(directory, 'claude-limits.d')
    try:
        os.makedirs(target, exist_ok=True)
        path = os.path.join(target, 'web.conf')
        lines = ['updated=%d' % int(time.time()), 'source=web',
                 'account=%s' % account]
        if five:
            lines.append('five_hour_resets_at=%s' % five['resets_at'])
            lines.append('five_hour_used=%d' % five['used'])
        if week:
            lines.append('seven_day_resets_at=%s' % week['resets_at'])
            lines.append('seven_day_used=%d' % week['used'])
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
        os.replace(tmp, path)
    except Exception as exc:
        return {'ok': False, 'error': 'could not save: %s' % exc}

    # Nothing is played here. This is a clock being set, not an event, and the
    # watcher is what eventually speaks.
    start_watcher()
    return {'ok': True, 'stored': True}


def start_watcher():
    """Make sure something is counting down. Harmless if one already is."""
    directory = claude_dir()
    if not directory:
        return
    if os.name == 'nt':
        script = os.path.join(directory, 'claude-notify.ps1')
        cmd = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', script, '-Kind', 'watch']
    else:
        script = os.path.join(directory, 'claude-notify.sh')
        cmd = ['bash', script, 'watch']
    if not os.path.exists(script):
        return
    try:
        subprocess.Popen(cmd, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def handle(message):
    if not isinstance(message, dict):
        return {'ok': False, 'error': 'not an object'}

    if message.get('kind') == 'limits':
        return store_limits(message)

    kind = message.get('kind')
    # The type check is not redundant: `x in set` raises on an unhashable value,
    # so a dict here would land in the caller's generic handler. Refused either
    # way, but it should be refused on purpose rather than by exception.
    if not isinstance(kind, str) or kind not in ALLOWED:
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
