// The usage poller lives alongside this: it answers 'when does my window
// reset', which is the reason the extension exists.
import './usage.js';

// Earshot for Web - the part that decides what to do with an event.
//
// The content script observes and reports. This decides. Keeping those apart
// means the code with access to notifications and to the native bridge never
// runs inside the page.

const DEFAULTS = {
  enabled: true,
  notify: true,
  sound: true,
  // Off until someone asks for it, because it is the only setting that lets
  // anything reach outside the browser.
  bridge: false,
  // Matches the desktop side: short turns are not worth interrupting for.
  quietKinds: [],
  tone: 'chime',
  volume: 60,
};

const TEXT = {
  done: { title: 'Claude is done', body: 'Your reply is ready.' },
  blocked: { title: 'Claude needs you', body: 'It is waiting on you to continue.' },
  limit: { title: 'Claude hit a limit', body: 'You have run out of messages for now.' },
};

const BRIDGE = 'com.azyzex.earshot';

async function settings() {
  const stored = await chrome.storage.local.get(DEFAULTS);
  return { ...DEFAULTS, ...stored };
}

/** Play a short tone.
 *
 * Generated with an oscillator rather than shipped as an audio file: it keeps
 * the extension tiny, and means there is no bundled binary for anyone to have
 * to trust. Each kind gets its own rhythm, which carries better than pitch.
 */
/** Make sure the document that can make a sound exists.
 *
 * A service worker cannot play audio, so Chrome wants an offscreen document.
 * Creating one twice is an error rather than a no-op, and asking whether one
 * exists is racy on its own, so both are handled.
 */
async function ensureOffscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  try {
    await chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['AUDIO_PLAYBACK'],
      justification: 'Play a short alert tone when Claude finishes or needs you.',
    });
  } catch (e) {
    // Two alerts at once can both find no document and both try to make one.
    // The loser of that race is fine: the document it wanted now exists.
    if (!String(e).includes('single offscreen')) throw e;
  }
}

/** Play a short tone. Returns true, or a reason it did not.
 *
 * Generated with an oscillator rather than shipped as an audio file: it keeps
 * the extension tiny, and means there is no bundled binary for anyone to have
 * to trust. Each kind gets its own rhythm, which carries better than pitch.
 *
 * It reports failure rather than swallowing it. Swallowing it is exactly how a
 * missing permission went unnoticed: notifications appeared, no sound ever
 * played, and nothing anywhere said why.
 */
/** The tones on offer.
 *
 * Each is a wave shape and a base pitch. The rhythm still comes from the kind
 * of alert, so a finish and a question stay tellable apart whichever tone is
 * chosen.
 */
const TONES = {
  chime: { wave: 'sine', base: 1046 },
  soft: { wave: 'sine', base: 660 },
  marimba: { wave: 'triangle', base: 880 },
  blip: { wave: 'square', base: 740 },
  deep: { wave: 'triangle', base: 440 },
};

async function play(kind) {
  const s = await settings();
  const tone = TONES[s.tone] || TONES.chime;
  const pattern = kind === 'done' ? [0] : kind === 'blocked' ? [0, 220] : [0, 160, 320];
  // Pitch shifts with the kind, from the chosen tone's base rather than from a
  // fixed number, so picking a tone changes all of them together.
  const freq = kind === 'done' ? tone.base : kind === 'blocked' ? tone.base * 0.84 : tone.base * 0.42;
  try {
    await ensureOffscreen();
    await chrome.runtime.sendMessage({
      type: 'earshot-play',
      freq,
      pattern,
      wave: tone.wave,
      volume: s.volume,
    });
    return true;
  } catch (e) {
    return String(e && e.message ? e.message : e);
  }
}

/** Hand the event to the local bridge, if the user turned that on.
 *
 * Native messaging rather than a local HTTP port: no listener, nothing else on
 * the machine can reach it, and only extension IDs allowlisted in the host's
 * manifest can start it at all.
 */
function toBridge(payload) {
  try {
    chrome.runtime.sendNativeMessage(BRIDGE, payload, () => {
      // Reading lastError marks it handled. A missing bridge is the normal
      // case for anyone who only installed the extension, not an error.
      void chrome.runtime.lastError;
    });
  } catch {
    /* not installed */
  }
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || msg.type !== 'earshot-event') return;
  // Only from a content script on the site this extension is scoped to.
  if (!sender.tab || !sender.url || !sender.url.startsWith('https://claude.ai/')) return;

  const kind = ['done', 'blocked', 'limit'].includes(msg.kind) ? msg.kind : null;
  if (!kind) return;

  settings().then(async (s) => {
    if (!s.enabled || s.quietKinds.includes(kind)) return;

    // Nothing to say if you are already looking at the tab it happened in.
    if (kind === 'done') {
      const active = await chrome.tabs
        .query({ active: true, lastFocusedWindow: true })
        .catch(() => []);
      if (active[0] && active[0].id === sender.tab.id) return;
    }

    const t = TEXT[kind];
    if (s.notify) {
      chrome.notifications.create(
        '',
        {
          type: 'basic',
          iconUrl: 'icons/128x128.png',
          title: t.title,
          message: t.body,
          silent: s.sound,        // the tone is ours, so do not double up
        },
        (id) => {
          if (id) tabForNotification.set(id, sender.tab.id);
        }
      );
    }
    if (s.sound) play(kind);
    if (s.bridge) toBridge({ source: 'web', kind, at: msg.at });

    // A tiny rolling record, for the popup to show. Events only: no message
    // text ever enters storage.
    const { recent = [] } = await chrome.storage.local.get({ recent: [] });
    recent.unshift({ kind, at: msg.at });
    await chrome.storage.local.set({ recent: recent.slice(0, 20) });
  });
});

