# Testing Earshot for Web

The extension has to tell "Claude is still writing" from "Claude has stopped".
Every selector in it is currently a guess about a page nobody involved has
inspected. This finds out the truth.

---

## The only part that matters

Four steps, about two minutes. **No extension needs to be installed.**

1. Open a conversation on [claude.ai](https://claude.ai)
2. Press **F12**, click the **Console** tab
3. Paste the whole of [`probe.js`](probe.js), press Enter
4. Type this and press Enter:

   ```js
   earshotRun()
   ```

It then tells you what to do: send Claude something slow, and leave it alone.
When the reply finishes it prints one report. Copy everything between
`--- Earshot report ---` and `--- end of report ---`.

That is the whole job.

**It never reads message text and sends nothing anywhere.** It records element
tags, a fixed list of attributes, and which buttons are disabled.

### If you would rather do it by hand

The pieces are available separately: `earshotProbe('a label')` for a snapshot,
`earshotWatch()` and `earshotWatchStop()` for the change log.

### Opportunistically

Next time you hit a usage limit naturally, run this while the message is
showing. Do not chase it on purpose:

```js
earshotProbe('rate limited')
```

---

## What the report answers

- **Which element exists while streaming and not afterwards.** That is how the
  extension knows a turn ended.
- **Whether the stop control has a stable `data-testid`.** Those survive
  redesigns; aria-labels get reworded and translated.
- **Whether send is a separate button or the same control changing role.** If
  it is one control, the signal is an attribute changing rather than an element
  appearing.
- **Whether `disabled` is set as a property, an attribute, or both.** React
  often sets the property alone, and an attribute-only check would miss it.
- **Whether the composer being empty looks the same as a finished turn.** If it
  does, "send exists" is not a usable signal on its own.

---

## Checking the extension end to end

Only worth doing once the selectors are right.

1. `chrome://extensions` (or `edge://extensions`)
2. Turn on **Developer mode**, top right
3. **Load unpacked**, choose the `extension/` folder
4. Ask Claude something slow, switch to another tab
5. You should get a notification and a chime when it finishes
6. Click the Earshot icon: the popup lists what it saw

**If nothing happens**, the popup's Recent list is the thing to check. Empty
means the page never looked finished to it, which is a selector problem.

This part cannot be automated, and it is not worth trying. `chrome://extensions`
is deliberately off limits to browser automation, and Claude's own browser
integration will not drive claude.ai at all: it is blocked at the domain level.
