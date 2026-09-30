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

/** Move every host into the slot that names it, or back into the pool.
 *  Returns the keys that ended up in a slot (i.e. are on screen). */
export function adoptHosts(hosts: Map<string, HTMLElement>, pool: HTMLElement, root: ParentNode = document): Set<string> {
  const slots = new Map<string, HTMLElement>();
  root.querySelectorAll<HTMLElement>("[data-terminal-slot]").forEach((el) => {
    const key = el.dataset.terminalSlot;
    if (key && hosts.has(key) && !slots.has(key)) slots.set(key, el);
  });
  const adopted = new Set<string>();
  for (const [key, host] of hosts) {
    const slot = slots.get(key);
    const target = slot ?? pool;
    if (host.parentElement !== target) target.appendChild(host);
    if (slot) {
      adopted.add(key);
      if (getComputedStyle(slot).position === "static") slot.style.position = "relative";
      host.style.setProperty("--term-pad", slot.dataset.terminalPad ?? DEFAULT_TERM_PAD);
    }
  }
  return adopted;
}
