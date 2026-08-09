# Plan: reset alerts from every surface

The goal, stated once: **tell me when my 5 hour window resets, whether or not I
ever hit the limit, no matter which surface I was using.**

Today that works only if Claude Code is opened at least once during the window,
because the Claude Code statusline is the only thing on the machine that is
handed `rate_limits.five_hour.resets_at`. This plan closes the gap, or proves
it cannot be closed cheaply and says so.

Two rules constrain every option below, and they are not negotiable: **no
tokens consumed**, and **the least permission that does the job**.

---

## The problem that shapes the design: whose limits are these

You might have Claude Code signed into one account and the browser signed into
another. The 5 hour window is per account. So a reset time learned in one place
is simply **wrong** for the other, and a system that quietly merged them would
produce confident, incorrect alerts. That is worse than staying silent.

So identity is not a detail to add later. It is the first thing every source
must report:

- **Every source records which account it observed.** The browser knows its
  organisation id. Claude Code needs an equivalent, and finding one is a task
  below, not an assumption.
- **Sources are only merged when the identifier matches.** Never otherwise.
- **When identifiers cannot be established, sources stay separate** and each
  alert says where it came from. Two honest alerts beat one confident wrong one.
- **Identifiers are stored hashed and truncated.** Enough to tell two accounts
  apart, never enough to be an account identifier sitting in a file.

---

## Phase 1: find out what the browser can actually see

**Cost: one console paste. No permissions, no install, no requests.**

`extension/probe-limits.js` reports three things: which storage keys exist and
whether their values are shaped like a timestamp or a percentage, which API
paths the page has already called, and the organisation id.

It reads no request bodies, no response bodies, and no message text. Values are
described by shape, never by content. Endpoint URLs come from the browser's own
performance timeline, which is precisely why this is safe: it reveals what
exists without touching what it returns.

Three possible outcomes, each of which decides Phase 2:

1. **A reset time is already in storage.** Best case. Read it, no new
   permission, done.
2. **A usage endpoint exists but must be read.** Then it becomes a judgement
   call, made explicitly in Phase 2 rather than drifted into.
3. **Nothing.** A real answer. The extension cannot do this, we say so in the
   README, and effort goes to Phase 4 instead.

### Phase 1 result, 9 August 2026

**Outcome 2.** Nothing usable is in storage: the timestamps found there belong
to Intercom, a Google tag, and dismissed banners. But the page calls an
endpoint of its own:

```
/api/organizations/<uuid>/usage
```

`overage_spend_limit` is billing and not relevant.

So the reset time is not lying around in the page, but there is an endpoint
that plausibly holds it. Whether it does, and what it costs to read, is
Phase 2.

---

## Phase 2: decide, only after Phase 1 reports

Written now so the decision is made on principle rather than on whatever is
convenient once the data is in.

**Acceptable:** reading a value the page already stores. Nothing is
intercepted, nothing new is requested, no permission is added.

**Acceptable with care:** one request to a usage endpoint, on a slow cadence,
only while a claude.ai tab is open. It consumes no tokens, since usage
endpoints do not run a model. It needs `host_permissions` we already hold. The
cost is honesty: the README must state plainly that the extension makes this
request and why.

**Not acceptable without a much better reason than convenience:** wrapping
`fetch` to inspect responses. It would work, and it needs no new manifest
permission, which is exactly what makes it tempting. But it puts our code in
the path of **every** response including message content. That trades a large
amount of your privacy for a countdown. If Phase 1 shows this is the only way,
the honest answer is to not do it and to explain why in the README.

### Phase 2 decision, 9 August 2026

`/usage` returns exactly what was needed:

```
five_hour: { utilization: 93, resets_at: <ISO timestamp> }
seven_day: { utilization: 35, resets_at: <ISO timestamp> }
```

Same field names the Claude Code statusline is handed, so both sources agree
without translation, and the weekly window comes free.

**Taken: the "acceptable with care" route.** One GET every ten minutes, only
while a claude.ai tab is open, to an endpoint the page already calls itself. It
runs no model, so it costs nothing. It needs no permission beyond the
`host_permissions` already held.

**Refused, as written in advance: wrapping `fetch`.** It was never needed.

Only four values are kept: two percentages and two timestamps. Everything else
the endpoint returns, including every field about money, is dropped at the
bridge rather than carried around and ignored. CI now fails the build if
`webRequest`, `debugger` or `scripting` ever appear in the manifest.

---

## Phase 3: connect the surfaces, and prove it

