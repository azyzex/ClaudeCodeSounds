// UI for the Claude Code sound alerts.
//
// The Rust side owns reading and writing ~/.claude/claude-notify.conf, so this
// file never parses the config format itself. Keeping one implementation of
// that is the whole reason the notifier scripts are generated from a single
// source, and a third copy here would defeat it.

const invoke = window.__TAURI__.core.invoke;

const EVENTS = [
  { kind: 'done',    key: 'DONE',    name: 'Finished',     when: 'Claude finished the turn.' },
  { kind: 'blocked', key: 'BLOCKED', name: 'Needs you',    when: 'A permission prompt, an idle prompt, or a subagent waiting on input.' },
  { kind: 'limit',   key: 'LIMIT',   name: 'Usage limit',  when: 'You hit your rate limit and the turn ended early.' },
  { kind: 'error',   key: 'ERROR',   name: 'Failed',       when: 'The turn died on some other API error.' },
];

const PATTERNS = [
  ['1', 'once'],
  ['2', 'twice'],
  ['3x140', 'three times'],
  ['4x110', 'four times'],
];

const SWITCHES = ['SUPPRESS_WHEN_FOCUSED', 'PROJECT_PITCH', 'SPEAK', 'TOAST_ON_DONE'];
// Handled separately: it writes a startup entry as well as the config.
const LOGIN_SWITCH = 'LAUNCH_AT_LOGIN';
const TEXTS = ['QUIET_HOURS'];
const NUMBERS = ['MIN_SECONDS', 'ESCALATE_AFTER'];

let state = null;
let saveTimer = null;

const $ = (id) => document.getElementById(id);

function status(text, kind) {
  const el = $('status');
  el.textContent = text;
  el.className = 'status' + (kind ? ' ' + kind : '');
}

/** Collect changed keys and write them. Debounced, because dragging a volume
 *  slider would otherwise write the file on every pixel. */
function scheduleSave(changes) {
  Object.assign(pendingChanges, changes);
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flushSave, 250);
}
let pendingChanges = {};

async function flushSave() {
  const changes = pendingChanges;
  pendingChanges = {};
  if (Object.keys(changes).length === 0) return;
  try {
    await invoke('save_settings', { changes });
    Object.assign(state.settings, changes);
    status('Saved', 'ok');
  } catch (e) {
    status(String(e), 'err');
  }
}

async function preview(kind, button) {
  // Flush first, so what you hear reflects the control you just moved rather
  // than the settings as they were 250ms ago.
  clearTimeout(saveTimer);
  await flushSave();
  button.disabled = true;
  try {
    const line = await invoke('preview', { kind });
    // The notifier reports what it decided. Surfacing a fallback is more useful
    // than silently playing a beep and leaving you to wonder.
    if (/player=(bell|beep)/.test(line)) {
      status('Played a fallback tone: no sound file could be played', 'err');
    } else {
      status('Played ' + kind, 'ok');
    }
  } catch (e) {
    status(String(e), 'err');
  } finally {
    button.disabled = false;
    renderLog();
  }
}

function renderEvents() {
  const host = $('events');
  host.textContent = '';

  for (const ev of EVENTS) {
    const enabled = state.settings[ev.key + '_ENABLED'] !== '0';

    const row = document.createElement('div');
    row.className = 'event' + (enabled ? '' : ' off');

    const name = document.createElement('div');
    name.className = 'event-name';
    name.textContent = ev.name;

    const toggle = document.createElement('input');
    toggle.type = 'checkbox';
    toggle.checked = enabled;
    toggle.setAttribute('aria-label', 'Enable the ' + ev.name + ' alert');
    toggle.addEventListener('change', () => {
      row.classList.toggle('off', !toggle.checked);
      scheduleSave({ [ev.key + '_ENABLED']: toggle.checked ? '1' : '0' });
    });

    const when = document.createElement('div');
    when.className = 'event-when';
    when.textContent = ev.when;

    const controls = document.createElement('div');
    controls.className = 'event-controls';

    controls.append(
      soundControl(ev),
      volumeControl(ev),
      patternControl(ev),
      playButton(ev),
    );

    row.append(name, toggle, when, controls);
    host.append(row);
  }
}

