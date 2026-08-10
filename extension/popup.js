const KEYS = ['enabled', 'sound', 'notify', 'bridge'];
const LABEL = { done: 'Finished', blocked: 'Needed you', limit: 'Hit a limit' };

function ago(at) {
  const s = Math.max(0, Math.round((Date.now() - at) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return new Date(at).toLocaleDateString();
}

/** How long until a reset, in words. */
function until(iso) {
  const ms = new Date(iso).getTime() - Date.now();
  if (!isFinite(ms)) return null;
  if (ms <= 0) return 'any moment';
  const mins = Math.round(ms / 60000);
  if (mins < 60) return 'in ' + mins + ' min';
  const hours = Math.floor(mins / 60);
  const rest = mins % 60;
  if (hours < 24) return 'in ' + hours + 'h' + (rest ? ' ' + rest + 'm' : '');
  return 'in ' + Math.round(hours / 24) + ' days';
}

/** Show the windows, which is the reason the extension exists.
 *
 * These numbers come from Anthropic's servers, so they already account for
 * every surface: this terminal, the web, a phone, another machine.
 */
function showLimits(limits) {
  const host = document.getElementById('limits');
  if (!host || !limits) return;
  const rows = [['5 hours', limits.five_hour], ['7 days', limits.seven_day]];
  host.textContent = '';
  for (const [name, w] of rows) {
    if (!w) continue;
    const row = document.createElement('div');
    row.className = 'ev';
    const what = document.createElement('span');
    what.textContent = name + '  ' + Math.round(w.utilization) + '%';
    const when = document.createElement('span');
    when.className = 'when';
    when.textContent = until(w.resets_at) || '';
    row.append(what, when);
    host.append(row);
  }
}

/** Which account these figures belong to.
 *
 * Worth showing because the window is per account. Signed into a different one
 * than you expected and the countdown is real but not yours, and without this
 * there was no way to tell.
 */
function showAccount(limits) {
  const host = document.getElementById('account');
  if (!host) return;
  host.textContent = '';
  const row = document.createElement('div');
  row.className = 'ev';
  const what = document.createElement('span');
  const when = document.createElement('span');
  when.className = 'when';
  if (limits?.account) {
    what.textContent = limits.account;
    when.textContent = limits.at ? 'read ' + ago(limits.at) : '';
  } else {
    what.className = 'dim';
    what.textContent = 'open a claude.ai tab';
  }
  row.append(what, when);
  host.append(row);
}

function render(s) {
  showLimits(s.limits);
  showAccount(s.limits);
}

// Ask for a fresh reading the moment the popup opens, then draw whatever is
// stored either way: a stale figure now beats a correct one after a wait.
chrome.runtime.sendMessage({ type: 'earshot-poll-now' }, () => {
  void chrome.runtime.lastError;
  chrome.storage.local.get(null).then(render);
});

/** Grey out everything the master switch controls. */
function applyEnabled(on) {
  const box = document.getElementById('settings');
  if (box) box.classList.toggle('off', !on);
  for (const el of document.querySelectorAll('#settings input, #settings button')) {
    el.disabled = !on;
  }
}

document.getElementById('test')?.addEventListener('click', () => {
  const out = document.getElementById('testresult');
  if (out) out.textContent = 'Playing...';
  chrome.runtime.sendMessage({ type: 'earshot-test' }, (r) => {
    if (!out) return;
    if (chrome.runtime.lastError) {
      out.textContent = 'The extension is not running. Reload it and try again.';
      return;
    }
    if (!r?.ok) {
      out.textContent = `Could not: ${r?.error || 'unknown reason'}`;
      return;
    }
    // Saying which half ran matters: silence with sound turned off is correct,
    // and silence with it turned on is a fault.
    const did = [r.played && 'sound', r.notified && 'notification'].filter(Boolean);
    out.textContent = did.length
      ? `Sent a ${did.join(' and a ')}. Seen nothing? Check Windows notification settings.`
      : 'Both sound and notification are turned off, so nothing was sent.';
  });
});

chrome.storage.local.get(null).then((s) => {
  render(s);
  applyEnabled(s.enabled !== false);
  for (const k of KEYS) {
    const el = document.getElementById(k);
    el.checked = Boolean(s[k]);
    el.addEventListener('change', () => {
      chrome.storage.local.set({ [k]: el.checked });
      if (k === 'enabled') applyEnabled(el.checked);
    });
  }
  const host = document.getElementById('recent');
  const recent = s.recent || [];
  if (recent.length) {
    host.textContent = '';
    for (const e of recent.slice(0, 8)) {
      const row = document.createElement('div');
      row.className = 'ev';
      const what = document.createElement('span');
      what.textContent = LABEL[e.kind] || e.kind;
      const when = document.createElement('span');
      when.className = 'when';
      when.textContent = ago(e.at);
      row.append(what, when);
      host.append(row);
    }
  }
});
