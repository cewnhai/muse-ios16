// ==UserScript==
// @name         Muse iOS 16 Compatibility
// @namespace    local.muse.compat
// @version      1.1.0
// @description  Polyfill missing Web APIs on iOS 16 Safari so muse.ai web login works (injects into the page context via DOM, does not rely on the manager's page mode)
// @match        https://muse.ai/*
// @run-at       document-start
// @inject-into  content
// @grant        none
// ==/UserScript==

// This wrapper runs in the extension's content (isolated) context, which is
// available on every Safari version. It injects the actual polyfill into the
// page's own JS context with a <script> tag, so the site's own code sees the
// patched APIs. (The manager's `@inject-into page` mode is unreliable on
// iOS 16, which made v1.0.0 a no-op there.)
(function () {
  'use strict';

  function polyfillInPage() {
    'use strict';
    var patched = [];

    // AbortSignal.any() — Safari 18+ only.
    if (typeof AbortSignal.any !== 'function') {
      Object.defineProperty(AbortSignal, 'any', {
        configurable: true,
        writable: true,
        value: function (signals) {
          var list = Array.from(signals);
          var controller = new AbortController();
          var i;
          for (i = 0; i < list.length; i++) {
            if (list[i].aborted) {
              controller.abort(list[i].reason);
              return controller.signal;
            }
          }
          var onAbort = function (event) {
            if (!controller.signal.aborted) {
              controller.abort(event.target.reason);
              cleanup();
            }
          };
          var cleanup = function () {
            for (var j = 0; j < list.length; j++) {
              list[j].removeEventListener('abort', onAbort);
            }
          };
          for (i = 0; i < list.length; i++) {
            list[i].addEventListener('abort', onAbort, { once: true });
          }
          return controller.signal;
        }
      });
      patched.push('AbortSignal.any');
    }

    // AbortSignal.timeout() — Safari 18+ only.
    if (typeof AbortSignal.timeout !== 'function') {
      Object.defineProperty(AbortSignal, 'timeout', {
        configurable: true,
        writable: true,
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

    // Promise.withResolvers() — Safari 17.2+ only, missing on iOS 16.
    if (typeof Promise.withResolvers !== 'function') {
      Object.defineProperty(Promise, 'withResolvers', {
        configurable: true,
        writable: true,
        value: function () {
          var resolve, reject;
          var promise = new Promise(function (res, rej) {
            resolve = res;
            reject = rej;
          });
          return { promise: promise, resolve: resolve, reject: reject };
        }
      });
      patched.push('Promise.withResolvers');
    }

    // Marker on <html> so the injection can be verified from outside the page
    // context (e.g. via Web Inspector or a content script reading the DOM).
    try {
      document.documentElement.setAttribute(
        'data-muse-compat',
        patched.length ? patched.join(',') : 'none-needed'
      );
    } catch (e) {}
    try {
      console.info(
        '[Muse compatibility] patch loaded:',
        patched.length ? patched.join(', ') : 'nothing to patch'
      );
    } catch (e) {}
  }

  function inject() {
    try {
      var docEl = document.documentElement;
      if (!docEl) return false;
      var s = document.createElement('script');
      s.textContent = '(' + polyfillInPage.toString() + ')();';
      docEl.appendChild(s);
      s.remove();
      return true;
    } catch (e) {
      return false;
    }
  }

  if (!inject()) {
    // Paranoia: if documentElement is somehow not ready yet at document-start,
    // retry until it appears (gives up after ~5s).
    var obs = new MutationObserver(function () {
      if (inject()) obs.disconnect();
    });
    obs.observe(document, { childList: true, subtree: true });
    setTimeout(function () { obs.disconnect(); }, 5000);
  }
})();
