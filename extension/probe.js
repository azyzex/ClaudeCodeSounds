// Earshot - DOM probe
//
// Paste into the browser console on claude.ai, then run:
//
//     earshotRun()
//
// It tells you what to do and prints one report at the end. Copy that.
//
// It reads element tags and a fixed list of attributes. It never reads message
// text, and it sends nothing anywhere.
//
// WHY THIS EXISTS
// The extension has to tell "Claude is still writing" from "Claude has
// stopped". Every selector in it is currently a guess about a page nobody
// involved has inspected. This reports the facts instead.
//
// Two things it captures that a pair of snapshots cannot:
//
//   * the TRANSITION. The extension hooks the moment a turn ends, not the
//     state either side of it, so the change log is the real answer.
//   * the composer. "A send button exists" does not separate "Claude
//     finished" from "you are still typing": send is usually disabled when
//     the box is empty. React often sets that as a property without
//     reflecting it to an attribute, so both are recorded.
//
// The single-command runner is `earshotRun()`. The pieces are also available
// on their own if you want them: earshotProbe(label), earshotWatch(),
// earshotWatchStop().

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
    '[role="progressbar"]',
    '[aria-busy="true"]',
    '[aria-live]',
  ];

  const WATCHED_ATTRS = [
    'data-testid', 'aria-label', 'role', 'type',
    'disabled', 'aria-disabled', 'aria-busy', 'aria-live', 'data-state',
  ];

  function describe(el) {
    const attrs = {};
    for (const name of WATCHED_ATTRS) {
      const v = el.getAttribute(name);
      if (v !== null) attrs[name] = v.slice(0, 60);
    }
    return {
      tag: el.tagName.toLowerCase(),
      classes: (el.className || '').toString().split(/\s+/).filter(Boolean).length,
      // The live property, not just the attribute: React frequently sets one
      // without the other, and an attribute-only check would miss it.
      disabledProp: 'disabled' in el ? Boolean(el.disabled) : null,
      attrs,
    };
  }

  function snapshot(label) {
    const found = {};
    for (const sel of CANDIDATES) {
      const els = document.querySelectorAll(sel);
      if (els.length) found[sel] = [...els].slice(0, 2).map(describe);
    }
    const buttonStates = [...document.querySelectorAll('button')]
      .filter((b) => b.getAttribute('data-testid') || b.getAttribute('aria-label'))
      .slice(0, 20)
      .map((b) => ({
        testid: b.getAttribute('data-testid'),
        label: (b.getAttribute('aria-label') || '').slice(0, 40),
        disabled: Boolean(b.disabled),
      }));
    return {
      label,
      matched: found,
      buttonStates,
      buttonTestIds: [...document.querySelectorAll('button[data-testid]')]
        .map((b) => b.getAttribute('data-testid'))
        .filter((v, i, a) => a.indexOf(v) === i)
        .slice(0, 25),
      dialogOpen: Boolean(document.querySelector('[role="dialog"]:not([aria-hidden="true"])')),
    };
  }

  window.earshotProbe = (label) => {
    const out = snapshot(label || 'unlabelled');
    console.log(JSON.stringify(out, null, 2));
    return out;
  };

  // ---- transition capture -------------------------------------------------

  let observer = null;
  let log = [];
  let t0 = 0;

  window.earshotWatch = () => {
    log = [];
    t0 = Date.now();
    observer = new MutationObserver((muts) => {
      for (const m of muts) {
        const el = m.target.nodeType === 1 ? m.target : m.target.parentElement;
        if (!el || !el.tagName) continue;
        const testid = el.getAttribute?.('data-testid');
        const label = el.getAttribute?.('aria-label');
        // Only nodes carrying an identifying hook. Everything else is
        // generated-class churn and would drown the signal.
        if (!testid && !label) continue;
        log.push({
          t: Date.now() - t0,
          type: m.type,
          attr: m.attributeName || null,
          tag: el.tagName.toLowerCase(),
          testid: testid || null,
          label: label ? label.slice(0, 40) : null,
          nowDisabled: 'disabled' in el ? Boolean(el.disabled) : null,
        });
      }
    });
    observer.observe(document.body, {
      subtree: true, attributes: true, childList: true,
      attributeFilter: WATCHED_ATTRS,
    });
  };

  function compactLog() {
    return log.filter((e, i) => {
      const p = log[i - 1];
      return !p || p.testid !== e.testid || p.attr !== e.attr ||
             p.nowDisabled !== e.nowDisabled || p.type !== e.type;
    });
  }

  window.earshotWatchStop = () => {
    if (observer) observer.disconnect();
    observer = null;
    const compact = compactLog();
    console.log(JSON.stringify(compact, null, 2));
    return compact;
  };

  // ---- the one command ----------------------------------------------------

  const say = (msg, style) =>
    console.log('%c' + msg, style || 'font-weight:bold;font-size:13px');

  /** Snapshot idle, watch a whole turn, and print one report.
   *
   * Ends itself once the page has been quiet for a while, so there is nothing
   * to remember to stop.
   */
  window.earshotRun = async () => {
    const report = { url: location.origin + location.pathname.replace(/\/[0-9a-f-]{16,}/gi, '/<id>'), states: [] };

    report.states.push(snapshot('idle, before typing'));
    say('Earshot: send Claude something slow now.');
    say('Try: write a 500 word essay about the sea', 'color:#888');
    say('Then leave this alone. It prints a report when the reply finishes.', 'color:#888');

    earshotWatch();

    // Wait for the page to start changing, which is the turn beginning.
    const started = await new Promise((resolve) => {
      const began = Date.now();
      const timer = setInterval(() => {
        if (log.length > 3) { clearInterval(timer); resolve(true); }
        else if (Date.now() - began > 180000) { clearInterval(timer); resolve(false); }
      }, 500);
    });

    if (!started) {
      earshotWatchStop();
      say('Nothing happened for three minutes. Run earshotRun() again when ready.', 'color:#c00');
      return null;
    }

    say('Earshot: saw it start. Waiting for it to finish...', 'color:#888');
    let midCaptured = false;
    setTimeout(() => { report.states.push(snapshot('while writing')); midCaptured = true; }, 2500);

    // Finished means nothing identifying has changed for a good few seconds.
    await new Promise((resolve) => {
      let lastSeen = log.length;
      let quietSince = Date.now();
      const timer = setInterval(() => {
        if (log.length !== lastSeen) { lastSeen = log.length; quietSince = Date.now(); }
        else if (Date.now() - quietSince > 6000 && midCaptured) { clearInterval(timer); resolve(); }
      }, 500);
    });

    report.states.push(snapshot('after finishing'));
    report.transitions = compactLog();
    if (observer) { observer.disconnect(); observer = null; }

    say('--- Earshot report: copy everything below ---');
    console.log(JSON.stringify(report, null, 2));
    say('--- end of report ---');
    return report;
  };

  say('Earshot probe ready. Type:  earshotRun()');
})();
