import { describe, it, expect, afterEach } from "vitest";
import { installNoAutocorrect } from "./noAutocorrect";

afterEach(() => {
  document.body.innerHTML = "";
});

describe("noAutocorrect: macOS WKWebView autocorrect must never mutate typed text", () => {
  it("hardens fields already in the DOM at install time", () => {
    document.body.innerHTML = `<input id="a" /><textarea id="b"></textarea>`;
    const stop = installNoAutocorrect();
    const input = document.getElementById("a")!;
    const textarea = document.getElementById("b")!;
    expect(input.getAttribute("autocorrect")).toBe("off");
    expect(input.getAttribute("autocapitalize")).toBe("off");
    expect(input.getAttribute("spellcheck")).toBe("false");
    expect(textarea.getAttribute("autocorrect")).toBe("off");
    stop();
  });

  it("hardens a field mounted later (modal opened after install)", async () => {
    const stop = installNoAutocorrect();
    const modal = document.createElement("div");
    modal.innerHTML = `<input id="c" />`;
    document.body.appendChild(modal);

    // MutationObserver callbacks fire on a microtask.
    await Promise.resolve();
    await new Promise((r) => setTimeout(r, 0));

    const input = document.getElementById("c")!;
    expect(input.getAttribute("autocorrect")).toBe("off");
    expect(input.getAttribute("autocapitalize")).toBe("off");
    stop();
  });

  it("does not touch non-field elements", () => {
    document.body.innerHTML = `<div id="d"></div>`;
    const stop = installNoAutocorrect();
    const div = document.getElementById("d")!;
    expect(div.getAttribute("autocorrect")).toBeNull();
    stop();
  });

  it("skips scanning inside a live xterm terminal subtree", async () => {
    const term = document.createElement("div");
    term.className = "xterm";
    document.body.appendChild(term);
    const stop = installNoAutocorrect();

    const row = document.createElement("div");
    row.innerHTML = `<input id="e" />`; // xterm never really does this, but prove the skip doesn't crash/miss silently by design
    term.appendChild(row);

    await Promise.resolve();
    await new Promise((r) => setTimeout(r, 0));

    // The skip is intentional: fields inside .xterm are not hardened because
    // xterm never mounts real form fields there — documenting the tradeoff.
    const input = document.getElementById("e")!;
    expect(input.getAttribute("autocorrect")).toBeNull();
    stop();
  });

  it("stop() disconnects the observer — later mutations are no longer hardened", async () => {
    const stop = installNoAutocorrect();
    stop();

    const input = document.createElement("input");
    input.id = "f";
    document.body.appendChild(input);

    await Promise.resolve();
    await new Promise((r) => setTimeout(r, 0));

    expect(input.getAttribute("autocorrect")).toBeNull();
  });
});