function labelled(text, control) {
  const wrap = document.createElement('label');
  wrap.className = 'control';
  wrap.append(document.createTextNode(text), control);
  return wrap;
}

function soundControl(ev) {
  const select = document.createElement('select');
  const current = state.settings[ev.key + '_SOUND'] || '';

  const auto = new Option('Automatic', '');
  select.append(auto);
  for (const name of state.sounds) {
    select.append(new Option(name, name));
  }
  // A custom path set by hand is not in the pack, so show it rather than
  // silently resetting someone's choice to Automatic.
  if (current && !state.sounds.includes(current)) {
    select.append(new Option(current, current));
  }
  select.value = current;

  select.addEventListener('change', () => {
    scheduleSave({ [ev.key + '_SOUND']: select.value });
  });
  return labelled('Sound', select);
}

function volumeControl(ev) {
  const slider = document.createElement('input');
  slider.type = 'range';
  slider.min = '0';
  slider.max = '100';
  slider.step = '5';
  slider.value = state.settings[ev.key + '_VOLUME'] || '100';
  slider.setAttribute('aria-label', ev.name + ' volume');

  const out = document.createElement('span');
  out.textContent = slider.value + '%';

  slider.addEventListener('input', () => {
    out.textContent = slider.value + '%';
    scheduleSave({ [ev.key + '_VOLUME']: slider.value });
  });

  const wrap = labelled('Volume', slider);
  wrap.append(out);
  return wrap;
}

function patternControl(ev) {
  const select = document.createElement('select');
  const current = state.settings[ev.key + '_PATTERN'] || '1';
  for (const [value, label] of PATTERNS) {
    select.append(new Option(label, value));
  }
  if (!PATTERNS.some(([v]) => v === current)) {
    select.append(new Option(current, current));
  }
  select.value = current;
  select.addEventListener('change', () => {
    scheduleSave({ [ev.key + '_PATTERN']: select.value });
  });
  return labelled('Play', select);
}

function playButton(ev) {
  const button = document.createElement('button');
  button.className = 'play';
  button.type = 'button';
  button.textContent = 'Play';
  button.addEventListener('click', () => preview(ev.kind, button));
  return button;
}

// Bound once. Changing the pack reloads the whole state, so binding here would
// stack a fresh listener on every reload.
let generalBound = false;

function bindGeneral() {
  if (generalBound) return;
  generalBound = true;

  for (const id of SWITCHES) {
    const el = $(id);
    el.addEventListener('change', () => scheduleSave({ [id]: el.checked ? '1' : '0' }));
  }

  // Not a plain config write: this also has to add or remove the platform's
  // own startup entry, so it goes through a command.
  $('LAUNCH_AT_LOGIN').addEventListener('change', async (e) => {
    try {
      await invoke('set_launch_at_login', { enable: e.target.checked });
      status(e.target.checked ? 'Will start with the machine' : 'Will not start automatically', 'ok');
    } catch (err) {
      status(String(err), 'err');
      e.target.checked = !e.target.checked;
    }
  });
  for (const id of NUMBERS.concat(TEXTS)) {
    const el = $(id);
    el.addEventListener('change', () => scheduleSave({ [id]: el.value.trim() }));
  }

  for (const b of document.querySelectorAll('.quiet-buttons button')) {
    b.addEventListener('click', async () => {
      try {
        status(await invoke('quiet_for', { minutes: Number(b.dataset.minutes) }), 'ok');
        await load();
      } catch (e) {
        status(String(e), 'err');
      }
    });
  }

  $('SOUND_PACK').addEventListener('change', async (e) => {
    scheduleSave({ SOUND_PACK: e.target.value });
    clearTimeout(saveTimer);
    await flushSave();
    await load();          // the sound lists belong to the pack, so redraw them
  });
}

