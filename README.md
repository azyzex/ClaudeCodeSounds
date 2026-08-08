# Claude Code Sounds

[![CI](https://github.com/azyzex/ClaudeCodeSounds/actions/workflows/ci.yml/badge.svg)](https://github.com/azyzex/ClaudeCodeSounds/actions/workflows/ci.yml)

Sound alerts for [Claude Code](https://code.claude.com), so you know when it needs you without watching the terminal.

Claude Code is fast enough that the bottleneck is often your attention, not the model. You give it a task, switch to something else, and come back ten minutes later to find it has been sitting there the whole time waiting for you to approve one file edit. Or it finished eight minutes ago. Or it stopped on an error you never saw.

This wires four distinct sounds to four points in Claude Code's lifecycle:

| Sound | Fires when |
| --- | --- |
| Soft chime | Claude finished the turn |
| Alert, twice, plus a desktop notification | Claude is waiting on you: a permission prompt, an idle prompt, or a subagent that needs input |
| Alarm, plus a desktop notification | You hit your usage limit |
| Alarm, plus a desktop notification | The turn died on some other API error |

It installs into `~/.claude/settings.json`, so it applies to every project and every terminal with no per-repository setup. It also stays quiet when you do not need it: see [Options](#options).

## Install

### Windows (PowerShell)

Read the script first, then run it:

```powershell
irm https://raw.githubusercontent.com/azyzex/ClaudeCodeSounds/main/install-claude-sound-alerts.ps1 -OutFile install.ps1
notepad install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

If you would rather not read it, the one-liner is:

```powershell
irm https://raw.githubusercontent.com/azyzex/ClaudeCodeSounds/main/install-claude-sound-alerts.ps1 | iex
```

### Linux and macOS

```bash
curl -fsSL https://raw.githubusercontent.com/azyzex/ClaudeCodeSounds/main/install-claude-sound-alerts.sh -o install.sh
less install.sh
bash install.sh
```

Either way, restart Claude Code afterwards and run `/hooks` to confirm all five entries are listed.

The installer plays a test tone at the end. If you hear it, the audio path works.

## What it changes

Two files, both under `~/.claude`:

- `claude-notify.ps1` or `claude-notify.sh` is created. This is the script that actually picks a sound and plays it.
- `claude-sounds/` is created, holding the nine bundled alert sounds.
- `settings.json` is backed up with a timestamp, then the hook entries are added to it.
- `claude-notify.conf` is created if absent. Your edits to it are never overwritten.

The installer merges rather than replaces. Any hooks you already have are left alone. It is safe to re-run: it strips its own entries before writing, so running it twice does not stack duplicates and give you overlapping chimes.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\install-claude-sound-alerts.ps1 -Uninstall
```

```bash
bash install-claude-sound-alerts.sh --uninstall
```

This removes the notifier script and its own hook entries, and leaves the rest of your settings untouched. Timestamped backups are kept either way, so you can always restore by hand.

To silence the alerts temporarily without uninstalling, set `"disableAllHooks": true` in `~/.claude/settings.json`.

## How it works

Claude Code has a [hooks](https://code.claude.com/docs/en/hooks) system: you attach a command to a named point in its lifecycle and it runs deterministically, without the model having to decide to call it. These events matter here.

- **`Stop`** fires at the end of every turn. No matcher, it always fires.
- **`Notification`** fires when Claude wants something from you. It takes a matcher on notification type, so this setup listens for `permission_prompt`, `idle_prompt`, `agent_needs_input`, and `elicitation_dialog`, and deliberately ignores the rest. You do not want a chime for `auth_success`.
- **`StopFailure`** fires when a turn ends on an error, and it takes a matcher on error type. One of the values is `rate_limit`, which means hitting your usage limit can have its own distinct sound instead of being lumped in with every other failure. That is the alert that is genuinely hard to get any other way.
- **`StopFailure`** again, matched against every remaining error type, for real failures.
- **`UserPromptSubmit`** records when a turn started, so `Stop` can tell a ten-minute turn from a four-second one. It plays nothing.

Two details make the difference between this being useful and being actively annoying.

**`async: true`.** Without it, Claude Code blocks for the full length of the audio clip at the end of every single turn. You feel it immediately.

**Debouncing.** Several of these events can fire inside the same second, and you get a stutter of overlapping sounds. The notifier keeps a timestamp in the temp directory and ignores anything that arrives within a couple of seconds of the last alert.

## Options

The installer asks about each option the first time you run it, and writes your answers to `~/.claude/claude-notify.conf`. Same file, same option names on every platform. To change them later:

```bash
bash install-claude-sound-alerts.sh --config
```

```powershell
powershell -ExecutionPolicy Bypass -File .\install-claude-sound-alerts.ps1 -Configure
```

Or edit the file directly. The notifier re-reads it on every alert, so changes take effect immediately with no reinstall and no restart. The installer never overwrites an existing config.

| Option | Default | What it does |
| --- | --- | --- |
| `MIN_SECONDS` | `30` | Stay silent when a turn finished faster than this. Short back-and-forth turns are the main source of alert fatigue. `0` disables the check. |
| `SUPPRESS_WHEN_FOCUSED` | `1` | Skip the alert when the terminal is already the focused window, on the basis that you are evidently already looking at it. |
| `PROJECT_PITCH` | `1` | Pick the finish sound from the working directory, so with several terminals open you can tell which project it was. |
| `SPEAK` | `0` | Read the alert aloud instead of playing a sound. Falls back to the normal chime if no working speech synthesiser is present. |
| `TOAST_ON_DONE` | `0` | Also raise a desktop notification when a turn merely finishes. |
| `DEBOUNCE_SECONDS` | `2` | Ignore repeat alerts for this long, so overlapping events do not stutter. |
| `ALWAYS_ALERT` | `blocked,limit,error` | Kinds that ignore `MIN_SECONDS` and the focus check, because you want to know regardless. |
| `MUTE` | empty | Kinds to silence completely. |
| `QUIET_HOURS` | empty | Silence everything inside a window, for example `23:00-08:00`. Windows that wrap past midnight work. |
| `SOUND_PACK` | `default` | Which pack to use. See below. |

### Per-event settings

Each of the four kinds — `DONE`, `BLOCKED`, `LIMIT`, `ERROR` — has its own group.

| Option | What it does |
| --- | --- |
| `<KIND>_ENABLED` | `0` turns that one kind off. |
| `<KIND>_VOLUME` | `0-100`. |
| `<KIND>_PATTERN` | How many times to play, optionally `NxMS` for the gap. `3x140` is three pulses 140ms apart. |
| `<KIND>_SOUND` | Full path to your own file, overriding the built-in choice. |

Rhythm is worth more than it sounds. Pitch is hard to place when you are not paying attention, but three quick pulses reads as urgent from across the room. The defaults use it: one pulse for a finished turn, two when something needs you, three tighter ones for a rate limit.

Volume has platform limits. On Windows anything below 100 plays through `MediaPlayer` rather than `SoundPlayer`, which has no volume control at all. On Linux `aplay` and `canberra-gtk-play` cannot set volume and play at the system level.

The config file is parsed, never sourced, so nothing in it can execute.

How well the focus check works varies by platform, and it is deliberately conservative: any uncertainty resolves to "not focused", so the failure mode is an alert you did not strictly need rather than a missed one.

- **Windows** compares the foreground window's process against this process's ancestry, so it answers "is *my* terminal in front", not merely "is a terminal in front".
- **macOS** compares the frontmost application against a list of known terminals and editors, so it is app-level rather than window-level.
- **Linux** needs `xdotool` under X11. Wayland exposes no portable way to ask, so there it always alerts.

## Customising the sounds

Everything in the table above is a config change. Only the sound files themselves need editing `~/.claude/claude-notify.ps1` or `~/.claude/claude-notify.sh`, and re-running the installer overwrites those, so keep a copy of your changes. Your config file is safe either way.

Nine sounds are installed to `~/.claude/claude-sounds/default/`, and they are what you hear by default on every platform. That is deliberate: relying on system sounds meant the alerts differed per machine, and on a minimal Linux install there were often none at all.

The quickest way to use your own is `<KIND>_SOUND` in the config, which takes a full path and needs no editing of any script.

If the bundled sounds are missing, the notifier falls back to the system set: `C:\Windows\Media` on Windows, `~/Library/Sounds` and `/System/Library/Sounds` on macOS, and the freedesktop theme directories on Linux.

The sounds are generated rather than sourced, by `build/make-sounds.py`, so they are reproducible and carry no licensing question. Six of the nine are interchangeable finish chimes, which is what gives `PROJECT_PITCH` its range.

### Sound packs

A pack is just a folder. To make your own, put `.wav` files in `~/.claude/claude-sounds/<name>/` using the same filenames as `default/`, then set `SOUND_PACK=<name>`.

You do not need a complete set. Anything the pack is missing falls back to `default/`, so a pack containing one file changes exactly one sound.

The filenames are `chime-glass`, `chime-soft`, `chime-bright`, `chime-low`, `chime-warm` and `chime-mid` for finished turns, then `alert-attention`, `alert-limit` and `alert-error`.

## Troubleshooting

**Nothing fires at all.** Restart Claude Code first, since settings are read at startup. Then run `claude --debug` and watch for the hook lines as events happen.

**Hooks run but there is no sound.** First find out what the notifier actually decided. It will tell you:

```bash
CLAUDE_NOTIFY_DEBUG=1 ~/.claude/claude-notify.sh blocked
```

```powershell
$env:CLAUDE_NOTIFY_DEBUG=1; & "$env:USERPROFILE\.claude\claude-notify.ps1" -Kind blocked
```

```
kind=blocked sound=/usr/share/sounds/freedesktop/stereo/dialog-warning.oga player=paplay notified=notify-send detail=...
```

`sound=none` means no sound file was found. `player=bell` on Unix, or `player=beep` on Windows, means a file was found but playback failed, so it fell back to a raw tone. That distinction tells you which of the two fixes below you need.

A `suppressed=` field instead means it worked exactly as configured and chose to stay quiet: `too-quick` (under `MIN_SECONDS`), `focused`, `debounced`, `quiet-hours`, or `muted`.

To see what it *would* do without actually hearing it, add `CLAUDE_NOTIFY_DRYRUN=1`. It resolves the sound, volume and pattern and reports them, but plays nothing and raises no notification.

On a minimal Linux install, the sound theme is often missing:

```bash
sudo apt install sound-theme-freedesktop libcanberra-gtk-module
```

On Linux you also need a player that handles `.oga` files. `paplay`, `pw-play`, and `canberra-gtk-play` all do; `aplay` only handles `.wav`.

**No desktop notification on macOS.** `osascript` routes notifications through Script Editor, which fails silently if it lacks notification permission. Run `osascript -e 'display notification "test"'` once, then enable Script Editor under System Settings, Notifications.

**Wrong sound for the wrong event.** Run `/hooks` and check the matcher strings against the [matcher values in the docs](https://code.claude.com/docs/en/hooks). An invalid matcher does not error, it just never matches.

## Requirements

- Claude Code with hooks support
- Windows: PowerShell 5.1 or later, which ships with Windows 10 and 11
- Linux and macOS: `bash`, plus `python3` for the installer only. The alerts themselves need no Python. A desktop notification needs `notify-send` on Linux or `osascript` on macOS, but sound works without either.

## Development

Both test suites run the real installer against a throwaway home directory, so they never touch your own `~/.claude`.

```bash
bash tests/test-unix.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File tests\test-windows.ps1
```

CI runs them on Linux, macOS and Windows, along with `shellcheck` and `PSScriptAnalyzer`. See [CONTRIBUTING.md](CONTRIBUTING.md) for what the tests protect and how to lint the generated notifier scripts.

## Notes and limitations

The two installers are separate scripts rather than one cross-platform script, because the audio and notification paths have nothing in common between Windows and Unix.

There is a cleaner route I did not take. Hooks can return a `terminalSequence` field and let Claude Code emit the notification escape sequence itself, which hands the decision to your terminal emulator and would work identically everywhere. It is worth looking at if you want your existing terminal notification setup to handle this instead of a bespoke script.

The Linux and macOS script is exercised by CI on real Linux and macOS runners, covering the settings merge, idempotency, uninstall, sound-file selection and the player fallback chain. What CI cannot cover is audio itself: the runners have no audio device, so the moment a player actually opens a sink is still the least proven part of this. If a sound does not play on your setup, open an issue with your distribution and audio stack and I will add it to the fallback chain.

## License

MIT. See [LICENSE](LICENSE).
