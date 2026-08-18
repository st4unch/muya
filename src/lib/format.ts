/** Pure, testable formatting helpers shared across components. */

/** Relative time from a ms-epoch timestamp, e.g. "just now" / "5m ago" / "2h ago". */
export function relTime(ms: number, now: number = Date.now()): string {
  if (!ms) return "—";
  const m = Math.floor((now - ms) / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

/** Collapse the user's home prefix to `~` for display. */
export function shortCwd(p: string): string {
  return p.replace(/^\/Users\/[^/]+/, "~");
}

const LANG: Record<string, string> = {
  ts: "typescript", tsx: "typescript", js: "javascript", jsx: "javascript",
  json: "json", rs: "rust", md: "markdown", py: "python", css: "css",
  scss: "scss", html: "html", sh: "shell", bash: "shell", toml: "ini",
  yaml: "yaml", yml: "yaml", go: "go", sql: "sql",
};

/** Monaco language id from a file path's extension (undefined → plaintext). */
export function langFromPath(p: string): string | undefined {
  return LANG[p.split(".").pop()?.toLowerCase() ?? ""];
}

/** Which viewer `openFile()` should route a path to (PRD file-viewer-dispatcher).
 *  `read_file` requires UTF-8 text, so images/PDFs need their own tab kind instead
 *  of failing into Monaco's error state. Order matters only in that each pattern
 *  is mutually exclusive by extension. */
export function viewerKindFor(p: string): "mdview" | "imgview" | "pdfview" | "editor" {
  if (/\.mdx?$/i.test(p)) return "mdview";
  if (/\.(png|jpe?g|gif|webp|bmp|ico|svg)$/i.test(p)) return "imgview";
  if (/\.pdf$/i.test(p)) return "pdfview";
  return "editor";
}
