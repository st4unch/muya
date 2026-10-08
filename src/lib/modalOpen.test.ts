// Created by Claude — Classification: INTERNAL
import { afterEach, describe, expect, it } from "vitest";
import { appModalOpen } from "./modalOpen";

afterEach(() => {
  document.body.innerHTML = "";
});

describe("appModalOpen", () => {
  it("is false with no modal", () => {
    document.body.innerHTML = `<div data-terminal-host="t1"><textarea></textarea></div>`;
    expect(appModalOpen()).toBe(false);
  });

  it("sees an app dialog", () => {
    document.body.innerHTML = `<div role="dialog">Settings</div>`;
    expect(appModalOpen()).toBe(true);
  });

  it("sees the full-screen backdrop convention", () => {
    document.body.innerHTML = `<div class="fixed inset-0 z-50"></div>`;
    expect(appModalOpen()).toBe(true);
  });

  // The reported bug: ⌘F in an open file leaves Monaco's find box (role="dialog")
  // in the page; the file sits in its host while the operator is back on a terminal.
  it("ignores Monaco's find box inside a file viewer host", () => {
    document.body.innerHTML = `
      <div aria-hidden="true"><div data-terminal-host="edit:/x/notes.ts">
        <div class="monaco-editor"><div class="editor-widget find-widget" role="dialog"></div></div>
      </div></div>`;
    expect(appModalOpen()).toBe(false);
  });

  it("ignores a dialog under a hidden page", () => {
    document.body.innerHTML = `<div class="hidden"><div role="dialog"></div></div>`;
    expect(appModalOpen()).toBe(false);
  });

  it("still sees an app dialog while a file viewer holds a find box", () => {
    document.body.innerHTML = `
      <div data-terminal-host="edit:/x"><div role="dialog" class="find-widget"></div></div>
      <div role="dialog">Unsaved changes</div>`;
    expect(appModalOpen()).toBe(true);
  });
});
