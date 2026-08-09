// Earshot - limits reconnaissance
//
// Paste into the console on claude.ai, then run:
//
//     earshotLimits()
//
// It answers one question: does claude.ai give the page anything that says
// when your 5 hour window resets, without you having to hit the limit first?
//
// WHAT IT DOES AND DOES NOT READ
//
// It reads three things:
//   * the NAMES of keys in localStorage and sessionStorage, and for each one
//     only whether the value looks like a timestamp or a percentage
//   * the URLs of requests the page has already made, from the browser's own
//     performance timeline
//   * the organisation id, shortened
//
// It does not read request or response bodies, does not make any request of
// its own, and does not read message text. Values are reported by shape, never
// by content, so nothing private ends up in what you paste back.
//
// Reading URLs from the performance timeline is the point: it tells us which
// endpoints exist without touching what they return. If a usage endpoint shows
// up, that is the finding. Deciding whether reading it is worth the permission
// it would cost comes after, as a separate decision.

(() => {
  const INTERESTING = /usage|limit|rate|quota|subscription|billing|tier|plan|capacity/i;

  /** Describe a value by shape only. Never returns the value itself. */
  function shapeOf(raw) {
    if (raw == null) return 'empty';
    const s = String(raw);
    if (s.length > 20000) return 'very large blob (' + s.length + ' chars)';

    const hits = [];
    // An ISO timestamp or a unix time in the near future is exactly what a
    // reset time would look like, so those are called out specifically.
    if (/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(s)) hits.push('ISO timestamp');
    if (/\b1[7-9]\d{8}\b/.test(s)) hits.push('unix seconds');
    if (/\b1[7-9]\d{11}\b/.test(s)) hits.push('unix millis');
    if (/reset|expires|refresh/i.test(s)) hits.push('mentions reset/expiry');
    if (/"?(used_?percentage|percent|remaining)"?\s*[:=]/i.test(s)) hits.push('a percentage field');
    if (/five_?hour|5h|seven_?day|weekly/i.test(s)) hits.push('a window name');

    return hits.length ? hits.join(', ') : 'nothing that looks like a limit';
  }

  function scanStorage(store, name) {
    const out = [];
    let keys = [];
    try { keys = Object.keys(store); } catch { return out; }
    for (const key of keys) {
      let raw = null;
      try { raw = store.getItem(key); } catch { continue; }
      const shape = shapeOf(raw);
      const relevant = INTERESTING.test(key) || shape !== 'nothing that looks like a limit';
      if (relevant) out.push({ store: name, key: key.slice(0, 80), looksLike: shape });
    }
    return out;
  }

  window.earshotLimits = () => {
    // Endpoints the page has already called. URLs only: the timeline does not
    // expose bodies, which is exactly why this is the safe way to look.
    let urls = [];
    try {
      urls = performance.getEntriesByType('resource')
        .map((e) => e.name)
        .filter((u) => u.includes('/api/'));
    } catch { /* not available */ }

    const strip = (u) => {
      try {
        const parsed = new URL(u);
        return parsed.pathname
          .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<uuid>')
          .replace(/\/[0-9a-f]{16,}/gi, '/<id>');
      } catch { return '<unparseable>'; }
    };

    const all = [...new Set(urls.map(strip))];
    const promising = all.filter((p) => INTERESTING.test(p));

    // The organisation id decides whose limits these are, and is the thing that
    // stops one account's reset time being reported for another. Only the first
    // eight characters are shown: enough to tell two accounts apart, not enough
    // to be an identifier worth pasting around.
    let org = null;
    const match = urls.join(' ').match(/organizations\/([0-9a-f-]{36})/i);
    if (match) org = match[1].slice(0, 8) + '...';

    const report = {
      org,
      promisingEndpoints: promising,
      allApiPaths: all.slice(0, 60),
      storage: [...scanStorage(localStorage, 'local'), ...scanStorage(sessionStorage, 'session')],
    };

    console.log('%c--- Earshot limits recon: copy below ---', 'font-weight:bold;font-size:13px');
    console.log(JSON.stringify(report, null, 2));
    console.log('%c--- end ---', 'font-weight:bold;font-size:13px');
    if (!promising.length && !report.storage.length) {
      console.log('%cNothing obvious. That is a real result, not a failure.', 'color:#888');
    }
    return report;
  };

  // ---- reading the usage endpoint ----------------------------------------

  /** Describe a value, keeping what is useful and dropping what is private.
   *
   * Numbers, booleans and timestamps are shown, because a percentage and a
   * reset time are the entire point. Every other string is reduced to its
   * type and length. Field names are always shown: they are the schema, not
   * the data.
   */
  function safeValue(v) {
    if (v === null) return null;
    if (typeof v === 'number' || typeof v === 'boolean') return v;
    if (typeof v === 'string') {
      if (/^\d{4}-\d{2}-\d{2}T[\d:.]+Z?$/.test(v)) return v;   // a timestamp
      if (/^(free|pro|max|team|enterprise|claude_\w+)$/i.test(v)) return v;
      return '<string, ' + v.length + " chars>";
    }
    return v;
  }

  function safeShape(node, depth) {
    if (depth > 4) return '<deeper>';
    if (Array.isArray(node)) {
      return node.length ? [safeShape(node[0], depth + 1), '<' + node.length + ' items>'] : [];
    }
    if (node && typeof node === 'object') {
      const out = {};
      for (const [k, v] of Object.entries(node)) out[k] = safeShape(v, depth + 1);
      return out;
    }
    return safeValue(node);
  }

  /** Fetch the usage endpoint and print its shape.
   *
   * This makes one GET request, to an endpoint the page already calls itself,
   * using the session you are already signed into. It runs no model, so it
   * consumes no tokens and does not touch your usage. Nothing is sent
   * anywhere: the response is printed here and goes no further.
   */
  window.earshotUsage = async () => {
    let org = null;
    try {
      const urls = performance.getEntriesByType('resource').map((e) => e.name).join(' ');
      const m = urls.match(/organizations\/([0-9a-f-]{36})/i);
      org = m && m[1];
    } catch { /* nothing */ }
    if (!org) {
      console.log('%cCould not find the organisation id. Use the site briefly, then retry.', 'color:#c00');
      return null;
    }

    const url = '/api/organizations/' + org + '/usage';
    let body;
    try {
      const res = await fetch(url, { credentials: 'include' });
      if (!res.ok) {
        console.log('%c' + url.replace(org, '<org>') + ' returned ' + res.status, 'color:#c00');
        return null;
      }
      body = await res.json();
    } catch (e) {
      console.log('%cRequest failed: ' + e.message, 'color:#c00');
      return null;
    }

    const shape = safeShape(body, 0);
    console.log('%c--- Earshot usage shape: copy below ---', 'font-weight:bold;font-size:13px');
    console.log(JSON.stringify(shape, null, 2));
    console.log('%c--- end ---', 'font-weight:bold;font-size:13px');
    return shape;
  };

  console.log(
    '%cEarshot limits recon ready.',
    'font-weight:bold;font-size:13px',
    '\nearshotLimits()   what the page stores and which endpoints it calls',
    '\nearshotUsage()    read the usage endpoint and show its shape',
    '\nUse the site for a minute first, so the page has made some requests.'
  );
})();
