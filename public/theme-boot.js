// No-flash theme boot (docs/design/redesign-v0.4/PROMPT.md §1). Loaded as a plain,
// non-module, non-deferred <script> in <head> — BEFORE any CSS — so <html> already
// carries the right `data-theme` (and legacy `.dark` class) by the time the first
// paint happens.
//
// This is a separate file, not an inline <script>, because the Tauri CSP is
// `script-src 'self'` — inline script is blocked in the bundled app. A same-origin
// external file satisfies 'self' and still runs synchronously in <head>.
//
// Keep this in sync with src/theme/theme.ts (THEME_STORAGE_KEY, resolveTheme,
// applyThemeToDocument) — it intentionally duplicates that tiny bit of logic
// rather than importing it, since it must run before any module graph loads.
(function () {
  var STORAGE_KEY = "apex.theme";
  var pref = "system";
  try {
    var stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "system" || stored === "light" || stored === "dark") pref = stored;
  } catch (e) {
    // localStorage unavailable (private mode, disabled storage) — default to system.
  }

  var systemDark = false;
  try {
    systemDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  } catch (e) {
    // matchMedia unavailable — default to light.
  }

  var resolved = pref === "system" ? (systemDark ? "dark" : "light") : pref;

  var root = document.documentElement;
  root.setAttribute("data-theme", resolved);
  if (resolved === "dark") root.classList.add("dark");
})();
