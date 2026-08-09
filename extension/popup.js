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

chrome.storage.local.get(null).then((s) => {
  showLimits(s.limits);
  for (const k of KEYS) {
    const el = document.getElementById(k);
    el.checked = Boolean(s[k]);
    el.addEventListener('change', () => chrome.storage.local.set({ [k]: el.checked }));
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
