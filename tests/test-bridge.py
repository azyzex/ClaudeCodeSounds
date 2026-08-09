#!/usr/bin/env python3
"""
Tests for Earshot Bridge.

The bridge is the one place where something outside this machine, a browser
extension, can ask for something to happen on it. Most of what follows is
therefore about what it refuses.
"""

import json
import os
import io
import shutil
import tempfile
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(os.path.dirname(HERE), 'bridge', 'earshot-bridge.py')

# Most tests drive the bridge as a real subprocess, which is how the browser
# uses it. The validation tests call handle() directly instead: they are about
# what it accepts rather than how it is spoken to, and going through the wire
# for each of forty inputs would only slow them down.
import importlib.util
_spec = importlib.util.spec_from_file_location('earshot_bridge', BRIDGE)
bridge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bridge)

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print('  ok    %s' % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print('  FAIL  %s' % msg)


def check(actual, expected, msg):
    if actual == expected:
        ok(msg)
    else:
        bad('%s (expected %r, got %r)' % (msg, expected, actual))


def frame(obj):
    body = json.dumps(obj).encode('utf-8')
    return struct.pack('<I', len(body)) + body


def run(messages, home='/nonexistent-earshot-test'):
    """Feed messages, return the replies."""
    payload = b''.join(frame(m) if not isinstance(m, bytes) else m for m in messages)
    env = dict(os.environ)
    env['HOME'] = home
    env['USERPROFILE'] = home
    proc = subprocess.run([sys.executable, BRIDGE], input=payload,
                          capture_output=True, env=env, timeout=30)
    out, replies, i = proc.stdout, [], 0
    while i + 4 <= len(out):
        n = struct.unpack('<I', out[i:i + 4])[0]
        i += 4
        replies.append(json.loads(out[i:i + n]))
        i += n
    return replies, proc


print('bridge: %s' % BRIDGE)
print('')

print('only the three alert kinds are accepted')
replies, proc = run([{'kind': 'done'}])
check(len(replies), 1, 'a valid kind gets a reply')
check(proc.returncode, 0, 'exits cleanly')

# Anything that is not one of the three is refused. These are the shapes an
# attacker would reach for if the field were ever passed to a shell or a path.
for hostile in ['rm -rf /', '../../etc/passwd', 'done; whoami', '', None, 42,
                {'nested': 'object'}, 'DONE', 'limit-reset']:
    replies, _ = run([{'kind': hostile}])
    if replies and replies[0].get('error') == 'unknown kind':
        ok('refused: %r' % (hostile,))
    else:
        bad('accepted %r -> %r' % (hostile, replies))

print('')
print('malformed input is survived, not crashed on')
for label, payload in [
    ('not an object', [b'\x0e\x00\x00\x00"just a string"']),
    ('not json', [b'\x04\x00\x00\x00abcd']),
    ('truncated body', [b'\xff\x00\x00\x00short']),
    ('absurd length', [struct.pack('<I', 200 * 1024) + b'x']),
    ('empty stream', []),
]:
    _, proc = run(payload)
    if proc.returncode == 0 and not proc.stderr:
        ok('%s: exits cleanly and says nothing on stderr' % label)
    else:
        bad('%s: rc=%s stderr=%r' % (label, proc.returncode, proc.stderr[:120]))

print('')
print('it does not run anything when the notifier is absent')
replies, _ = run([{'kind': 'done'}])
check(replies[0].get('ok'), False, 'reports that it could not act')
check(replies[0].get('error'), 'notifier not installed', 'and says why')

print('')
print('repeats are rate limited')
replies, _ = run([{'kind': 'done'}, {'kind': 'done'}, {'kind': 'done'}])
skipped = sum(1 for r in replies if r.get('skipped'))
check(skipped, 2, 'only the first of three is acted on')


# --- the limits kind ---------------------------------------------------------
# Added once the usage endpoint was proven to carry resets_at. These matter more
# than the sound kinds: this one writes to disk and sets a clock.

print('')
print('limits are validated before anything is written')

# Computed rather than written down. The bridge sanity checks that a reset is
# actually near, so a fixed date here would pass today and fail the build
# tomorrow.
import datetime as _dt
GOOD_AT = (_dt.datetime.now(_dt.timezone.utc)
           + _dt.timedelta(hours=2)).isoformat()


def limits(**over):
    msg = {'kind': 'limits', 'account': 'a1b2c3d4e5f6',
           'five_hour': {'utilization': 93, 'resets_at': GOOD_AT}}
    msg.update(over)
    return msg


# The account is the whole reason two signed-in accounts cannot contaminate
# each other, so anything that is not a plain hash is refused.
for junk in ('', 'NOTAHASH', '../../etc/passwd', 'a1b2c3d4e5f6; rm -rf /',
            None, 42, {'a': 1}, 'g' * 12, 'abc'):
    check(bridge.handle(limits(account=junk)).get('error'), 'bad account',
          'account %r refused' % (junk,))

# A reset time is a timestamp or it is nothing. A bad one would schedule the
# alert for the wrong moment, which is worse than no alert at all.
for junk in ('tomorrow', '', '2026-13-45T99:99:99', 'now()', None, 0,
            {'nested': 1}, '2026-08-09',
            '2026-13-45T99:99:99',           # shape-valid, not a date
            '2099-01-01T00:00:00+00:00'):    # real, but no window is that long
    check(bridge.handle(limits(five_hour={'utilization': 50,
                                          'resets_at': junk})).get('error'),
          'no usable window', 'resets_at %r refused' % (junk,))

for junk in (-1, 101, 'lots', None, [50]):
    check(bridge.handle(limits(five_hour={'utilization': junk,
                                          'resets_at': GOOD_AT})).get('error'),
          'no usable window', 'utilization %r refused' % (junk,))

check(bridge.handle(limits(five_hour=None)).get('error'), 'no usable window',
      'a message with no usable window is refused')

print('')
print('a good message is stored, and only the two fields survive')

_home = tempfile.mkdtemp()
_old = dict(os.environ)
os.environ['HOME'] = _home
os.environ['USERPROFILE'] = _home
os.makedirs(os.path.join(_home, '.claude'), exist_ok=True)
try:
    _reply = bridge.handle(limits(seven_day={'utilization': 35,
                                             'resets_at': GOOD_AT,
                                             'limit_dollars': 20,
                                             'used_dollars': 12.5}))
    check(_reply.get('ok'), True, 'accepted')
    _f = os.path.join(_home, '.claude', 'claude-limits.d', 'web.conf')
    check(os.path.exists(_f), True, 'written to its own file, not the shared one')
    _body = io.open(_f, encoding='utf-8').read()
    check('account=a1b2c3d4e5f6' in _body, True, 'records which account it saw')
    check('source=web' in _body, True, 'records which surface saw it')
    # Stored as an epoch: the watcher skips anything that is not all digits, so
    # an ISO string would be written and then silently never fire.
    _epoch = int((_dt.datetime.now(_dt.timezone.utc)
                  + _dt.timedelta(hours=2)).timestamp())
    _line = [l for l in _body.splitlines() if l.startswith('five_hour_resets_at=')]
    check(len(_line), 1, 'keeps the reset time')
    _got = _line[0].split('=', 1)[1]
    check(_got.isdigit(), True, 'stores the reset time as an epoch, not ISO')
    check(abs(int(_got) - _epoch) < 5, True, 'and it is the right moment')
    check('five_hour_used=93' in _body, True, 'keeps the percentage')
    check('seven_day_used=35' in _body, True, 'keeps the weekly window too')
    # Money is in the response and has no business being on disk.
    check('dollar' in _body or '12.5' in _body, False,
          'drops everything about money')
finally:
    os.environ.clear()
    os.environ.update(_old)
    shutil.rmtree(_home, ignore_errors=True)

print('')
print('passed %d, failed %d' % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
