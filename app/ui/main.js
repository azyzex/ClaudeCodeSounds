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
const TEXTS = ['QUIET_HOURS', 'NTFY_TOPIC'];
const NUMBERS = ['MIN_SECONDS', 'ESCALATE_AFTER'];

let state = null;
let saveTimer = null;

/** Run something with the control disabled, so a second click cannot start it.
 *
 * Every button that does real work goes through here. Double clicking a save or
 * a push is not something to leave to how fast someone's mouse is.
 */
async function busy(el, work) {
  if (!el || el.dataset.busy === '1') return;
  el.dataset.busy = '1';
  const wasDisabled = el.disabled;
  el.disabled = true;
  el.classList.add('busy');
  try {
    await work();
  } catch (e) {
    status(String(e), 'err');
  } finally {
    el.dataset.busy = '';
    el.disabled = wasDisabled;
    el.classList.remove('busy');
  }
}

function note(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

/** Grey out everything the master switch controls. */
function applyMaster(on) {
  for (const card of document.querySelectorAll('main .card')) {
    if (card.classList.contains('master-card')) continue;
    card.classList.toggle('off', !on);
  }
  // Everything below going inert with nothing said about why is how a dead
  // button gets mistaken for a broken one. It is stated instead.
  note(
    'master-note',
    on
      ? 'Turns everything off without removing anything. Your settings, sounds and phone topic are all kept.'
      : 'Alerts are off, so everything below is inactive until you switch this back on. Nothing has been removed.'
  );
}

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
  } catch (e) {
    // The log is a nicety rather than a failure, so this does not interrupt
    // anything. It does say so, though: returning quietly left whatever was
    // already on screen, so a stale list looked like a current one.
    host.textContent = '';
    const p = document.createElement('p');
    p.className = 'muted';
    p.textContent = `Could not read the log: ${String(e)}`;
    host.append(p);
    return;
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
  showBridge();
  // The build number belongs in About, so a bug report can name it.
  const ver = document.getElementById('about-version');
  if (ver && state.version) ver.textContent = `Version ${state.version}`;
  renderInstallState();
  // Set here rather than while wiring: wiring runs before the first load, so
  // reading state there threw and silently killed every listener registered
  // after it. That is what left the phone buttons dead.
  const masterBox = document.getElementById('master');
  if (masterBox) {
    masterBox.checked = (state?.installed ?? 0) > 0;
    applyMaster(masterBox.checked);
  }
  renderEvents();
  bindGeneral();
  fillGeneral();
  fillQuietNow();
  await renderLog();
}

async function main() {
  $('install').addEventListener('click', () => setHooks(true));
  const confirmRemove = document.getElementById('confirm-remove');
  $('uninstall').addEventListener('click', () => confirmRemove?.showModal());
  document.getElementById('confirm-remove-no')?.addEventListener('click', () =>
    confirmRemove?.close()
  );
  document.getElementById('confirm-remove-yes')?.addEventListener('click', () => {
    confirmRemove?.close();
    setHooks(false);
  });

  // The master switch. Turning everything off without removing anything is what
  // most people actually want when they reach for the red button, so it sits
  // above it and says so.
  const master = document.getElementById('master');
  if (master) {
    const confirmOff = document.getElementById('confirm-off');
    master.addEventListener('change', () => {
      if (!master.checked) {
        // Turning everything off is worth a question. Turning it back on is
        // not, so only one direction asks.
        master.checked = true;
        confirmOff?.showModal();
        return;
      }
      busy(master, async () => {
        await setHooks(true);
        applyMaster(true);
      });
    });
    document.getElementById('confirm-off-no')?.addEventListener('click', () => {
      confirmOff?.close();
      master.checked = true;
      applyMaster(true);
    });
    document.getElementById('confirm-off-yes')?.addEventListener('click', () => {
      confirmOff?.close();
      master.checked = false;
      busy(master, async () => {
        await setHooks(false);
        applyMaster(false);
      });
    });
  }

  document.getElementById('ntfy-suggest')?.addEventListener('click', (e) =>
    busy(e.target, async () => {
      const topic = await invoke('suggest_topic');
      const field = document.getElementById('NTFY_TOPIC');
      if (!field) return;
      field.value = topic;
      // Saved straight away: a generated topic sitting unsaved in a box is the
      // easiest thing in the world to lose by closing the window.
      await invoke('save_settings', { changes: { NTFY_TOPIC: topic } });
      state.settings.NTFY_TOPIC = topic;
      note('ntfy-result', 'Topic saved. Subscribe to it in the ntfy app on your phone.');
    })
  );

  document.getElementById('ntfy-subscribe')?.addEventListener('click', (e) =>
    busy(e.target, async () => {
      note('ntfy-result', 'Opening...');
      try {
        note('ntfy-result', await invoke('open_ntfy'));
      } catch (err) {
        note('ntfy-result', String(err));
      }
    })
  );

  document.getElementById('ntfy-test')?.addEventListener('click', (e) =>
    busy(e.target, async () => {
      note('ntfy-result', 'Sending...');
      try {
        note('ntfy-result', await invoke('test_push'));
      } catch (err) {
        note('ntfy-result', String(err));
      }
    })
  );
  try {
    await load();
  } catch (e) {
    status(String(e), 'err');
  }
}

