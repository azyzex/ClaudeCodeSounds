// Earshot - DOM probe
//
// Paste this into the browser console on claude.ai and it prints what Earshot
// needs to know. It changes nothing and sends nothing: it only looks at the
// page you already have open, and it never reads message text.
//
// Why it exists: the extension has to tell "Claude is still writing" from
// "Claude has stopped", and the only honest way to know how is to look at a
// real page rather than assume. Everything printed here is a fact about the
// current DOM.
//
// How to use it:
//   1. open a conversation on claude.ai
//   2. F12, Console tab, paste this, press Enter
//   3. ask Claude something slow, so it streams for a while
//   4. while it is still writing, run:  earshotProbe('while writing')
//   5. once it has finished, run:       earshotProbe('after finishing')
//   6. copy both outputs

(() => {
  const CANDIDATES = [
    '[aria-label*="Stop response" i]',
    '[aria-label*="Stop generating" i]',
    '[aria-label*="Stop" i]',
    'button[data-testid="stop-button"]',
    '[data-testid*="stop" i]',
    '[aria-label*="Send" i]',
    'button[data-testid="send-button"]',
    '[role="dialog"]:not([aria-hidden="true"])',
    '[role="alertdialog"]',
    '[data-testid*="limit" i]',
  ];

  /** A short, non-identifying description of an element. */
  function describe(el) {
    const attrs = {};
    for (const name of ['data-testid', 'aria-label', 'role', 'type', 'disabled']) {
      const v = el.getAttribute(name);
      if (v !== null) attrs[name] = v.slice(0, 60);
    }
    return {
      tag: el.tagName.toLowerCase(),
      // Class lists are long and generated, so only the count is useful.
      classes: (el.className || '').toString().split(/\s+/).filter(Boolean).length,
      attrs,
    };
  }

  window.earshotProbe = (label) => {
    const found = {};
    for (const sel of CANDIDATES) {
      const els = document.querySelectorAll(sel);
      if (els.length) found[sel] = [...els].slice(0, 2).map(describe);
    }

    // Any button carrying a testid, which is the most likely stable hook.
    const testids = [...document.querySelectorAll('button[data-testid]')]
      .map((b) => b.getAttribute('data-testid'))
      .filter((v, i, a) => a.indexOf(v) === i)
      .slice(0, 25);

    const out = {
      label: label || 'unlabelled',
      url: location.origin + location.pathname.replace(/\/[0-9a-f-]{16,}/gi, '/<id>'),
      matched: found,
      buttonTestIds: testids,
      dialogOpen: Boolean(document.querySelector('[role="dialog"]:not([aria-hidden="true"])')),
    };
    console.log('%c--- earshot probe: ' + out.label + ' ---', 'font-weight:bold');
    console.log(JSON.stringify(out, null, 2));
    return out;
  };

  console.log(
    '%cEarshot probe ready.',
    'font-weight:bold',
    '\nRun earshotProbe("while writing") while Claude is replying,',
    '\nthen earshotProbe("after finishing") once it has stopped.'
  );
})();
