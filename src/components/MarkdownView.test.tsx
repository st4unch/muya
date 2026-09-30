// Created by Claude — Classification: INTERNAL
import { describe, it, expect, vi } from "vitest";
import { render, waitFor } from "@testing-library/react";

// A malicious markdown file: every classic way to run script through rendered HTML.
const EVIL = [
  "# Title",
  "<script>window.__pwned = 1</script>",
  '<img src=x onerror="window.__pwned = 2">',
  "[click](javascript:window.__pwned=3)",
  '<svg><g onload="window.__pwned=4"></g></svg>',
  '<a href="javascript:window.__pwned=5">x</a>',
  "<iframe src=\"javascript:window.__pwned=6\"></iframe>",
].join("\n\n");

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(async () => EVIL) }));

import MarkdownView from "./MarkdownView";

// MarkdownView is what renders .md files in the app (MarkdownViewer.tsx is not used).
// It sanitizes with DOMPurify, which was bumped 3.2.7 → 3.4.x for published XSS
// advisories affecting default sanitize() — this pins the behaviour end to end.
describe("MarkdownView sanitizes untrusted markdown", () => {
  it("renders the text but no executable markup", async () => {
    const { container } = render(<MarkdownView filePath="/tmp/evil.md" />);
    await waitFor(() => expect(container.querySelector("h1")?.textContent).toBe("Title"));
    const html = container.innerHTML;
    expect(container.querySelector("script, iframe")).toBeNull();
    expect(html).not.toMatch(/\son\w+=/i); // no inline event handlers survive
    expect(html).not.toMatch(/javascript:/i);
    expect((window as unknown as { __pwned?: number }).__pwned).toBeUndefined();
  });
});
