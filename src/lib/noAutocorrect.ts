// macOS WKWebView applies system autocorrect/autocapitalize to every
// <input>/<textarea> in a Tauri app — there is no per-app opt-out at the OS
// level, only per-field. In a dev tool where the operator types hostnames,
// paths, branch names, SSH aliases and shell commands, the OS silently
// rewriting that text is catastrophic. Rather than hand-editing every
// input/textarea across src/, this module disables it globally.
//
// `autocorrect`/`autocapitalize` are the WebKit attributes that actually
// MUTATE typed text; `spellcheck` only draws the red squiggle underline and
// is disabled too — every input/textarea in this codebase carries technical
// content (hostnames, paths, commands, prompts mixing prose with code), not
// literary prose, so there is no field where the squiggle is worth the
// false-positive noise.
//
// WHY `focusin` AND NOT A MutationObserver:
// The first version observed `document.body` with `subtree: true`. xterm
// repaints terminal output by adding and removing DOM rows continuously, so
// with several live terminals that fired the callback hundreds of times a
// second — each one walking the DOM via `closest('.xterm')` just to decide it
// had nothing to do. Constant main-thread tax in the WebView process, on the
// app's hottest path, for fields that were not even on screen. (Reported as
// high `tauri://localhost` CPU, 2026-08-28.)
//
// Autocorrect can only affect a field the user is TYPING IN, and a field must
// be focused to be typed in. So hardening on `focusin` is both sufficient and
// O(1) per focus event: no polling, no observing, no work while terminals
// stream. A single delegated listener also covers anything mounted later —
// modals, new tabs, lazily-loaded panels — with no extra bookkeeping.

const FIELD_SELECTOR = "input, textarea";

function harden(el: Element | null): void {
  if (!(el instanceof HTMLInputElement) && !(el instanceof HTMLTextAreaElement)) return;
  // Cheap idempotence guard: skip fields already hardened.
  if (el.getAttribute("autocorrect") === "off") return;
  el.setAttribute("autocorrect", "off");
  el.setAttribute("autocapitalize", "off");
  el.setAttribute("spellcheck", "false");
}

/**
 * Install the global no-autocorrect behavior. Call once (mount-once effect)
 * from App.tsx. Returns a cleanup function — call it on unmount.
 */
export function installNoAutocorrect(): () => void {
  if (typeof document === "undefined") return () => {};

  // Harden what is already mounted, so a field focused before any event
  // (autofocused inputs) is covered too.
  document.querySelectorAll(FIELD_SELECTOR).forEach(harden);

  // `focusin` bubbles (unlike `focus`), so one delegated listener catches
  // every field in the document, including ones mounted later.
  const onFocusIn = (e: Event) => harden(e.target as Element | null);
  document.addEventListener("focusin", onFocusIn, true);
  return () => document.removeEventListener("focusin", onFocusIn, true);
}
