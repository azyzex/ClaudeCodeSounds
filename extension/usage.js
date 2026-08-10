// Earshot for Web - watching the usage window.
//
// This is the reason the extension exists. It answers "when does my 5 hour
// window reset" without you having to hit the limit first, and without a single
// token being spent.
//
// HOW, AND WHY THIS IS THE CHEAP WAY
//
// claude.ai has an endpoint the page already calls for itself:
//
//     GET /api/organizations/<org>/usage
//
// It returns, among other things:
//
//     five_hour: { utilization: 93, resets_at: "2026-08-09T22:00:00+00:00" }
//     seven_day: { utilization: 35, resets_at: ... }
//
// Those numbers come from Anthropic's servers, so they are right regardless of
// which surface used the window. Reading them runs no model, so it costs
// nothing and does not touch your usage.
//
// WHAT IT DOES NOT DO
//
//   * it does not intercept anything. Wrapping fetch would have worked and
//     needed no extra permission, which is exactly what made it tempting, but
//     it would put this code in the path of every response including your
//     messages. One deliberate request is the smaller ask.
//   * it does not read conversations, titles or any other endpoint
//   * it keeps nothing but two numbers and two timestamps
//   * it sends nothing anywhere except, if you switch the bridge on, to the
//     notifier already running on your own machine

const USAGE_ALARM = 'earshot-usage';

// The reset time only moves when a window rolls over, so this can be lazy.
// Every ten minutes is far more often than the answer changes, and the request
// is smaller than a single page image.
const EVERY_MINUTES = 10;

/** A short, stable, non-reversible stand-in for the account.
 *
 * Claude Code and the browser may be signed into different accounts, and the
 * window is per account: a reset time from one is simply wrong for the other.
 * Something has to tell them apart. That something does not need to be the
 * organisation id itself, so it never leaves here in the clear.
 */
async function accountTag(org) {
  const data = new TextEncoder().encode('earshot:' + org);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(digest)].slice(0, 6)
    .map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** The organisation id, learned from a page the user already has open. */
async function findOrg() {
  const tabs = await chrome.tabs.query({ url: 'https://claude.ai/*' }).catch(() => []);
  if (!tabs.length) return null;
  const { lastOrg } = await chrome.storage.local.get({ lastOrg: null });
  if (lastOrg) return lastOrg;
  // The bootstrap endpoint names the current organisation. Asking for it is
  // cheaper and steadier than scraping a URL out of the page.
  try {
    const res = await fetch('https://claude.ai/api/organizations', { credentials: 'include' });
    if (!res.ok) return null;
    const list = await res.json();
    const org = Array.isArray(list) && list.length ? list[0].uuid : null;
    if (org) await chrome.storage.local.set({ lastOrg: org });
    return org || null;
  } catch {
    return null;
  }
}

/** Put the number on the toolbar icon.
 *
 * The whole point of the extension is not having to go and look. A badge is the
 * one place a number can live where checking it costs nothing at all, and it
 * needs no permission: an extension may always draw on its own icon.
 *
 * The percentage rather than the time left, because the percentage is what
 * decides whether to start something big, and the time is one click away.
 */
function updateBadge(five) {
  try {
    if (!five || typeof five.utilization !== 'number') {
      chrome.action.setBadgeText({ text: '' });
      return;
    }
    const pct = Math.round(five.utilization);
    chrome.action.setBadgeText({ text: `${pct}` });
    // Green until it matters, amber when the end is in sight, red when
    // starting something long is a bad idea.
    // Four steps rather than three: the jump from "fine" to "stop" was too
    // sudden to be useful while you are deciding whether to start something.
    const colour =
      pct >= 100 ? '#c0392b' :      // red, it is gone
      pct >= 90 ? '#d2691e' :       // dark orange, wrap up
      pct >= 70 ? '#e6c34a' :       // light yellow, worth knowing
      '#2f7d32';                    // green
    chrome.action.setBadgeBackgroundColor({ color: colour });
    chrome.action.setTitle({
      title: `Earshot - ${pct}% of your 5 hour window used`,
    });
  } catch {
    // A badge is a nicety. Never let it break the alerting.
  }
}

