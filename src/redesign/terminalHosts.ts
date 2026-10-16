// Created by Claude — Classification: INTERNAL
//
// The terminal pool. Every open terminal (and every open file viewer) lives in ONE host
// element, created once and rendered into via a React portal — so there is exactly one
// xterm and one PTY per tab, whichever screen is showing. Screens only render empty
// `[data-terminal-slot=<tabKey>]` placeholders; adoptHosts() moves each host into its
// slot (appendChild) and parks the rest in the hidden pool. Never unmount, never respawn.

export const DEFAULT_TERM_PAD = "20px 28px";

/** Style for the pool element. NOT display:none: a terminal parked in a 0×0 box fits to a
 *  handful of columns, the PTY is told that size, and the screen parser (permission
 *  dialogs, spinner, mode footer of agents nobody is looking at) then reads garbage.
 *  Off-screen at a normal terminal size keeps every parked terminal readable. */
export const POOL_STYLE = {
  position: "fixed",
  left: -20000,
  top: 0,
  width: 1000,
  height: 640,
  overflow: "hidden",
  visibility: "hidden",
  pointerEvents: "none",
} as const;

export function createHost(key: string): HTMLDivElement {
  const host = document.createElement("div");
  host.dataset.terminalHost = key;
  // Always absolutely fill whatever holds it: a slot (made `position: relative`) or the pool.
  host.style.cssText = "position:absolute;inset:0;min-width:0;min-height:0;";
  return host;
}

/** Move a host, telling whatever has the keyboard inside it.
 *
 *  WebKit (the macOS webview) fires no blur when a focused element is moved in the DOM:
 *  focus silently drops to <body> while Monaco and xterm still believe they have it.
 *  Monaco then ignored the next click into the file (it thought it was focused), and an
 *  IME composition left open (⌥ accents, press-and-hold) never ended, so it dropped
 *  every key and Enter until the file was closed — only paste got through. Blur first so
 *  they hear about it, and hand the focus back when the host is still on screen (its
 *  slot was only re-created). */
function moveHost(host: HTMLElement, target: HTMLElement, onScreen: boolean): void {
  const doc = host.ownerDocument;
  const active = doc.activeElement;
  let had: HTMLElement | null = null;
  if (active instanceof HTMLElement && host.contains(active)) {
    had = active;
    active.blur();
  } else if (lastFocus.el && host.contains(lastFocus.el)) {
    // React already removed the old slot, and the focus went with it, unannounced.
    had = lastFocus.el;
    had.dispatchEvent(new FocusEvent("blur"));
    had.dispatchEvent(new FocusEvent("focusout", { bubbles: true }));
  }
  lastFocus.el = null;
  target.appendChild(host);
  const free = !doc.activeElement || doc.activeElement === doc.body;
  if (had && onScreen && free) had.focus({ preventScroll: true });
}

/** The element holding the keyboard, as long as it has not announced losing it — so a
 *  focus that vanished with a removed node (no blur in WebKit) can still be found. */
const lastFocus: { el: HTMLElement | null; doc: Document | null } = { el: null, doc: null };
function trackFocus(doc: Document): void {
  if (lastFocus.doc === doc) return;
  lastFocus.doc = doc;
  const a = doc.activeElement;
  lastFocus.el = a instanceof HTMLElement && a !== doc.body ? a : null;
  doc.addEventListener("focusin", (e) => { lastFocus.el = e.target instanceof HTMLElement ? e.target : null; }, true);
  doc.addEventListener("focusout", (e) => { if (e.target === lastFocus.el) lastFocus.el = null; }, true);
}

/** Move every host into the slot that names it, or back into the pool.
 *  Returns the keys that ended up in a slot (i.e. are on screen). */
export function adoptHosts(hosts: Map<string, HTMLElement>, pool: HTMLElement, root: ParentNode = document): Set<string> {
  trackFocus(pool.ownerDocument);
  const slots = new Map<string, HTMLElement>();
  root.querySelectorAll<HTMLElement>("[data-terminal-slot]").forEach((el) => {
    const key = el.dataset.terminalSlot;
    if (key && hosts.has(key) && !slots.has(key)) slots.set(key, el);
  });
  const adopted = new Set<string>();
  for (const [key, host] of hosts) {
    const slot = slots.get(key);
    const target = slot ?? pool;
    if (host.parentElement !== target) moveHost(host, target, !!slot);
    if (slot) {
      adopted.add(key);
      if (getComputedStyle(slot).position === "static") slot.style.position = "relative";
      host.style.setProperty("--term-pad", slot.dataset.terminalPad ?? DEFAULT_TERM_PAD);
    }
  }
  return adopted;
}
