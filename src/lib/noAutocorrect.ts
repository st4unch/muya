// macOS WKWebView applies system autocorrect/autocapitalize to every
// <input>/<textarea> in a Tauri app — there is no per-app opt-out at the OS
// level, only per-field. In a dev tool where the operator types hostnames,
// paths, branch names, SSH aliases and shell commands, the OS silently
// rewriting that text is catastrophic. Rather than hand-editing every
// input/textarea across src/, this module disables it globally: once for
// whatever is already mounted, then via a MutationObserver for anything
// mounted later (modals, new terminal tabs, etc).
//
// `autocorrect`/`autocapitalize` are the WebKit attributes that actually
// MUTATE typed text; `spellcheck` only draws the red squiggle underline and
// is disabled too — every input/textarea in this codebase carries technical
// content (hostnames, paths, commands, prompts mixing prose with code), not
// literary prose, so there is no field where the squiggle is worth the
// false-positive noise. See src/lib/noAutocorrect.md-equivalent note in the
// muya-agent skill report for the fields considered and rejected.

const FIELD_SELECTOR = "input, textarea";

function harden(el: Element): void {
  if (!(el instanceof HTMLInputElement) && !(el instanceof HTMLTextAreaElement)) return;
  el.setAttribute("autocorrect", "off");
  el.setAttribute("autocapitalize", "off");
  el.setAttribute("spellcheck", "false");
}

function hardenTree(root: Node): void {
  if (root instanceof Element) {
    harden(root);
    root.querySelectorAll(FIELD_SELECTOR).forEach(harden);
  }
}

/**
 * Install the global no-autocorrect behavior. Call once (mount-once effect)
 * from App.tsx. Returns a cleanup function that disconnects the observer —
 * call it on unmount.
 */
export function installNoAutocorrect(): () => void {
  if (typeof document === "undefined") return () => {};

  hardenTree(document.body);

  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      if (m.addedNodes.length === 0) continue;
      // Skip mutations rooted inside a live xterm terminal — its DOM
      // renderer churns rows constantly while output streams and never
      // contains real form fields, so scanning it here would be wasted
      // work on exactly the hot path this app can't afford to slow down.
      if (m.target instanceof Element && m.target.closest(".xterm")) continue;
      for (const node of m.addedNodes) {
        hardenTree(node);
      }
    }
  });

  observer.observe(document.body, { childList: true, subtree: true });
  return () => observer.disconnect();
}