The wiring exists and has never been run end to end.

1. Load the extension unpacked, get its ID
2. `python bridge/install-bridge.py --extension-id <id>`
3. Turn on the bridge in the popup
4. Confirm a real browser event reaches the notifier and the phone

Then extend the message contract from three kinds to carrying limit state:
`{kind: 'limits', account: <hash>, five_hour: {used, resets_at}}`. The bridge's
allowlist grows by exactly one kind, and the account field is validated as a
hash and nothing else. Its tests grow with it.

The desktop app reads the same `claude-limits.json`, so it inherits all of this
without changes.

---

## Phase 4: the Claude desktop app

**Investigated 9 August 2026. Nothing usable, and that is the answer.**

On Windows it is a Store package, so its data is redirected to
`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude`.
Inside is an ordinary Electron layout. Neither Local Storage nor Session Storage
mentions a window or a reset time. The one match anywhere is inside an IndexedDB
**blob**, which is a cached response body: evictable, undocumented, and not a
shape anything should be built on.

The route that would work is the one to refuse. The app keeps a session cookie
in an SQLite store encrypted with DPAPI, and decrypting it to call `/usage`
ourselves is strictly worse than the `fetch` wrapping already ruled out: it
would mean taking the user's credentials rather than reading one number. Not
doing it, and saying so.

### Why this matters less than it first appears

The window is **per account, not per surface**, and the numbers come from
Anthropic's servers. So it does not matter which surface learns the reset time:
if Claude Code or a claude.ai tab reads it, the countdown is correct even for a
window spent entirely in the desktop app.

The gap left is genuinely narrow: a window in which you open neither Claude Code
nor claude.ai in a browser. For that case there is no cheap, honest mechanism,
and the README should say so plainly rather than imply full coverage.

---

## Phase 5: identity, plumbed through

**Done, 9 August 2026.**

Rather than reshaping the shared file, each surface writes its own into
`~/.claude/claude-limits.d/`, tagged with the account it saw. The watcher reads
every one of them, and the fired-already key is `window@account` rather than
just the window, so one account cannot silence another.

Nothing merges. That was the whole point.

Two things fell out of building it that were not obvious beforehand:

- **The status line is handed an epoch; the web returns an ISO string.** The
  watcher skips anything non-numeric, so the browser's reading would have been
  stored successfully and then silently ignored forever. The bridge converts.
- **`[ -f x ] && printf` inside a function is fatal under `set -e`.** When the
  shared file was absent the test came out false, took the subshell down with
  it, and the source list came back empty. The same trap this project has hit
  before, in a new place.

Both are covered by tests now, on Unix and on Windows. Windows had no watcher
tests at all before this, which was a poor place to have a coverage gap given it
is the platform most of this runs on.

---

## Considered and rejected: spawning a Claude session to read `/usage`

`/usage` inside a session really does cost nothing, so the idea of having a
button run it in the background is a reasonable one. It does not survive
contact with the CLI:

- There is **no `claude usage` subcommand**. `claude --help` lists agents, auth,
  doctor, mcp, plugin, project and a few others. Nothing reports usage.
- The only way to reach `/usage` is inside a session, and driving one
  non-interactively goes through the path that talks to a model. The command is
  free *because you are already in a session*; the session is the cost, not the
  command. A button that spawned one to avoid spending tokens could end up
  spending them.

It is also unnecessary. The status line is handed `rate_limits` on **every
redraw**, and the extension reads the usage endpoint directly, so the figures
already arrive free whenever either is used. What was missing was somewhere to
see them, which is now a panel in the app rather than a session in the
background.

The same reasoning rules out the other tempting shortcut: reading Claude Code's
stored credentials to call the usage endpoint from the app. That is the same
move as decrypting the desktop app's cookie, already refused in Phase 4, and it
is refused here for the same reason.

## What is already true

- Reset alerts work today, given Claude Code opened once in the window
- They fire at any usage level, not only at 100%
- No tokens are consumed at any point
- The terminal, the bridge and the app already share one notifier, one mute,
  one set of quiet hours and one log

## Known gaps, stated plainly

- A window spent entirely in the Claude desktop app is not covered yet
- The web leg has never run end to end in a real browser. Every piece is
  tested, and the chain between them is not
- A real 5 hour reset has never been observed firing in the wild; the tests
  pass, which is not the same thing
- The rate limited state of the page has never been captured
- VS Code, mobile and connectors are out of scope and expected to stay so
