// Web content embedded in the builtin bench app and in every generated bundle.
// The same bench.js runs in every bundle, so the chain survives each reload
// (direct mode reloads the WebView into the freshly downloaded bundle).
import { deviceBaseUrl } from './config.mjs';

export function indexHtml(marker) {
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>capgo bench</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;margin:24px;font-size:14px}pre{white-space:pre-wrap;word-break:break-all}</style>
</head>
<body>
<h3>Capgo updater bench</h3>
<div id="marker">${marker}</div>
<pre id="log"></pre>
<script src="bench.js"></script>
</body>
</html>
`;
}

// Plain script (no bundler): talks to the plugin through the Capacitor native
// bridge exactly like the registerPlugin() proxy does (Capacitor.nativePromise).
export function benchJs(marker) {
  return `/* capgo bench ${marker} */
(function () {
  'use strict';
  var SERVER = ${JSON.stringify(deviceBaseUrl)};
  var TSET_KEY = '__capgo_bench_tset';
  var logEl = document.getElementById('log');
  function log(msg) {
    var line = new Date().toISOString().slice(11, 23) + ' ' + msg;
    if (logEl) logEl.textContent = (line + '\\n' + logEl.textContent).slice(0, 4000);
    try { console.log('[bench] ' + msg); } catch (e) {}
  }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function call(method, options) {
    return window.Capacitor.nativePromise('CapacitorUpdater', method, options || {});
  }
  function post(path, body) {
    return fetch(SERVER + path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body || {}),
    }).then(function (r) { return r.json(); });
  }
  async function postRetry(path, body) {
    for (var i = 0; ; i++) {
      try { return await post(path, body); } catch (e) {
        log('post ' + path + ' failed: ' + (e && e.message));
        if (i > 30) throw e;
        await sleep(1000);
      }
    }
  }
  function errText(e) {
    if (!e) return 'unknown error';
    return String(e.message || e.errorMessage || e.code || e);
  }
  async function cleanupBundles() {
    try {
      var cur = await call('current');
      var currentId = cur && cur.bundle ? cur.bundle.id : null;
      var list = await call('list', { raw: false });
      var bundles = (list && list.bundles) || [];
      for (var i = 0; i < bundles.length; i++) {
        var b = bundles[i];
        if (!b || !b.id || b.id === currentId || b.id === 'builtin') continue;
        try { await call('delete', { id: b.id }); } catch (e) { log('delete ' + b.id + ' failed: ' + errText(e)); }
      }
    } catch (e) {
      log('cleanup failed: ' + errText(e));
    }
  }
  async function runCase(c) {
    log('run ' + c.id + ' attempt ' + c.attempt);
    await cleanupBundles();
    var base = { caseId: c.id, attempt: c.attempt };
    var t0 = Date.now();
    var bundle;
    try {
      bundle = await call('download', c.download);
    } catch (e) {
      return postRetry('/bench/result', Object.assign({}, base, { ok: false, error: 'download: ' + errText(e) }));
    }
    var t1 = Date.now();
    if (c.mode === 'background') {
      return postRetry('/bench/result', Object.assign({}, base, { ok: true, t0: t0, t1: t1, bundleId: bundle && bundle.id, status: bundle && bundle.status }));
    }
    await postRetry('/bench/downloaded', Object.assign({}, base, { t0: t0, t1: t1, bundleId: bundle && bundle.id, status: bundle && bundle.status }));
    var tSet = Date.now();
    try { localStorage.setItem(TSET_KEY, JSON.stringify({ caseId: c.id, attempt: c.attempt, tSet: tSet })); } catch (e) {}
    try {
      await call('set', { id: bundle.id });
    } catch (e) {
      return postRetry('/bench/result', Object.assign({}, base, { ok: false, error: 'set: ' + errText(e) }));
    }
    // set() reloads the WebView: this page normally dies before getting here.
    await sleep(120000);
    return postRetry('/bench/result', Object.assign({}, base, { ok: false, error: 'set() resolved but no reload happened' }));
  }
  async function main() {
    var ready = null;
    var readyError = null;
    try { ready = await call('notifyAppReady'); } catch (e) { readyError = errText(e); }
    var tReady = Date.now();
    var cur = null;
    try { cur = await call('current'); } catch (e) {}
    var pendingSet = null;
    try { pendingSet = JSON.parse(localStorage.getItem(TSET_KEY) || 'null'); localStorage.removeItem(TSET_KEY); } catch (e) {}
    var bundle = cur && cur.bundle ? cur.bundle : null;
    log('boot ' + ${JSON.stringify(marker)} + ' bundle=' + (bundle ? bundle.version : '?'));
    var resp = await postRetry('/bench/boot', {
      marker: ${JSON.stringify(marker)},
      tReady: tReady,
      readyError: readyError,
      ready: ready,
      bundle: bundle,
      pendingSet: pendingSet,
      userAgent: navigator.userAgent,
    });
    for (;;) {
      if (!resp || resp.action === 'done') { log('done'); return; }
      if (resp.action === 'wait') { await sleep(resp.ms || 2000); resp = await postRetry('/bench/next', {}); continue; }
      if (resp.action === 'run') { resp = await runCase(resp.case); continue; }
      log('unknown action ' + JSON.stringify(resp));
      await sleep(2000);
      resp = await postRetry('/bench/next', {});
    }
  }
  main().catch(function (e) {
    log('fatal: ' + errText(e));
    post('/bench/log', { fatal: errText(e) }).catch(function () {});
  });
})();
`;
}
