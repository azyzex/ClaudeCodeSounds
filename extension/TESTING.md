# Testing Earshot for Web

The extension has to tell "Claude is still writing" from "Claude has stopped".
The only honest way to know how is to look at a real page, so this is written
against facts rather than assumptions.

There are two jobs here. The first is the one that matters.

---

## Job 1: find out what the page actually looks like

**This is the important one, and it needs no extension installed.**

1. Open a conversation on [claude.ai](https://claude.ai)
2. Press **F12**, go to the **Console** tab
3. Paste the whole of [`probe.js`](probe.js) and press Enter
4. Ask Claude something that takes a while, for example *"write a 500 word essay
   about the sea"*
5. **While it is still writing**, run:

   ```js
   earshotProbe('while writing')
   ```

6. **Once it has finished**, run:

   ```js
   earshotProbe('after finishing')
   ```

7. Copy both blocks of output

The difference between those two is the whole answer: whatever is present during
the first and absent in the second is how the extension knows a turn ended.

The probe reads only element names and attributes. **It never reads message
text, and it sends nothing anywhere.**

### If you hit a usage limit

If you ever see the limit message on the web, run this while it is showing:

```js
earshotProbe('rate limited')
```

That is the hardest state to test on purpose and the most useful to capture.

---

## Job 2: check the extension end to end

Only worth doing after job 1, since the selectors may need correcting first.

1. Open `chrome://extensions` (or `edge://extensions`)
2. Turn on **Developer mode**, top right
3. **Load unpacked**, choose the `extension/` folder
4. Open a Claude conversation, ask something slow, and switch to another tab
5. When it finishes you should get a notification and a chime
6. Click the Earshot icon: the popup lists what it saw

**If nothing happens**, the popup's Recent list is the thing to look at. Empty
means the page never looked "finished" to it, which is a selector problem and
exactly what job 1 fixes.

This step cannot be automated. `chrome://extensions` is deliberately off limits
to browser automation, so loading an unpacked extension is always done by hand.

---

## What to send back

Anything at all from job 1 is useful, even if it looks like nothing. The most
useful single thing is the `matched` object from each run, because the selector
that appears in one and not the other is the one the extension should use.
