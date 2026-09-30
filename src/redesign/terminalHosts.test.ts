import { describe, expect, it } from "vitest";
import { adoptHosts, createHost, DEFAULT_TERM_PAD } from "./terminalHosts";

function setup() {
  document.body.innerHTML = "";
  const pool = document.createElement("div");
  const screen = document.createElement("div");
  document.body.append(pool, screen);
  return { pool, screen };
}

const slot = (key: string, pad?: string) => {
  const el = document.createElement("div");
  el.dataset.terminalSlot = key;
  if (pad) el.dataset.terminalPad = pad;
  return el;
};

describe("adoptHosts", () => {
  it("moves a host into its slot and back to the pool — the same element, never a copy", () => {
    const { pool, screen } = setup();
    const host = createHost("a");
    const hosts = new Map([["a", host]]);
    const s = slot("a");
    screen.append(s);
    expect([...adoptHosts(hosts, pool)]).toEqual(["a"]);
    expect(host.parentElement).toBe(s);
    s.remove(); // the screen unmounts (Control -> Grid)
    expect(adoptHosts(hosts, pool).size).toBe(0);
    expect(host.parentElement).toBe(pool);
    const s2 = slot("a");
    screen.append(s2);
    adoptHosts(hosts, pool);
    expect(host.parentElement).toBe(s2);
    expect(document.querySelectorAll('[data-terminal-host="a"]').length).toBe(1);
  });

  it("parks hosts without a slot, ignores slots without a host, and takes the first slot per key", () => {
    const { pool, screen } = setup();
    const hosts = new Map([["a", createHost("a")], ["b", createHost("b")]]);
    const first = slot("a");
    const second = slot("a");
    screen.append(first, second, slot("none"));
    adoptHosts(hosts, pool);
    expect(hosts.get("a")!.parentElement).toBe(first);
    expect(hosts.get("b")!.parentElement).toBe(pool);
  });

  it("hands the slot's padding to the terminal through --term-pad", () => {
    const { pool, screen } = setup();
    const host = createHost("a");
    const hosts = new Map([["a", host]]);
    screen.append(slot("a", "14px 16px"));
    adoptHosts(hosts, pool);
    expect(host.style.getPropertyValue("--term-pad")).toBe("14px 16px");
    screen.innerHTML = "";
    screen.append(slot("a"));
    adoptHosts(hosts, pool);
    expect(host.style.getPropertyValue("--term-pad")).toBe(DEFAULT_TERM_PAD);
  });
});