chrome.runtime.onInstalled.addListener(async () => {
  await chrome.storage.local.get(DEFAULTS).then((s) => chrome.storage.local.set(s));
  await injectIntoOpenTabs();
});

/** Put the watcher into claude.ai tabs that were already open.
 *
 * A content script is only placed in pages loaded after the extension is, so
 * installing it while a conversation sits open meant nothing was watching that
 * conversation and the first thing anyone tried appeared to do nothing at all.
 */
async function injectIntoOpenTabs() {
  try {
    const tabs = await chrome.tabs.query({ url: 'https://claude.ai/*' });
    for (const tab of tabs) {
      chrome.scripting
        .executeScript({ target: { tabId: tab.id }, files: ['content.js'] })
        .catch(() => {
          // A tab mid-navigation, or one Chrome will not script. Not worth
          // saying anything about: the next page load covers it.
        });
    }
  } catch {
    /* nothing to do */
  }
}

// Clicking the notification should take you to the conversation it was about,
// which is the only thing anyone wants to do next.
const tabForNotification = new Map();

chrome.notifications.onClicked.addListener((id) => {
  const tabId = tabForNotification.get(id);
  chrome.notifications.clear(id);
  if (tabId === undefined) return;
  // update() on a known id needs no extra permission; reading a tab's url
  // would, and is not needed for this.
  chrome.tabs.update(tabId, { active: true }).catch(() => {});
  chrome.tabs.get(tabId).then((t) => chrome.windows.update(t.windowId, { focused: true })).catch(() => {});
});

/** Play one alert now, so the setup can be proven without waiting for Claude. */
async function runTest() {
  const s = await settings();
  const t = TEXT.done;
  if (s.notify) {
    chrome.notifications.create('', {
      type: 'basic',
      iconUrl: 'icons/128x128.png',
      title: 'Earshot is working',
      message: 'This is what an alert looks like.',
      silent: s.sound,
    });
  }
  let played = false;
  let soundError = null;
  if (s.sound) {
    const r = await play('done');
    if (r === true) played = true;
    else soundError = r;
  }
  return { ok: true, notified: s.notify, played, soundError, wantedSound: s.sound };
}

/** Ask the desktop app whether it is there.
 *
 *
 * The old switch only wrote a preference: it never checked anything, so turning
 * it on looked identical whether the app was set up or not. This actually
 * speaks to it and reports what came back.
 */
async function pingBridge() {
  // nativeMessaging is optional on purpose: it is the only permission that
  // lets anything reach outside the browser, so it is not held until asked
  // for. Until it is granted the API does not exist at all, which is what
  // "sendNativeMessage is not a function" was telling us.
  let granted = false;
  try {
    granted = await chrome.permissions.contains({ permissions: ['nativeMessaging'] });
    if (!granted) {
      granted = await chrome.permissions.request({ permissions: ['nativeMessaging'] });
    }
  } catch (e) {
    return { ok: false, reason: 'failed', detail: String(e) };
  }
  if (!granted) {
    return {
      ok: false,
      reason: 'denied',
      detail: 'Permission to talk to the desktop app was not given.',
    };
  }

  return new Promise((resolve) => {
    try {
      chrome.runtime.sendNativeMessage(BRIDGE, { kind: 'ping' }, (reply) => {
        const err = chrome.runtime.lastError;
        if (err) {
          const text = err.message || String(err);
          // The two failures worth telling apart: not set up at all, versus set
          // up and refusing to run.
          resolve({
            ok: false,
            reason: /not found|no such native|not installed/i.test(text)
              ? 'notfound'
              : 'failed',
            detail: text,
          });
          return;
        }
        resolve({ ok: true, app: reply?.app, notifier: reply?.notifier });
      });
    } catch (e) {
      resolve({ ok: false, reason: 'failed', detail: String(e) });
    }
  });
}

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type === 'earshot-preview') {
    play('done').then((r) => reply({ ok: r === true, error: r === true ? null : r }));
    return true;
  }
  if (msg?.type === 'earshot-connect') {
    pingBridge().then(async (r) => {
      // Only remembered as on once it has actually answered.
      await chrome.storage.local.set({ bridge: Boolean(r.ok) });
      reply(r);
    });
    return true;
  }
  if (!msg || msg.type !== 'earshot-test') return undefined;
  runTest()
    .then(reply)
    .catch((e) => reply({ ok: false, error: String(e) }));
  return true;
});
