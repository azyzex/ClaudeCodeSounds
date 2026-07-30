# Contributing

Thanks for looking. This is a small project with a narrow job: make Claude Code tell you when it needs you, on any platform, without becoming annoying.

## The thing most likely to be useful

Sound and notification coverage on machines I do not have. The Windows path is in daily use. The Linux and macOS path is covered by CI on GitHub's runners, which have no audio device, so the player and notification calls are the least proven part of this. If a sound does not play on your setup, the [sound issue template](.github/ISSUE_TEMPLATE/sound-not-playing.yml) asks for exactly the information needed to add your case to the fallback chain.

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
shellcheck -S warning install-claude-sound-alerts.sh tests/test-unix.sh
```

```powershell
Invoke-ScriptAnalyzer -Path install-claude-sound-alerts.ps1 -Settings .github\PSScriptAnalyzerSettings.psd1
```

One wrinkle worth knowing: **the notifier scripts are generated**, written out by the installer from a heredoc. Linters treat that heredoc as inert text and never look inside it, so CI installs into a temp directory first and then lints the file the installer actually emitted. If you change the notifier body, run the linter the same way or the change goes unchecked.

Rule exclusions live in `.github/PSScriptAnalyzerSettings.psd1`, each with the reason it is excluded. If you need another one, add the reason too.

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
