// Created by Claude — Classification: INTERNAL
//
// Startup guard. Loaded as a plain <script> in <head>, BEFORE the module graph.
//
// main.tsx forwards uncaught errors to the log file, but ES modules evaluate their
// imports first: an exception while App.tsx (or anything it imports) is being
// evaluated happens before main.tsx's handler exists, and the user gets a silent
// white window with nothing in any log. This catches errors from the very first
// line, forwards them to the Rust log (`frontend_log`) when running in Tauri, and
// if the app never mounts, replaces the white window with the error itself.
//
// External file, not inline: the Tauri CSP is `script-src 'self'`.
(function () {
  var errors = [];
  function describe(e) {
    if (!e) return "unknown error";
    var msg = e.message || String(e);
    var stack = e.stack ? String(e.stack).split("\n").slice(0, 6).join("\n") : "";
    return stack && stack.indexOf(msg) === -1 ? msg + "\n" + stack : stack || msg;
  }
  function forward(text) {
    try {
      var t = window.__TAURI_INTERNALS__;
      if (t && typeof t.invoke === "function") {
        t.invoke("frontend_log", { level: "error", message: "[boot] " + text }).catch(function () {});
      }
    } catch (_) {
      /* logging must never throw */
    }
  }
  function onError(ev) {
    var text = describe(ev.error || ev.reason || ev.message);
    errors.push(text);
    forward(text);
  }
  window.addEventListener("error", onError);
  window.addEventListener("unhandledrejection", onError);

  // If nothing has mounted after a generous delay, show why instead of white.
  setTimeout(function () {
    var root = document.getElementById("root");
    if (!root || root.childElementCount > 0) return;
    var box = document.createElement("pre");
    box.setAttribute("role", "alert");
    box.style.cssText =
      "margin:0;padding:24px 24px 24px 88px;font:12px/1.6 ui-monospace,monospace;" +
      "white-space:pre-wrap;color:#b42318;background:#fff;height:100vh;box-sizing:border-box;overflow:auto";
    box.textContent =
      "Muya could not start.\n\n" +
      (errors.length ? errors.join("\n\n") : "No error was reported — the interface never mounted.") +
      "\n\nThe same error is in the app log: ~/Library/Logs/<app id>/muya.log";
    document.body.appendChild(box);
    forward("app did not mount within 8s" + (errors.length ? "" : " (no error reported)"));
  }, 8000);
})();
