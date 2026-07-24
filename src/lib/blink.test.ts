import { describe, it, expect } from "vitest";
import { nextAcked, deriveBlinkKeys } from "./blink";

const S = (...xs: string[]) => new Set(xs);

describe("blink: needs-decision until the operator opens the tab", () => {
  it("a waiting tab blinks while it is neither active nor acknowledged", () => {
    const blink = deriveBlinkKeys(S("a", "b"), "c", S());
    expect([...blink].sort()).toEqual(["a", "b"]);
  });

  it("the active tab never blinks (you're already on it)", () => {
    expect(deriveBlinkKeys(S("a"), "a", S()).has("a")).toBe(false);
  });

  it("opening a waiting tab acknowledges it, and it stops blinking even after switching away", () => {
    let acked = S();
    const waiting = S("a");
    // Operator opens the waiting tab → acknowledged.
    acked = nextAcked(acked, "a", waiting);
    expect(acked.has("a")).toBe(true);
    // Now switch to another tab; "a" is still waiting but must NOT blink again.
    expect(deriveBlinkKeys(waiting, "b", acked).has("a")).toBe(false);
  });

  it("re-blinks on the NEXT prompt: leaving the waiting set clears the ack", () => {
    let acked = S("a");
    // The prompt was answered → "a" is no longer waiting → ack cleared.
    acked = nextAcked(acked, "b", S());
    expect(acked.has("a")).toBe(false);
    // A new prompt puts "a" back into waiting → it blinks again.
    expect(deriveBlinkKeys(S("a"), "b", acked).has("a")).toBe(true);
  });
});
