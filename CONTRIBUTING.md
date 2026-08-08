
# Contributing

Thanks for looking. This is a small project with a narrow job: make Claude Code tell you when it needs you, on any platform, without becoming annoying.

## The thing most likely to be useful

Sound and notification coverage on machines I do not have. The Windows path is in daily use, and CI plays real sound files through real players on Linux and macOS runners. What CI cannot cover is desktop notifications, because its runners have no notification daemon or GUI session, so that is the least proven part of this. If a sound does not play on your setup, the [sound issue template](.github/ISSUE_TEMPLATE/sound-not-playing.yml) asks for exactly the information needed to add your case to the fallback chain.

## Running the tests

Both suites run the real installer against a throwaway `HOME` or `USERPROFILE`, so they never touch your own `~/.claude`.

```bash
bash tests/test-unix.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File tests\test-windows.ps1
```

They cover a fresh install, merging into existing settings, idempotency across repeated runs, uninstall leaving unrelated hooks alone, refusing to clobber malformed JSON, and the notifier exiting cleanly for every alert kind.

## Linting

CI runs both linters and they must be clean.

```bash
shellcheck -S warning install-claude-sound-alerts.sh notifier/claude-notify.sh tests/test-unix.sh
```

```powershell
Invoke-ScriptAnalyzer -Path install-claude-sound-alerts.ps1 -Settings .github\PSScriptAnalyzerSettings.psd1
```

Rule exclusions live in `.github/PSScriptAnalyzerSettings.psd1`, each with the reason it is excluded. If you need another one, add the reason too.

## The installers are generated

**Do not edit `install-claude-sound-alerts.sh` or `install-claude-sound-alerts.ps1` directly.** They are built from two sources:

```
templates/install-claude-sound-alerts.sh.in   the installer logic
notifier/claude-notify.sh                     the notifier it writes out
        |
        +--> build/generate.py --> install-claude-sound-alerts.sh
```

Edit the template or the notifier, then regenerate:

```bash
python build/generate.py
```

Commit both the source and the regenerated installer. CI runs `python build/generate.py --check` and fails if they have drifted.

This exists because the installers are distributed as one file each, since people pipe them straight from a URL, but the notifier inside them is also what the desktop app ships. Keeping the notifier as a real file means there is one copy rather than two that silently diverge. It has a useful side effect: linters can read the notifiers directly, where previously they treated the heredoc as inert text and skipped it entirely.

## Things to preserve when editing the installers

These are the properties the tests exist to protect. Please do not regress them.

- **Merge, never replace.** People have their own hooks in `settings.json`. Read it, add to it, write it back.
- **Back up first.** Timestamped, before any write.
- **Stay idempotent.** Strip our own entries, recognised by the `claude-notify` filename, before adding them. Running the installer twice must not produce two chimes.
- **No BOM.** `Set-Content -Encoding utf8` on PowerShell 5.1 adds one and it breaks strict JSON parsers. The installer writes bytes directly to avoid this.
- **Keep the PowerShell files pure ASCII.** PowerShell 5.1 reads a BOM-less file as ANSI, so a stray em dash in a comment renders as mojibake.
- **Never let the notifier fail loudly.** It runs on every turn. It swallows errors on purpose, degrades to a terminal bell when no player works, and always exits 0.
- **Keep `async: true`.** Without it Claude Code blocks for the length of the audio clip on every single turn.
- **Keep the debounce.** Several events can fire in the same second.

## Verifying hook behaviour against the docs

Matcher strings fail silently. An invalid matcher does not error, it just never fires, which is indistinguishable from a broken sound. If you add or change an event, check the value against the [hooks reference](https://code.claude.com/docs/en/hooks) rather than inferring it, and note that matchers made only of letters, digits, `_`, `-`, spaces, `,` and `|` are treated as exact strings or a `|`-separated list, while anything else is a JavaScript regex.

## Commits and pull requests

Explain why in the commit message, not just what. If you fixed something subtle, the reasoning is the valuable part. Small, focused pull requests are easier to take than large ones.