// Warn once as the window fills, so there is a chance to wrap up rather than
// being cut off mid-task. That is the failure this whole project exists to
// prevent, and until now nothing said anything on the way up.
const WARN_AT = 80;

// Held in the worker as well as in storage, because storage is asynchronous and
// the gap between reading and writing it is exactly where the duplicates got in.
let warnedRightNow = null;

async function warnIfNearLimit(five) {
  if (!five || typeof five.utilization !== 'number') return;
  const pct = Math.round(five.utilization);
  const { warnedFor } = await chrome.storage.local.get({ warnedFor: null });
  // Keyed by the window's own reset time, so it warns once per window and
  // starts fresh when a new one begins rather than staying quiet forever.
  const key = five.resets_at || 'unknown';
  if (pct < WARN_AT) {
    // Dropped as soon as usage falls back, which means the window rolled over.
    if (warnedFor) await chrome.storage.local.set({ warnedFor: null });
    warnedRightNow = null;
    return;
  }
  if (warnedFor === key) return;
  // Claimed before the notification is made, not after. Several polls can be in
  // flight at once - the alarm, the worker waking, and every time the popup is
  // opened - and each was reading "not warned yet" before any of them wrote it.
  // That is how one warning arrived five times.
  if (warnedRightNow === key) return;
  warnedRightNow = key;
  await chrome.storage.local.set({ warnedFor: key });

  const { enabled, notify } = await chrome.storage.local.get({ enabled: true, notify: true });
  if (!enabled || !notify) return;
  // A fixed id, so a repeat replaces the notification rather than stacking
  // another one beside it. Belt and braces with the guard above, because five
  // notifications is the kind of bug that must not come back.
  chrome.notifications.create('earshot-warn', {
    type: 'basic',
    iconUrl: 'icons/128x128.png',
    // Named like every other browser alert, so several sources on one screen
    // stay tellable apart.
    title: `${pct}% of your 5 hour window used - browser`,
    message: 'Worth finishing what you are on rather than starting something long.',
  });
}

function usableWindow(w) {
  if (!w || typeof w.utilization !== 'number' || typeof w.resets_at !== 'string') return null;
  return { utilization: w.utilization, resets_at: w.resets_at };
}

/** Read the window state, store it, and pass it to the bridge if enabled. */
async function pollUsage() {
  const { enabled, bridge } = await chrome.storage.local.get({ enabled: true, bridge: false });
  if (!enabled) return;

  // Only while a claude.ai tab is actually open. With the browser closed or the
  // site not in use, nothing here runs at all.
  const org = await findOrg();
  if (!org) return;

  let body;
  try {
    const res = await fetch('https://claude.ai/api/organizations/' + org + '/usage',
      { credentials: 'include' });
    if (!res.ok) return;
    body = await res.json();
  } catch {
    return;
  }

  const five = usableWindow(body.five_hour);
  const week = usableWindow(body.seven_day);
  if (!five && !week) return;

  updateBadge(five);
  await warnIfNearLimit(five);

  const account = await accountTag(org);
  await chrome.storage.local.set({
    limits: { account, five_hour: five, seven_day: week, at: Date.now() },
  });

  if (bridge) {
    try {
      chrome.runtime.sendNativeMessage('com.azyzex.earshot', {
        kind: 'limits', account, five_hour: five, seven_day: week,
      }, () => { void chrome.runtime.lastError; });
    } catch { /* bridge not installed, which is the normal case */ }
  }
}

chrome.alarms.create(USAGE_ALARM, { periodInMinutes: EVERY_MINUTES, delayInMinutes: 1 });

// Read once as soon as the worker wakes, rather than waiting out the first
// tick. Opening the popup a minute after installing and finding it empty made
// the whole thing look broken when it was only early.
pollUsage().catch(() => {});

// And on demand, so opening the popup shows something current rather than
// whatever the last tick happened to leave behind.
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (!msg || msg.type !== 'earshot-poll-now') return undefined;
  pollUsage()
    .then(() => reply({ ok: true }))
    .catch((e) => reply({ ok: false, error: String(e) }));
  return true;   // the reply is async
});
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === USAGE_ALARM) pollUsage().catch(() => {});
});
