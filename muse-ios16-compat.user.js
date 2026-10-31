// ==UserScript==
// @name         Muse iOS 16 Compatibility
// @namespace    local.muse.compat
// @version      1.0.0
// @description  Polyfill missing Web APIs on iOS 16 Safari so muse.ai web login works
// @match        https://muse.ai/*
// @run-at       document-start
// @inject-into  page
// @grant        none
// ==/UserScript==

(function () {
  "use strict";

  const patched = [];

  // AbortSignal.any() — Safari 18+ only. Returns a signal that aborts
  // as soon as any of the given signals aborts (with that signal's reason).
  if (typeof AbortSignal.any !== "function") {
    Object.defineProperty(AbortSignal, "any", {
      configurable: true,
      writable: true,
      value: function (signals) {
        const list = Array.from(signals);
        const controller = new AbortController();

        for (const signal of list) {
          if (signal.aborted) {
            controller.abort(signal.reason);
            return controller.signal;
          }
        }

        const cleanup = () => {
          for (const signal of list) {
            signal.removeEventListener("abort", onAbort);
          }
        };

        const onAbort = event => {
          if (!controller.signal.aborted) {
            controller.abort(event.target.reason);
            cleanup();
          }
        };

        for (const signal of list) {
          signal.addEventListener("abort", onAbort, { once: true });
        }

        return controller.signal;
      }
    });
    patched.push("AbortSignal.any");
  }

  // AbortSignal.timeout() — Safari 18+ only. Returns a signal that
  // auto-aborts after the given milliseconds with a TimeoutError.
  if (typeof AbortSignal.timeout !== "function") {
    Object.defineProperty(AbortSignal, "timeout", {
      configurable: true,
      writable: true,
      value: function (milliseconds) {
        const controller = new AbortController();

        setTimeout(() => {
          controller.abort(
            new DOMException("The operation timed out", "TimeoutError")
          );
        }, Math.max(0, Number(milliseconds) || 0));

        return controller.signal;
      }
    });
    patched.push("AbortSignal.timeout");
  }

  // Promise.withResolvers() — Safari 17.2+ only. Missing on iOS 16.
  if (typeof Promise.withResolvers !== "function") {
    Object.defineProperty(Promise, "withResolvers", {
      configurable: true,
      writable: true,
      value: function () {
        let resolve, reject;
        const promise = new Promise((res, rej) => {
          resolve = res;
          reject = rej;
        });
        return { promise, resolve, reject };
      }
    });
    patched.push("Promise.withResolvers");
  }

  console.info(
    "[Muse compatibility] patch loaded:",
    patched.length ? patched.join(", ") : "nothing to patch"
  );
})();
