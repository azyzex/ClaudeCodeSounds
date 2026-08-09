# What claude.ai actually does

Measured on 9 August 2026, Chrome on Windows, by running
[`probe.js`](probe.js) against a live conversation. Everything here is
observed, not assumed. Earlier versions of the detector were guesses; this
replaced them.

## The signal

While a reply is streaming:

```
div[role="feed"][aria-label="Chat messages"]  aria-busy="true"
button[aria-label="Stop response"]            present, enabled
button[aria-label="Send message"]             present, DISABLED
```

Once it finishes, the stop button is gone and the feed is no longer busy.

**`aria-busy` on the feed is the signal to build on**, with the stop button as
a fallback. It is an accessibility contract rather than a label, so it does not
get reworded in a redesign, and it does not change in another language the way
`"Stop response"` would.

## Three things this corrected

**There is no `data-testid` on the send or stop controls.** The only ones on
the whole page are `pin-sidebar-toggle`, `user-menu-button` and
`model-selector-dropdown`. A test id would have been the sturdiest hook, and it
simply is not available, so this was worth knowing before relying on one.

**Send and stop are separate buttons that coexist**, rather than one control
swapping roles. Send stays in the DOM while streaming and is disabled. So
"a send button exists" says nothing about whether a turn is running, and
`disabled` alone cannot be the signal either, since it is also true whenever
the composer is empty.

**`disabled` is set both ways here**, as the attribute and the property. That
is not guaranteed elsewhere in the page, so the probe records both.

## Consequences for the extension

The observer now watches attributes, not only added and removed nodes. The end
of a turn can be nothing more than `aria-busy` flipping, and a childList-only
observer would miss it entirely. The filter is narrow, so this stays cheap.

## Still unmeasured

- **The rate-limited state.** Not worth burning a usage window to capture.
  Run `earshotProbe('rate limited')` if you hit one naturally.
- **A dialog needing input.** `role="dialog"` is the assumption, still untested.
- **claude.ai has its own "notify me when Claude responds" feature.** Worth
  knowing what it covers before duplicating it.
