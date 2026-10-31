// ==UserScript==
// @name         Muse iOS 16 Diagnostic
// @namespace    local.muse.compat
// @version      1.0.0
// @description  Diagnostic probe for muse.ai on old Safari: shows a floating panel with UA, natively missing Web APIs, applied polyfills and page JS errors. Screenshot it and send back.
// @match        https://muse.ai/*
// @run-at       document-start
// @inject-into  content
// @grant        none
// ==/UserScript==

// Runs in the extension content context, injects the probe into the page's
// own JS context via a <script> tag (same technique as the compat script).
(function () {
  'use strict';

  function probeInPage() {
    'use strict';

    var errors = [];
    var nativeMiss = [];
    var nativeOkCount = 0;
    var patched = [];

    function check(name, fn) {
      var ok = false;
      try { ok = !!fn(); } catch (e) { ok = false; }
      if (ok) { nativeOkCount++; } else { nativeMiss.push(name); }
    }

    // Capture page JS errors (sync throws) and unhandled promise rejections.
    window.addEventListener('error', function (e) {
      var msg = '';
      try { msg = String(e.message || (e.error && e.error.message) || e.error || e); } catch (x) { msg = 'unknown error'; }
      errors.push('error: ' + msg);
      render();
    });
    window.addEventListener('unhandledrejection', function (e) {
      var r = e.reason, msg = '';
      try { msg = String((r && (r.message || r)) || r); } catch (x) { msg = 'unknown rejection'; }
      errors.push('unhandledrejection: ' + msg);
      render();
    });

    // ---- 1. Probe NATIVE state first (before patching) ----
    check('AbortSignal.any', function () { return typeof AbortSignal.any === 'function'; });
    check('AbortSignal.timeout', function () { return typeof AbortSignal.timeout === 'function'; });
    check('AbortSignal.prototype.throwIfAborted', function () { return typeof AbortSignal.prototype.throwIfAborted === 'function'; });
    check('Promise.withResolvers', function () { return typeof Promise.withResolvers === 'function'; });
    check('Promise.allSettled', function () { return typeof Promise.allSettled === 'function'; });
    check('Promise.any', function () { return typeof Promise.any === 'function'; });
    check('Promise.try', function () { return typeof Promise.try === 'function'; });
    check('Array.prototype.toSorted', function () { return typeof Array.prototype.toSorted === 'function'; });
    check('Array.prototype.toReversed', function () { return typeof Array.prototype.toReversed === 'function'; });
    check('Array.prototype.toSpliced', function () { return typeof Array.prototype.toSpliced === 'function'; });
    check('Array.prototype.with', function () { return typeof Array.prototype.with === 'function'; });
    check('Array.prototype.findLast', function () { return typeof Array.prototype.findLast === 'function'; });
    check('Array.prototype.findLastIndex', function () { return typeof Array.prototype.findLastIndex === 'function'; });
    check('Array.prototype.at', function () { return typeof Array.prototype.at === 'function'; });
    check('Array.fromAsync', function () { return typeof Array.fromAsync === 'function'; });
    check('Object.hasOwn', function () { return typeof Object.hasOwn === 'function'; });
    check('Object.groupBy', function () { return typeof Object.groupBy === 'function'; });
    check('Map.groupBy', function () { return typeof Map.groupBy === 'function'; });
    check('structuredClone', function () { return typeof structuredClone === 'function'; });
    check('Set.prototype.union', function () { return typeof Set.prototype.union === 'function'; });
    check('Set.prototype.intersection', function () { return typeof Set.prototype.intersection === 'function'; });
    check('Set.prototype.difference', function () { return typeof Set.prototype.difference === 'function'; });
    check('ArrayBuffer.prototype.transfer', function () { return typeof ArrayBuffer.prototype.transfer === 'function'; });
    check('RegExp.escape', function () { return typeof RegExp.escape === 'function'; });
    check('URL.parse', function () { return typeof URL.parse === 'function'; });
    check('URL.canParse', function () { return typeof URL.canParse === 'function'; });
    check('String.prototype.isWellFormed', function () { return typeof String.prototype.isWellFormed === 'function'; });
    check('String.prototype.toWellFormed', function () { return typeof String.prototype.toWellFormed === 'function'; });
    check('String.prototype.replaceAll', function () { return typeof String.prototype.replaceAll === 'function'; });
    check('String.prototype.at', function () { return typeof String.prototype.at === 'function'; });
    check('Intl.Segmenter', function () { return typeof Intl.Segmenter === 'function'; });
    check('Intl.DurationFormat', function () { return typeof Intl.DurationFormat === 'function'; });
    check('Atomics.waitAsync', function () { return typeof Atomics.waitAsync === 'function'; });
    check('scheduler', function () { return typeof scheduler !== 'undefined'; });
    check('crypto.randomUUID', function () { return !!(window.crypto && typeof window.crypto.randomUUID === 'function'); });
    check('CompressionStream', function () { return typeof CompressionStream === 'function'; });
    check('DecompressionStream', function () { return typeof DecompressionStream === 'function'; });
    check('OffscreenCanvas', function () { return typeof OffscreenCanvas === 'function'; });
    check('Element.prototype.checkVisibility', function () { return typeof Element.prototype.checkVisibility === 'function'; });
    check('HTMLElement.prototype.showPopover', function () { return typeof HTMLElement.prototype.showPopover === 'function'; });
    check('CSS selector(:has)', function () { return CSS.supports('selector(:has(*))'); });
    check('navigator.clipboard', function () { return !!navigator.clipboard; });
    check('navigator.userAgentData', function () { return !!navigator.userAgentData; });
    check('ResizeObserver', function () { return typeof ResizeObserver === 'function'; });
    check('queueMicrotask', function () { return typeof queueMicrotask === 'function'; });
    check('WeakRef', function () { return typeof WeakRef === 'function'; });
    check('AggregateError', function () { return typeof AggregateError === 'function'; });

    // ---- 2. Apply the same polyfills as the compat script ----
    if (typeof AbortSignal.any !== 'function') {
      Object.defineProperty(AbortSignal, 'any', {
        configurable: true, writable: true,
        value: function (signals) {
          var list = Array.from(signals);
          var controller = new AbortController();
          var i;
          for (i = 0; i < list.length; i++) {
            if (list[i].aborted) { controller.abort(list[i].reason); return controller.signal; }
          }
          var onAbort = function (event) {
            if (!controller.signal.aborted) { controller.abort(event.target.reason); cleanup(); }
          };
          var cleanup = function () {
            for (var j = 0; j < list.length; j++) { list[j].removeEventListener('abort', onAbort); }
          };
          for (i = 0; i < list.length; i++) { list[i].addEventListener('abort', onAbort, { once: true }); }
          return controller.signal;
        }
      });
      patched.push('AbortSignal.any');
    }
    if (typeof AbortSignal.timeout !== 'function') {
      Object.defineProperty(AbortSignal, 'timeout', {
        configurable: true, writable: true,
        value: function (milliseconds) {
          var controller = new AbortController();
          setTimeout(function () {
            controller.abort(new DOMException('The operation timed out', 'TimeoutError'));
          }, Math.max(0, Number(milliseconds) || 0));
          return controller.signal;
        }
      });
      patched.push('AbortSignal.timeout');
    }
    if (typeof Promise.withResolvers !== 'function') {
      Object.defineProperty(Promise, 'withResolvers', {
        configurable: true, writable: true,
        value: function () {
          var resolve, reject;
          var promise = new Promise(function (res, rej) { resolve = res; reject = rej; });
          return { promise: promise, resolve: resolve, reject: reject };
        }
      });
      patched.push('Promise.withResolvers');
    }

    // ---- 3. Floating report panel (tap to hide) ----
    function render() {
      try {
        var el = document.getElementById('muse-diag-panel');
        if (!el) {
          el = document.createElement('div');
          el.id = 'muse-diag-panel';
          el.style.cssText = 'position:fixed;left:0;right:0;top:0;z-index:2147483647;' +
            'background:rgba(0,0,0,0.94);color:#00ff66;font:11px/1.5 monospace;' +
            'padding:10px;max-height:52vh;overflow:auto;white-space:pre-wrap;word-break:break-all;';
          el.title = 'tap to hide';
          el.addEventListener('click', function () { el.style.display = 'none'; });
          (document.body || document.documentElement).appendChild(el);
        }
        var lines = [];
        lines.push('MUSE DIAGNOSTIC (tap panel to hide)');
        lines.push('UA: ' + navigator.userAgent);
        lines.push('platform: ' + navigator.platform);
        lines.push('patched in page: ' + (patched.join(', ') || 'none'));
        lines.push('native check: ' + nativeOkCount + ' OK, ' + nativeMiss.length + ' MISSING');
        lines.push('MISSING: ' + (nativeMiss.join(', ') || 'none'));
        lines.push('page errors(' + errors.length + '):');
        if (errors.length) {
          var tail = errors.slice(-8);
          for (var i = 0; i < tail.length; i++) lines.push('  [' + i + '] ' + tail[i]);
        } else {
          lines.push('  (none captured)');
        }
        el.textContent = lines.join('\n');
      } catch (e) {}
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', render);
    } else {
      render();
    }
    setTimeout(render, 2500);
    setTimeout(render, 6000);
  }

  function inject() {
    try {
      var docEl = document.documentElement;
      if (!docEl) return false;
      var s = document.createElement('script');
      s.textContent = '(' + probeInPage.toString() + ')();';
      docEl.appendChild(s);
      s.remove();
      return true;
    } catch (e) {
      return false;
    }
  }

  if (!inject()) {
    var obs = new MutationObserver(function () {
      if (inject()) obs.disconnect();
    });
    obs.observe(document, { childList: true, subtree: true });
    setTimeout(function () { obs.disconnect(); }, 5000);
  }
})();
