#!/usr/bin/env python3
"""
Tests for Earshot Bridge.

The bridge is the one place where something outside this machine, a browser
extension, can ask for something to happen on it. Most of what follows is
therefore about what it refuses.
"""

import json
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(os.path.dirname(HERE), 'bridge', 'earshot-bridge.py')

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

print('')
print('passed %d, failed %d' % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
