# Earshot for Web

A browser extension that tells you when Claude on claude.ai finishes, needs you,
or hits a limit. Part of [Earshot](../BRAND.md), by Azyzex.

**Not affiliated with Anthropic.**

## Testing it

See [TESTING.md](TESTING.md). The important part needs no install: paste
[`probe.js`](probe.js) into the console on claude.ai and it reports what the
page actually looks like while Claude is writing and after it stops.

## Installing it

Not in any store yet. To load it by hand:

1. Open `chrome://extensions` (or `edge://extensions`)
2. Turn on **Developer mode**
3. **Load unpacked**, and choose this folder

Firefox: `about:debugging` → This Firefox → Load Temporary Add-on → pick
`manifest.json`.

## What it can and cannot do

It asks for the narrowest permissions that do the job:

| Permission | Why |
| --- | --- |
| `https://claude.ai/*` | The only site it runs on. Not `<all_urls>`. |
| `notifications` | To show one. |
| `storage` | Your four toggles, and a list of recent alert kinds. |
| `nativeMessaging` | **Optional**, requested only if you turn on the desktop link. |

It does **not** ask for tabs, history, cookies, downloads, or any other host.

**It never reads your messages.** It watches whether the stop button exists, to
know when a response is running. The one place it looks at text is deciding
whether you have hit a limit, and that text is never stored or sent anywhere.

**It makes no network requests.** Not to Anthropic, not to me, not to anyone.
There is no analytics and no telemetry.

**It consumes no tokens.** It only observes a page you already have open.

## The desktop link

Off by default. Turn it on and alerts also go to
[Earshot Bridge](../bridge/), which hands them to the notifier already installed
on your machine, so the browser and your terminal sound the same and obey the
same mute and quiet hours.

The bridge uses native messaging: the browser launches it directly over stdin
and stdout. No port is opened, and it accepts nothing but one of three alert
kinds.