function fillQuietNow() {
  const el = $('quietstate');
  if (!state.muted_until) {
    el.textContent = 'Not muted.';
    el.className = 'hint';
    return;
  }
  const mins = Math.max(1, Math.round((state.muted_until - Date.now() / 1000) / 60));
  el.textContent = 'Muted for another ' + mins + ' minute' + (mins === 1 ? '' : 's') + '.';
  el.className = 'hint on';
}

function fillGeneral() {
  for (const id of SWITCHES) {
    $(id).checked = state.settings[id] === '1';
  }
  $(LOGIN_SWITCH).checked = state.settings[LOGIN_SWITCH] === '1';
  for (const id of NUMBERS.concat(TEXTS)) {
    $(id).value = state.settings[id] || '';
  }

  const packs = $('SOUND_PACK');
  packs.textContent = '';
  for (const p of state.packs.length ? state.packs : ['default']) {
    packs.append(new Option(p, p));
  }
  packs.value = state.settings.SOUND_PACK || 'default';
}

function renderInstallState() {
  const setup = $('setup');
  const installed = state.installed >= 5;
  setup.classList.toggle('hidden', installed);

  if (!state.claude_dir_exists) {
    status('No ~/.claude found. Run Claude Code once first.', 'err');
  } else if (installed) {
    status('Alerts are installed');
  } else if (state.installed > 0) {
    status('Partly installed (' + state.installed + ' of 5 hooks)', 'err');
  } else {
    status('Alerts are not installed', 'err');
  }
}

async function setHooks(install) {
  status(install ? 'Installing…' : 'Removing…');
  try {
    await invoke('set_hooks', { install });
    await load();
    status(install
      ? 'Installed. Restart Claude Code to pick them up.'
      : 'Removed. Restart Claude Code.', 'ok');
  } catch (e) {
    status(String(e), 'err');
  }
}

function whenText(epochSeconds) {
  const secs = Math.max(0, Math.floor(Date.now() / 1000) - epochSeconds);
  if (secs < 60) return 'just now';
  if (secs < 3600) return Math.floor(secs / 60) + 'm ago';
  if (secs < 86400) return Math.floor(secs / 3600) + 'h ago';
  return new Date(epochSeconds * 1000).toLocaleDateString();
}

const OUTCOME_TEXT = {
  played: 'played',
  muted: 'muted',
  focused: 'skipped, terminal was focused',
  debounced: 'skipped, too soon after the last one',
  'too-quick': 'skipped, the turn was too short',
  'quiet-hours': 'skipped, quiet hours',
};

async function renderLog() {
  const host = $('log');
  let entries = [];
  try {
    entries = await invoke('recent_log', { limit: 12 });
  } catch {
    return;                       // the log is a nicety, never a failure
  }
  host.textContent = '';
  if (entries.length === 0) {
    const p = document.createElement('p');
    p.className = 'muted';
    p.textContent = 'Nothing yet. Alerts appear here once Claude Code fires one.';
    host.append(p);
    return;
  }
  const names = Object.fromEntries(EVENTS.map((e) => [e.kind, e.name]));
  for (const e of entries) {
    const row = document.createElement('div');
    row.className = 'log-row' + (e.outcome === 'played' ? ' played' : '');

    const when = document.createElement('span');
    when.className = 'log-when';
    when.textContent = whenText(e.at);

    const kind = document.createElement('span');
    kind.className = 'log-kind';
    kind.textContent = names[e.kind] || e.kind;

    const outcome = document.createElement('span');
    outcome.className = 'log-outcome';
    const base = OUTCOME_TEXT[e.outcome] || e.outcome;
    outcome.textContent = e.outcome === 'played' && e.sound ? base + ' ' + e.sound : base;

    row.append(when, kind, outcome);
    host.append(row);
  }
}

async function load() {
  state = await invoke('load_state');
  $('confpath').textContent = state.conf_path;
  renderInstallState();
  renderEvents();
  bindGeneral();
  fillGeneral();
  fillQuietNow();
  await renderLog();
}

async function main() {
  $('install').addEventListener('click', () => setHooks(true));
  $('uninstall').addEventListener('click', () => setHooks(false));
  try {
    await load();
  } catch (e) {
    status(String(e), 'err');
  }
}

main();
