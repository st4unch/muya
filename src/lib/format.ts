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

/**
 * A Monaco model path that can never be misread as a URI scheme.
 *
 * `@monaco-editor/react`'s `path` prop becomes a model URI via `Uri.parse`. Handing
 * it a raw filename means anything before a `:` is taken as the scheme — and a
 * scheme containing a space or non-ASCII character makes Monaco throw
 * `[UriError]: Scheme contains illegal characters`, which (with no error boundary)
 * unmounted the whole app into a black window. Reported 2026-08-26 opening a .csv.
 *
 * This bites on macOS especially: a filename shown as `Report 2026/08.csv` in Finder
 * is stored on disk as `Report 2026:08.csv`, so ordinary downloaded files hit it.
 *
 * Percent-encoding leaves `.` untouched, so the extension survives — Monaco still
 * infers the language from it. Encoding the FULL path (not just the basename) also
 * fixes a latent collision: two same-named files in different folders previously
 * shared one model path, and so shared an undo stack.
 */
export function monacoModelPath(fullPath: string): string {
  return encodeURIComponent(fullPath);
}
