# Earshot Bridge

The local link between [Earshot for Web](../extension/) and the notifier already
installed on your machine. Part of [Earshot](../BRAND.md), by Azyzex.

Turn it on and a browser alert sounds exactly like a terminal one, obeying the
same mute, quiet hours, volume and log.

## Installing

```
python bridge/install-bridge.py --extension-id <id from chrome://extensions>
python bridge/install-bridge.py --uninstall
```

The extension ID is required rather than defaulted. That ID is the allowlist: a
manifest trusting any extension would let any extension on your machine start
the bridge.

## Why native messaging and not a local server

A local HTTP server is the obvious way to let a browser reach your machine, and
the wrong one. It opens a port every other program on the machine can reach, so
it needs its own authentication, and it is one bad default away from being
reachable from outside.

Native messaging has none of that. The browser launches this program directly
and talks over stdin and stdout. **No port is opened, nothing listens, and
nothing runs when the browser is closed.**

## What it accepts

One field, `kind`, and only `done`, `blocked` or `limit`.

Not a path, not a command, not a URL, not text to display. The worst a
compromised extension achieves through this is playing one of three sounds.

There are tests for exactly that, including that `rm -rf /` and
`../../etc/passwd` as a kind are refused, that malformed frames are survived
rather than crashed on, and that repeats are rate limited.

## Requirements

Python 3, which the Unix installer already needs. Nothing else.
