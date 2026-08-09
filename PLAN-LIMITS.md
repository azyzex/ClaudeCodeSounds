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

Worth doing regardless of Phase 1, and the only route that covers someone who
uses neither the terminal nor a browser.

It is an Electron app, so it keeps local state in a known place. The question
is whether any of it records the limit window. **Read only, no patching of
their app** — that would break on every update and is not something to ship to
other people.

If it does, it becomes a third source feeding the same file, with the same
account identity rule.

---

## Phase 5: identity, plumbed through

Once any second source exists:

- `claude-limits.json` becomes keyed by account hash rather than flat
- The watcher schedules one timer per account
- Notifications name the account only when more than one is known, so the
  common case stays quiet
- Tests cover the case that motivated all of this: two accounts, two windows,
  two different reset times, and no cross-contamination

---

## What is already true

- Reset alerts work today, given Claude Code opened once in the window
- They fire at any usage level, not only at 100%
- No tokens are consumed at any point
- The terminal, the bridge and the app already share one notifier, one mute,
  one set of quiet hours and one log

## Known gaps, stated plainly

- A window spent entirely on web or the desktop app is not covered yet
- The web leg of the bridge has never run end to end
- A real 5 hour reset has never been observed firing in the wild; the tests
  pass, which is not the same thing
- The rate limited state of the page has never been captured
- VS Code, mobile and connectors are out of scope and expected to stay so
