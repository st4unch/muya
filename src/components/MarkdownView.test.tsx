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

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

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

describe("MarkdownView links and stripped tags", () => {
  it("opens http(s) externally, ignores javascript:, strips form/style", async () => {
    const md = [
      "# T",
      "[ext](https://example.com/x)",
      '<a href="javascript:alert(1)">js</a>',
      "<form action=\"https://evil\"><input name=a></form>",
      "<style>body{display:none}</style>",
    ].join("\n\n");
    const core = await import("@tauri-apps/api/core");
    vi.mocked(core.invoke).mockResolvedValueOnce(md);
    const opener = await import("@tauri-apps/plugin-opener");
    const { fireEvent } = await import("@testing-library/react");
    const { container } = render(<MarkdownView filePath="/tmp/l.md" />);
    await waitFor(() => expect(container.querySelector("h1")).not.toBeNull());
    expect(container.querySelector("form, style, input")).toBeNull();
    const ext = container.querySelector('a[href^="https://example.com"]') as HTMLAnchorElement;
    expect(ext.getAttribute("rel")).toBe("noopener noreferrer");
    const notPrevented = fireEvent.click(ext);
    expect(notPrevented).toBe(false); // preventDefault was called
    expect(opener.openUrl).toHaveBeenCalledWith("https://example.com/x");
    vi.mocked(opener.openUrl).mockClear();
    const js = Array.from(container.querySelectorAll("a")).find((a) => a.textContent === "js");
    if (js) fireEvent.click(js);
    expect(opener.openUrl).not.toHaveBeenCalled();
  });
});
