import { describe, it, expect } from "vitest";
import { mdToHtml } from "./MarkdownViewer";

// Security regression tests for the markdown → HTML renderer, which feeds
// dangerouslySetInnerHTML. PRD files come from ANY workspace the user adds,
// so untrusted markup must never produce executable HTML.
describe("mdToHtml — XSS hardening", () => {
  it("neutralizes raw <script> tags", () => {
    const out = mdToHtml("hello <script>alert(1)</script> world");
    expect(out).not.toContain("<script>");
    expect(out).toContain("&lt;script&gt;");
  });

  it("neutralizes <img onerror> injection", () => {
    const out = mdToHtml('![x](y) <img src=x onerror="alert(1)">');
    expect(out).not.toMatch(/<img[^>]*onerror/i);
    expect(out).toContain("&lt;img");
  });

  it("blocks javascript: link hrefs", () => {
    const out = mdToHtml("[click](javascript:alert(1))");
    expect(out).not.toMatch(/href="javascript:/i);
    expect(out).toContain('href="#"');
  });

  it("blocks data: link hrefs", () => {
    const out = mdToHtml("[x](data:text/html,<script>alert(1)</script>)");
    expect(out).not.toMatch(/href="data:/i);
  });

  it("escapes HTML inside fenced code blocks", () => {
    const out = mdToHtml("```\n<script>alert(1)</script>\n```");
    expect(out).not.toContain("<script>");
    expect(out).toContain("&lt;script&gt;");
  });

  it("still renders safe markdown (headings, bold, safe links)", () => {
    const out = mdToHtml("# Title\n\n**bold** and [ok](https://example.com)");
    expect(out).toContain("<h1>Title</h1>");
    expect(out).toContain("<strong>bold</strong>");
    expect(out).toContain('href="https://example.com"');
  });
});
