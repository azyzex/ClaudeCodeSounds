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
    const colour = pct >= 90 ? '#c0392b' : pct >= 70 ? '#c77d0a' : '#2f7d32';
    chrome.action.setBadgeBackgroundColor({ color: colour });
    chrome.action.setTitle({
      title: `Earshot - ${pct}% of your 5 hour window used`,
    });
  } catch {
    // A badge is a nicety. Never let it break the alerting.
  }
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