main();

// ---------------------------------------------------------------- usage ----
// The figures are already on disk, put there by the Claude Code status line and
// by any other surface that reported in. So "check usage" re-reads a file. It
// asks nobody anything, which is exactly why it cannot consume the limit it is
// reporting on.

/** "in 2h 14m", or "any moment" once the time has passed. */
function untilText(epochSeconds) {
  const left = epochSeconds * 1000 - Date.now();
  if (left <= 0) return 'any moment';
  const secs = Math.floor(left / 1000);
  const mins = Math.floor(secs / 60);
  const hours = Math.floor(mins / 60);
  // Seconds are shown because a countdown that only moves once a minute looks
  // frozen, and this is the number people sit and watch.
  if (mins < 60) return `in ${mins}m ${secs % 60}s`;
  if (hours < 24) return `in ${hours}h ${mins % 60}m ${secs % 60}s`;
  return `in ${Math.floor(hours / 24)}d ${hours % 24}h`;
}

function agoText(epochSeconds) {
  const gone = Math.floor((Date.now() - epochSeconds * 1000) / 60000);
  if (gone < 1) return 'just now';
  if (gone < 60) return `${gone}m ago`;
  const hours = Math.floor(gone / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.round(hours / 24)} days ago`;
}

function windowRow(name, w) {
  if (!w || w.resets_at === null) return null;
  const row = document.createElement('div');
  row.className = 'row';

  const label = document.createElement('span');
  label.className = 'name';
  label.textContent = name;

  const bar = document.createElement('span');
  bar.className = 'bar';
  const fill = document.createElement('i');
  const pct = typeof w.used === 'number' ? Math.min(100, Math.max(0, w.used)) : 0;
  fill.style.width = `${pct}%`;
  bar.append(fill);

  const value = document.createElement('span');
  value.className = 'pct';
  value.textContent = typeof w.used === 'number' ? `${w.used}%` : '--';

  const when = document.createElement('span');
  when.className = 'when';
  // The reset time is kept on the element so the one-second tick can redraw it
  // without going back to disk.
  when.dataset.resets = String(w.resets_at);
  when.textContent = untilText(w.resets_at);

  row.append(label, bar, value, when);
  return row;
}

/// Turn whatever came back from the command into something worth reading.
///
/// The previous version swallowed every failure, which meant a broken home
/// directory and a working-but-empty one looked identical: nothing happened and
/// you were left to guess.
function limitsError(err) {
  const text = typeof err === 'string' ? err : err?.message || String(err);
  if (/home directory/i.test(text)) {
    return 'Could not work out your home folder, so there is nowhere to read from.';
  }
  if (/permission|denied|os error 5/i.test(text)) {
    return 'Not allowed to read the usage files in your .claude folder.';
  }
  return `Could not read the usage files: ${text}`;
}

let checking = false;

async function showLimits({ manual = false } = {}) {
  const host = document.getElementById('limits');
  if (!host) return;
  // The minute timer must not fight a click, and a second click while the first
  // is still going would race two redraws onto the same element.
  if (checking) return;

  const button = document.getElementById('refresh-limits');
  checking = true;
  if (manual && button) {
    button.disabled = true;
    button.classList.add('busy');
    button.textContent = 'Checking';
  }

  let sources = null;
  let failure = null;
  try {
    sources = await invoke('read_limits');
  } catch (err) {
    failure = limitsError(err);
  }

  // Reading local files is usually instant, and a spinner that appears and
  // vanishes within one frame reads as a glitch rather than as progress. This
  // holds the busy state just long enough to be seen as deliberate.
  if (manual) await new Promise((r) => setTimeout(r, 220));

  try {
    if (failure !== null) {
      host.textContent = '';
      const p = document.createElement('p');
      p.className = 'hint error';
      p.textContent = failure;
      host.append(p);
      return;
    }

    host.textContent = '';
    if (!sources.length) {
      const p = document.createElement('p');
      p.className = 'hint';
      p.textContent =
        'Nothing known yet. Open Claude Code once, or a claude.ai tab with the ' +
        'browser extension, and the times appear here.';
      host.append(p);
      return;
    }

    // One set of bars per account, not per source. Claude Code and the browser
    // reading the same account are the same window, and showing it twice was
    // just noise. Two accounts still get two blocks, which is the case the
    // separation existed for.
    //
    // The status line does not report an account at all, so a source without
    // one joins the single known account when there is exactly one. With two
    // known accounts it cannot be placed, and is shown on its own rather than
    // guessed into the wrong one.
    const known = [...new Set(sources.map((x) => x.account).filter(Boolean))];
    const groups = new Map();
    for (const src of sources) {
      const key = src.account || (known.length === 1 ? known[0] : 'unknown');
      const existing = groups.get(key);
      // The freshest reading wins: they describe the same window, so the newer
      // one is simply more current.
      if (!existing || (src.updated || 0) > (existing.updated || 0)) {
        groups.set(key, src);
      }
    }

    for (const [account, s2] of groups) {
      if (groups.size > 1) {
        const from = document.createElement('div');
        from.className = 'from';
        from.textContent = account === 'unknown' ? 'another account' : `account ${account}`;
        host.append(from);
      }
      const five = windowRow('5 hours', s2.five_hour);
      const week = windowRow('7 days', s2.seven_day);
      if (five) host.append(five);
      if (week) host.append(week);

      if (s2.updated) {
        const seen = document.createElement('div');
        seen.className = 'from';
        // Stale figures are worth flagging: nothing has read the numbers in a
        // while, so a window may have rolled over without anything noticing.
        const stale = Date.now() - s2.updated * 1000 > 6 * 3600 * 1000;
        if (stale) seen.classList.add('stale');
        seen.textContent = stale
          ? `last seen ${agoText(s2.updated)}, so this may be out of date`
          : `last seen ${agoText(s2.updated)}`;
        host.append(seen);
      }
    }

  } finally {
    checking = false;
    if (manual && button) {
      button.disabled = false;
      button.classList.remove('busy');
      button.textContent = 'Check usage';
    }
  }
}

document
  .getElementById('refresh-limits')
  ?.addEventListener('click', () => showLimits({ manual: true }));
showLimits();
// Two timers on purpose. The figures are re-read from disk once a minute,
// because that is how often they can change. The countdown is redrawn every
// second, because a display with seconds in it that only moves once a minute
// is worse than one without them.
setInterval(showLimits, 60000);
setInterval(() => {
  for (const el of document.querySelectorAll('#limits .when[data-resets]')) {
    el.textContent = untilText(Number(el.dataset.resets));
  }
}, 1000);

// --------------------------------------------------------------- browser ---

// This used to be a terminal command plus an extension id copied out of
// chrome://extensions. The app registers itself as the browser's link instead,
// so there is nothing to copy and no Python to install.
/** Say plainly what the link is, and is not, doing.
 *
 * The switch alone was not enough: turning it on and seeing nothing change is
 * indistinguishable from turning it on and it failing.
 */
async function showBridge() {
  const host = document.getElementById('bridge-detail');
  if (!host) return;
  let s;
  try {
    s = await invoke('bridge_status');
  } catch (e) {
    host.textContent = `Could not check the link: ${String(e)}`;
    return;
  }

  const lines = [];
  if (s.installed) {
    lines.push('Your browsers can see this app.');
  } else {
    lines.push('Not connected yet. Turn the switch on above.');
  }
  if (s.registered === false && s.installed) {
    lines.push('Chrome could not be registered, so it may not find the app.');
  }
  if (!s.notifier) {
    lines.push('The notifier is not installed, so alerts would have nothing to play. Install the alerts first.');
  }
  lines.push(
    s.last_contact
      ? `The browser last spoke to this app ${s.last_contact} ago.`
      : 'The browser has never spoken to this app yet.'
  );
  lines.push(
    s.last_reading
      ? 'A usage reading from the browser has arrived.'
      : 'No usage reading from the browser yet. Open a claude.ai tab with the extension on.'
  );
  lines.push(`Trusting extension id: ${s.extension_id}`);
  const idField = document.getElementById('extension-id');
  if (idField && !idField.value) idField.value = s.extension_id;
  for (const m of s.manifests) lines.push(m);

  host.textContent = '';
  for (const line of lines) {
    const p = document.createElement('div');
    p.textContent = line;
    host.append(p);
  }
}

document.getElementById('bridge-check')?.addEventListener('click', showBridge);

document.getElementById('bridge-test')?.addEventListener('click', (e) =>
  busy(e.target, async () => {
    note('bridge-test-result', 'Asking the browser...');
    try {
      note('bridge-test-result', await invoke('test_browser'));
    } catch (err) {
      note('bridge-test-result', String(err));
    }
  })
);

// Notice when the extension reaches this app, so a test started in the browser
// is answered here rather than only in the browser.
let lastSeenContact = null;
setInterval(async () => {
  const s = await invoke('bridge_status').catch(() => null);
  if (!s) return;
  if (lastSeenContact === null) {
    lastSeenContact = s.last_contact || '';
    return;
  }
  if (s.last_contact && s.last_contact !== lastSeenContact) {
    lastSeenContact = s.last_contact;
    status('The browser extension just reached this app.', 'ok');
    showBridge();
  }
}, 3000);

/** The whole connection, as one procedure with something to watch.
 *
 * A tick that wrote a preference told nobody anything, and could not: the
 * browser has to speak first. This registers the app, then waits for the
 * extension to actually say something, and shows which of those two halves it
 * is on rather than declaring success at the halfway point.
 */
let waitTimer = null;

document.getElementById('bridge-connect')?.addEventListener('click', (e) =>
  busy(e.target, async () => {
    const dialog = document.getElementById('bridge-wait');
    const step = document.getElementById('bridge-wait-step');
    const waitNote = document.getElementById('bridge-wait-note');
    const done = document.getElementById('bridge-wait-done');
    if (done) done.hidden = true;
    if (waitNote) waitNote.textContent = '';
    dialog?.showModal();

    const idField = document.getElementById('extension-id');
    try {
      await invoke('set_bridge', { enable: true, extensionId: idField?.value || null });
    } catch (err) {
      if (step) step.textContent = `Could not register: ${String(err)}`;
      if (done) done.hidden = false;
      return;
    }
    if (step) step.textContent = 'Registered. Now waiting for the extension to say hello.';

    // Watches the app's own record of when the browser last spoke, so the wait
    // ends on something that actually happened rather than on a timer.
    const startedAt = Date.now();
    const before = (await invoke('bridge_status').catch(() => null))?.last_contact || null;
    clearInterval(waitTimer);
    waitTimer = setInterval(async () => {
      const st = await invoke('bridge_status').catch(() => null);
      if (!st) return;
      if (st.last_contact && st.last_contact !== before) {
        clearInterval(waitTimer);
        if (step) step.textContent = 'The extension reached this app. The link works.';
        if (waitNote) waitNote.textContent = '';
        if (done) done.hidden = false;
        showBridge();
        return;
      }
      const waited = Math.round((Date.now() - startedAt) / 1000);
      if (waitNote) waitNote.textContent = `Listening... ${waited}s`;
      if (waited > 180) {
        clearInterval(waitTimer);
        if (step) {
          step.textContent =
            'Nothing heard in three minutes. Check the extension is reloaded, and ' +
            'that the id it shows matches the one in this window.';
        }
        if (done) done.hidden = false;
      }
    }, 1000);
  })
);

for (const id of ['bridge-wait-cancel', 'bridge-wait-done']) {
  document.getElementById(id)?.addEventListener('click', () => {
    clearInterval(waitTimer);
    document.getElementById('bridge-wait')?.close();
    showBridge();
  });
}

// ---------------------------------------------------------------- about ---

const about = document.getElementById('about');
document.getElementById('about-open')?.addEventListener('click', () => about?.showModal());
document.getElementById('about-close')?.addEventListener('click', () => about?.close());
// Clicking the backdrop closes it, which is what everyone expects of a dialog.
about?.addEventListener('click', (e) => {
  if (e.target === about) about.close();
});

// Links go through a command with a fixed allowlist rather than being opened by
// the page, because this window has no shell or network permission at all and
// should not gain one for three URLs.
for (const link of document.querySelectorAll('.about-links a')) {
  link.addEventListener('click', async (e) => {
    e.preventDefault();
    try {
      await invoke('open_url', { url: link.dataset.url });
    } catch (err) {
      link.textContent = 'Could not open your browser';
    }
  });
}
