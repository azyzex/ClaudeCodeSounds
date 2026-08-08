# ClaudeCodeSounds — project overview

A briefing document. It describes what this project is, how it is built, what
already works, and what is being considered next. Written to be read on its own
by someone with no prior context.

Repository: https://github.com/azyzex/ClaudeCodeSounds

---

## What the project is

Sound alerts for [Claude Code](https://code.claude.com), so a developer knows
when the agent needs them without watching the terminal.

The problem it solves: Claude Code is fast enough that the bottleneck is often
your attention rather than the model. You give it a task, switch away, and come
back ten minutes later to find it has been sitting there the whole time waiting
for you to approve one file edit. Or it finished eight minutes ago. Or it
stopped on an error you never saw.

## How it works

Claude Code has a **hooks** system: you attach a shell command to a named point
in its lifecycle in `~/.claude/settings.json`, and it runs deterministically,
without the model deciding to call it. Five events are wired:

| Event | Matcher | Purpose |
| --- | --- | --- |
| `UserPromptSubmit` | none | Records a start time. Plays nothing. |
| `Stop` | none | The turn finished. |
| `Notification` | `permission_prompt\|idle_prompt\|agent_needs_input\|elicitation_dialog` | Claude needs you. |
| `StopFailure` | `rate_limit` | You hit the usage limit. |
| `StopFailure` | every other error type | The turn died on an API error. |

`StopFailure` filtering on `rate_limit` is the interesting one, and the hardest
alert to obtain any other way: hitting the usage limit gets its own distinct
sound rather than being buried in a generic failure.

Two details matter for it not being annoying. **`async: true`** on every hook,
or Claude Code blocks for the full length of the audio clip at the end of every
turn. And **debouncing**, because several of these events can fire inside the
same second.

## Architecture

```
notifier/claude-notify.sh      the notifier, Linux and macOS
notifier/claude-notify.ps1     the notifier, Windows
templates/*.in                 installer logic, with a placeholder for the above
sounds/default/*.wav           nine synthesised alert sounds
build/generate.py              templates + notifier + sounds -> single-file installers
build/make-sounds.py           synthesises the sounds
build/make-icons.py            draws the app icons (PNG, ICO, ICNS)
install-claude-sound-alerts.sh    GENERATED, do not edit
install-claude-sound-alerts.ps1   GENERATED, do not edit
app/                           Tauri v2 desktop configurator
tests/                         integration suites for both platforms
```

**The installers are generated.** They are distributed as one self-contained
file each, because people pipe them straight from a URL, but the notifier inside
them is also what the desktop app ships. Keeping the notifier as a real file
means one copy rather than two that drift. CI runs `generate.py --check` and
fails if they are out of sync.

**The notifier is the engine, and the app is optional.** The hooks own the
alerting. The app only writes the same config file you could edit by hand.
Removing the app leaves alerts working. This is a hard constraint, not a
preference.

### The notifier

One script per platform. On each alert it:

1. Reads `~/.claude/claude-notify.conf` fresh, so changes take effect with no
   restart. The file is **parsed, never sourced or invoked**, so nothing in it
   can execute. There are tests asserting exactly that.
2. Reads the hook payload from stdin (JSON, carrying `session_id`, `cwd`, and
   `message` for notifications).
3. Decides whether to alert at all, then plays a sound and optionally raises a
   desktop notification.
4. Records the decision to `~/.claude/claude-notify.log`.

### Suppression rules

The first version chimed on every turn, which is what makes a notifier get
switched off within a week. The useful version knows when to stay quiet:

| Option | Default | Effect |
| --- | --- | --- |
| `MIN_SECONDS` | 30 | Silent if the turn was shorter than this. Needs the `UserPromptSubmit` start time. |
| `SUPPRESS_WHEN_FOCUSED` | 1 | Silent if the terminal is already the focused window. |
| `QUIET_HOURS` | empty | e.g. `23:00-08:00`, wrapping past midnight. |
| `MUTE_UNTIL` | empty | Epoch second. An expiry rather than a flag, so a forgotten mute lifts itself. |
| `DEBOUNCE_SECONDS` | 2 | Ignore repeats. |
| `ALWAYS_ALERT` | `blocked,limit,error` | Kinds that bypass the elapsed and focus checks. |
| `MUTE` | empty | Kinds silenced entirely. |

Plus per-event: `<KIND>_ENABLED`, `_VOLUME`, `_PATTERN`, `_SOUND` for each of
`DONE`, `BLOCKED`, `LIMIT`, `ERROR`.

**Rhythm carries further than pitch.** `_PATTERN` is `N` or `NxMS`: `3x140` is
three pulses 140ms apart. Defaults are one pulse for finished, two for needs
you, three tighter for rate limited. That is recognisable from across a room in
a way a different chime is not.

`CLAUDE_NOTIFY_DEBUG=1` prints the decision. `CLAUDE_NOTIFY_DRYRUN=1` resolves
everything without playing. `CLAUDE_NOTIFY_FORCE=1` bypasses all suppression,
used by the app's preview button.

### Sounds

Nine sounds ship with the project, installed to
`~/.claude/claude-sounds/default/`. They are **synthesised** by
`build/make-sounds.py` rather than sourced, so they are reproducible from the
repo and carry no licensing question. Six interchangeable finish chimes give the
per-project pitch variation range; then one distinct sound per alert kind.

They are embedded in the installers as base64, so a single self-contained file
installs with no network access. Size had to come from the sound design rather
than compression, since PCM tones are high entropy and gzip only took 4% off:
11025 Hz, pitch set kept under Nyquist, exponential tails trimmed with a short
fade. That took 223KB down to 84KB per installer.

A **sound pack is a folder**. `SOUND_PACK=retro` looks in
`~/.claude/claude-sounds/retro/`, falling back to `default/` per missing sound,
so a pack containing one file changes exactly one sound.

### Desktop app

Tauri v2 (Rust backend, system webview, ~2MB installers). Windows and Linux;
macOS is deliberately deferred.

- Per-event rows: toggle, sound, volume, rhythm, and a **play button** that runs
  the real notifier rather than reimplementing playback
- Suppression settings in plain language
- Installs and removes the hooks itself, bundling the notifier and sounds as
  resources, so a machine that has never run the scripts needs no terminal
- Recent activity: what fired, and what was suppressed and why
- Tray icon with quick mute, "quiet for 30 minutes / an hour", and open settings

Rust owns parsing and writing the config; the frontend never touches the format.
Writes edit the file **in place**, preserving comments, ordering, and any key
the app does not recognise, because people hand-edit it.

### Testing

CI runs eight jobs on every push: integration suites on Linux, macOS and
Windows; `shellcheck`; `PSScriptAnalyzer`; the generated-installer check; and
the Rust app built and tested on Linux and Windows.

**197 assertions**: 85 Unix, 82 Windows, 30 Rust.

On Linux and macOS, CI installs real audio players and asserts a real player
handled the file rather than falling through to a fallback tone. The one thing
CI cannot cover is desktop notifications, since its runners have no notification
daemon or GUI session.

### Constraints worth knowing

- **Nothing in this project costs money.** No code signing certificates, so
  desktop builds are unsigned and the Gatekeeper and SmartScreen workarounds are
  documented rather than paid away.
- The notifier runs on **every turn**, so it must stay fast and dependency-free.
  Shell and PowerShell are already installed everywhere; that is why it is not
  Rust.
- The notifier must **never write to stderr** and must always exit 0. A
  notification failure is not worth breaking a turn over.

---

## Proposed next feature: a usage-limit reset notifier

**This is the part that does not exist yet, and the reason this document was
written.**

### The idea

Claude Code enforces a usage limit on a rolling window (commonly described as
five hours). When you hit it, work stops. The current project can already tell
you *that* you have been rate limited, with its own distinct sound, because
`StopFailure` exposes a `rate_limit` matcher.

What it cannot tell you is **when the limit resets**. That is the more useful
alert: being told "you can work again now" is worth more than being told "you
are blocked", because the second one is obvious the moment it happens and the
first one is the moment you actually want to come back.

Desired behaviour:

- When the limit is hit, work out when it resets
- At that moment, notify on the **desktop** and on the **phone**
- Ideally also a countdown visible in the app and the tray

### What is already in place for it

- The `StopFailure` / `rate_limit` hook already fires at the exact moment the
  limit is hit, and receives the error payload on stdin
- The notifier already parses fields out of that payload
- The desktop app is already tray-resident, so it has somewhere to run a timer
  and fire a notification later, which a hook cannot do because a hook exits
  immediately
- Desktop notification plumbing already exists on all three platforms

### Open questions to work through

1. **Where does the reset time come from?** The rate-limit error message may
   contain it. If so, parsing it is the whole job. If not, the fallback is to
   assume a fixed window from the moment the limit was hit, which is an estimate
   rather than a fact and should be presented as one.
2. **What does "five hours" actually mean** for the plan in question, and does
   it differ across plans? An alert that is confidently wrong is worse than none.
3. **Phone delivery.** See below.
4. **What if the machine sleeps** between hitting the limit and the reset? A
   timer in a resident process does not survive that reliably; a stored absolute
   timestamp checked on wake does.

### Phone push, explained

There is no need for a mobile app. The established pattern is a **push relay**:

**[ntfy.sh](https://ntfy.sh)** is the usual choice. You pick an unguessable
topic name, install the free ntfy app on your phone and subscribe to that topic,
and anything that can make an HTTP request can then push to it:

```
curl -d "Your Claude Code limit has reset" ntfy.sh/your-secret-topic-name
```

That is the entire integration. No account, no API key, no server, free, and it
is open source and self-hostable later if wanted.

The trade-offs to be honest about:

- **The topic name is the only secret.** Anyone who knows it can read your
  notifications and send to them. Use something long and random, and never put
  anything sensitive in the message body.
- **It leaves your machine.** The message transits a third-party server. For
  "your limit reset" that is unremarkable, but it is a different privacy posture
  from a purely local tool, and it should be off by default and opt-in.

Alternatives considered: Pushover (better polish, one-off payment, so ruled out
by the no-cost constraint), Telegram or Discord webhooks (work fine, but require
a bot and an account), and Apple or Google push directly (require developer
accounts and cost money).

---

## Current state

Five releases. Scripts at `v1.2.0`, app at `app-v0.2.0`, tagged separately so
they ship independently.

Remaining planned work: escalation for unanswered prompts, launch at login,
stats, a health check command, OS do-not-disturb awareness, auto-update, a small
CLI, and more hook events. A macOS app build is deferred. Per-project settings
are a parked idea, not scheduled.
