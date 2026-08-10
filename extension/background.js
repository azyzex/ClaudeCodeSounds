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
async function play(kind) {
  const pattern = kind === 'done' ? [0] : kind === 'blocked' ? [0, 220] : [0, 160, 320];
  const freq = kind === 'done' ? 1046 : kind === 'blocked' ? 880 : 440;
  try {
    // Offscreen documents are the only way a service worker can make sound.
    await chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['AUDIO_PLAYBACK'],
      justification: 'Play a short alert tone when Claude finishes or needs you.',
    }).catch(() => {});
    await chrome.runtime.sendMessage({ type: 'earshot-play', freq, pattern });
  } catch {
    // No sound is survivable. The notification still happens.
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
  if (s.sound) await play('done');
  return { ok: true, notified: s.notify, played: s.sound };
}

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (!msg || msg.type !== 'earshot-test') return undefined;
  runTest()
    .then(reply)
    .catch((e) => reply({ ok: false, error: String(e) }));
  return true;
});
