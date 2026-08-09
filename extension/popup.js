const KEYS = ['enabled', 'sound', 'notify', 'bridge'];
const LABEL = { done: 'Finished', blocked: 'Needed you', limit: 'Hit a limit' };

function ago(at) {
  const s = Math.max(0, Math.round((Date.now() - at) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return new Date(at).toLocaleDateString();
}

chrome.storage.local.get(null).then((s) => {
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
