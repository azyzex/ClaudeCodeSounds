# Earshot

**Know when it needs you.**

Earshot, by Azyzex, is a family of small tools that tell you when an AI
assistant wants your attention, so you can go and do something else.

The name is the whole idea: within earshot. You are not watching the screen, and
you do not need to.

## Why a brand at all

This started as sound alerts for one terminal. It now covers usage limits, phone
push, a desktop app, and soon the browser. "ClaudeCodeSounds" describes none of
that, and several separate pieces need names that show they belong together.

**Earshot is deliberately not a Claude name.** The [NOTICE](NOTICE.md) states
there is no affiliation with Anthropic, and a brand built out of someone else's
trademark would undercut that. Earshot is a plain English word describing what
the tool does.

## The pieces

| Name | What it is | Status |
| --- | --- | --- |
| **Earshot for Claude Code** | The hooks and notifier. Sounds, desktop notifications, phone push, limit resets. | Shipped |
| **Earshot Desktop** | The tray app and settings window. Optional, always. | Shipped |
| **Earshot for Web** | A browser extension for claude.ai. | Planned |
| **Earshot Bridge** | The local link between the extension and everything else. | Planned |

Each works on its own. None requires any other. That is a rule, not an
aspiration: the notifier has always run without the app, and the extension will
run without either.

## How they connect

Everything shares one directory of small plain files, and nothing talks over the
network:

```
~/.earshot/
  limits.json      usage percentages and reset times, whoever saw them last
  alerts.log       what fired, and what was deliberately suppressed
  config           one file of KEY=value, hand-editable
  state/           watcher heartbeats, pending resets
```

The reason for files rather than a service is that a file has no port, no
listener, no daemon and no attack surface. Anything can read one; nothing has to
be running.

For continuity, `~/.claude/` remains the location while Earshot for Claude Code
is the only writer. The move to `~/.earshot/` happens when the extension lands,
with the old paths read as a fallback so nobody's setup breaks.

### The bridge, and why it exists

A browser extension cannot write to your disk. It needs something local to talk
to, and there are two ways to do that:

- **A local HTTP server.** Simple, and wrong. It opens a port that every other
  program on the machine can reach, so it needs its own authentication, and it
  is one misconfiguration away from being reachable off-machine.
- **Native messaging.** The browser launches a small local program and talks to
  it over stdin and stdout. No port, no listener, and only extensions you have
  explicitly allowlisted by ID can start it.

**Earshot Bridge uses native messaging.** It is a few dozen lines: read a JSON
message on stdin, validate it, write to the shared files, exit.

## Rules these tools are held to

These are the constraints the project has been built under, and the new pieces
inherit them.

**No tokens are ever consumed.** The status line integration reads what Claude
Code hands it. The extension reads a usage endpoint that runs no model. Nothing
here ever asks Claude to generate anything, so nothing Earshot does can eat into
the limit it is reporting on.

**Nothing is collected, ever.** No analytics, no telemetry, no crash reporting,
no phoning home. Nothing is sent to us, because there is no us to send it to.

**Two things reach the network, both named.** The extension reads claude.ai's
own usage endpoint every ten minutes while a tab is open, which is the only way
it can know when your window resets. And phone push, which is off by default and
goes only to the server you name. Both are documented in the NOTICE. There is
nothing else.

**The least permission that works.** The extension will request the narrowest
host permission that does the job, which is claude.ai and nothing else. No
`<all_urls>`, no tabs permission, no history, no cookies. If a feature needs a
broad permission, the feature loses.

**Content is never read or stored.** The tools care about events and numbers:
that a response finished, that a limit resets at a time. Not what you asked, not
what was answered. The existing log stores the alert kind and the short
notification text, and that stays the ceiling.

**Nothing is required.** Every piece is optional and removable, and removing one
never breaks another.

**No cost.** Nothing here is paid for, so nothing depends on a subscription, a
certificate, or a hosted service.

## What each piece may and may not do

| | Reads | Writes | Network |
| --- | --- | --- | --- |
| For Claude Code | hook payloads, status line session data | shared files, `settings.json` hooks | ntfy only, opt in |
| Desktop | shared files | shared files, `settings.json` hooks | update check only |
| For Web | the claude.ai page it is on | nothing directly, sends to the bridge | none |
| Bridge | messages from allowlisted extension IDs | shared files | none |

The extension writing nothing directly, and the bridge accepting nothing from
the network, is the point: the browser side can suggest, but a local program
decides.
