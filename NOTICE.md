# Notice

## This is an unofficial, independent project

ClaudeCodeSounds is **not affiliated with, endorsed by, sponsored by, or
connected to Anthropic PBC** in any way. It is an independent tool written by a
third party.

"Claude", "Claude Code" and "Anthropic" are trademarks of Anthropic PBC. They are
used here only to describe what this tool works with, which is nominative fair
use. No claim to those marks is made or implied.

If you have a problem with this tool, raise it
[here](https://github.com/azyzex/ClaudeCodeSounds/issues). Do not raise it with
Anthropic: they did not write it and cannot support it.

## What it does with your data

Nothing leaves your machine unless you switch it on. Specifically:

- **Config and logs stay local.** `~/.claude/claude-notify.conf`,
  `claude-notify.log`, `claude-limits.json` and the sounds are all files on your
  own disk. Nothing is uploaded, and there is no analytics or telemetry of any
  kind.
- **The log records alerts, not conversations.** It stores the alert kind, the
  outcome, and the short notification text Claude Code passes to the hook, such
  as "waiting on your input". It does not store your prompts or Claude's
  replies.
- **Phone push is off by default.** If you set `NTFY_TOPIC`, alert titles and
  their short text are sent to the ntfy server you configure, by default the
  public `ntfy.sh`. **The topic name is the only thing protecting them**, so
  anyone who knows it can read and send. Use a long random topic, and do not put
  anything sensitive in an alert.
- **Nothing is sent to Anthropic.** The usage figures this tool shows are ones
  Claude Code already hands to its own status line. No API request is made and
  no tokens are consumed.

## Reading Claude Code's session data

The status line integration reads the session JSON that Claude Code passes to
any configured status line command, which is a documented extension point. It
saves only the usage percentages and reset timestamps.

It writes to `~/.claude/settings.json` to register its hooks and status line.
An existing status line is never overwritten, and uninstall removes only this
project's own entries.

## No warranty

This software is provided as is, without warranty of any kind, as set out in
[LICENSE](LICENSE). It makes sounds and shows notifications. It is not a
reliable alarm, and you should not depend on it for anything that matters.

In particular, the usage and reset figures are read from data Claude Code
provides. If that data is absent, stale, or changes shape in a future release,
the alerts may be wrong or may not fire. Treat them as a convenience.

## Third-party services

- **[ntfy](https://ntfy.sh)** is used only if you enable phone push. It is a
  separate service with its own terms and privacy policy. This project is not
  affiliated with it.

Nothing else is contacted.
