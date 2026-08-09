// Earshot for Web - the part that runs on claude.ai
//
// It answers one question: has Claude stopped working, and did it stop because
// it finished or because it wants something?
//
// Deliberate limits, which are the whole reason this is safe to install:
//
//   * it reads the page's own visible state, nothing more
//   * it never reads message text, and never stores any
//   * it makes no network requests of its own
//   * it cannot write to your disk; it hands events to the background worker,
//     which decides what to do with them
//
// The DOM of a web app is not an API and will change. Everything here is
// written to fail quietly and stay silent rather than guess, because a wrong
// alert is worse than a missing one.

(() => {
  'use strict';

  const SETTLE_MS = 900;      // quiet period before calling a turn finished
  const MIN_RUN_MS = 4000;    // ignore turns too short to have walked away from

  let busy = false;
  let busySince = 0;
  let settleTimer = null;
  let lastFiredAt = 0;

  /** Is Claude currently generating?
   *
   * Detected from controls rather than text: while a response streams there is
   * a stop button, and when it ends there is not. Several selectors are tried
   * because only one of them needs to survive any given redesign.
   */
  function isGenerating() {
    const stop =
      document.querySelector('[aria-label*="Stop response" i]') ||
      document.querySelector('[aria-label*="Stop generating" i]') ||
      document.querySelector('button[data-testid="stop-button"]');
    return Boolean(stop);
  }

  /** Is the page asking for something, rather than just having finished?
   *
   * Only structural signals count. Matching on prose would break in every
   * language but English and would guess wrong the rest of the time.
   */
  function needsAttention() {
    const dialog = document.querySelector('[role="dialog"]:not([aria-hidden="true"])');
    if (dialog) return true;
    const alert = document.querySelector('[role="alertdialog"]');
    return Boolean(alert);
  }

  /** Has the page said you are out of quota?
   *
   * This one has to look at text, because there is no structural marker for it.
   * Kept to a narrow phrase, checked against a limited region, and only ever
   * used to decide which sound to play. The text itself is never stored or
   * sent.
   */
  function looksRateLimited() {
    const region = document.querySelector('main') || document.body;
    if (!region) return false;
    const text = (region.innerText || '').slice(-2000).toLowerCase();
    return (
      text.includes('message limit') ||
      text.includes('usage limit') ||
      (text.includes('limit reached') && text.includes('reset'))
    );
  }

  function send(kind) {
    const now = Date.now();
    // One alert per turn. A DOM that flickers should not become a stutter.
    if (now - lastFiredAt < 3000) return;
    lastFiredAt = now;
    try {
      chrome.runtime.sendMessage({ type: 'earshot-event', kind, at: now });
    } catch {
      // The worker may be asleep or the extension reloading. An alert that
      // cannot be delivered is dropped, never retried into a pile.
    }
  }

  function check() {
    const generating = isGenerating();

    if (generating && !busy) {
      busy = true;
      busySince = Date.now();
      clearTimeout(settleTimer);
      return;
    }

    if (!generating && busy) {
      // Wait out a settle period before declaring it over: the controls flicker
      // between messages in a single turn.
      clearTimeout(settleTimer);
      settleTimer = setTimeout(() => {
        if (isGenerating()) return;      // it started again, so it never stopped
        const ran = Date.now() - busySince;
        busy = false;
        if (ran < MIN_RUN_MS) return;    // too short to have walked away from
        if (looksRateLimited()) send('limit');
        else if (needsAttention()) send('blocked');
        else send('done');
      }, SETTLE_MS);
    }
  }

  // A throttled observer rather than a polling loop: the page mutates
  // constantly while streaming, and this must not become the reason a laptop
  // fan spins up.
  let queued = false;
  const observer = new MutationObserver(() => {
    if (queued) return;
    queued = true;
    setTimeout(() => {
      queued = false;
      try {
        check();
      } catch {
        // Never let a page change break the page.
      }
    }, 400);
  });

  observer.observe(document.body, { childList: true, subtree: true });
  check();
})();
