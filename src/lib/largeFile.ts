// Created by Claude — Classification: INTERNAL
//
// Large-file policy (docs/prd-large-file-open.md). Pure: the viewers feed it what the
// backend `file_probe` reported and act on the answer.

export const MB = 1024 * 1024;
// Thresholds come from measurements (tools/largefile-perf, docs/large-file-measurements.md):
// Monaco with EVERY feature on opens 50 MB JSON/log/TS/Markdown in < 0.5 s, keeps typing
// < 100 ms and scrolling at 60 fps; even 200 MB opens in < 2 s. Native (Swift) uses the SAME
// numbers (native/app/Sources/Logic/FileLogic.swift LargeFile) — change them together.
/** From here the editor drops tokenization, minimap, wrap, folding and diff (still editable). */
export const LARGE_BYTES = 50 * MB;
/** Above this a file is not loaded until the operator asks; "Open anyway" shows the head. */
export const PROMPT_BYTES = 128 * MB;
/** Largest chunk of a file "Open anyway" reads (read-only). Rust caps read_file_prefix at 16 MB. */
export const HEAD_BYTES = 16 * MB;
/** Markdown above this is not parsed/sanitised/injected: marked + DOMPurify + layout cost
 *  ~0.4 s per MB on the main thread here (1 MB = 0.4 s, 8 MB = 3.1 s); Native's renderer ~0.75 s/MB. */
export const MD_RENDER_MAX = 1 * MB;
/** A single line longer than this (a minified bundle on one line) gets the large-file
 *  treatment whatever the file size: tokenizing/validating one 5 MB line costs 10 s of CPU,
 *  10 MB costs 25 s, and typing lags (140 ms at 50 MB). */
export const LONG_LINE_CHARS = 2_000_000;

/** Length of the longest line (one pass, no allocation). */
export function longestLine(text: string): number {
  let max = 0;
  let from = 0;
  for (;;) {
    const nl = text.indexOf("\n", from);
    const end = nl === -1 ? text.length : nl;
    if (end - from > max) max = end - from;
    if (nl === -1) return max;
    from = nl + 1;
  }
}

export interface FileProbe {
  size: number;
  /** A NUL byte in the first 8 KB: not text. */
  binary: boolean;
}

export type OpenMode =
  | "normal" // full editor / rendered markdown
  | "large" // editable, but plain text with the expensive features off
  | "prompt" // too big to load unasked
  | "binary"; // never loaded as text

export function decideOpen(probe: FileProbe, opts: { markdown?: boolean } = {}): OpenMode {
  if (probe.binary) return "binary";
  if (probe.size > PROMPT_BYTES) return "prompt";
  if (probe.size >= LARGE_BYTES) return "large";
  if (opts.markdown && probe.size > MD_RENDER_MAX) return "large";
  return "normal";
}

/** Whether a rendered markdown preview is allowed for this probe. */
export function canRenderMarkdown(probe: FileProbe): boolean {
  return decideOpen(probe, { markdown: true }) === "normal";
}

export function formatSize(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < MB) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / MB).toFixed(1)} MB`;
}

/** Monaco options that keep a big file responsive. Spread over the normal options. */
export const LARGE_EDITOR_OPTIONS = {
  minimap: { enabled: false },
  wordWrap: "off" as const,
  folding: false,
  bracketPairColorization: { enabled: false },
  guides: { bracketPairs: false, indentation: false, highlightActiveIndentation: false },
  matchBrackets: "never" as const,
  occurrencesHighlight: "off" as const,
  selectionHighlight: false,
  renderWhitespace: "none" as const,
  renderLineHighlight: "none" as const,
  links: false,
  colorDecorators: false,
  codeLens: false,
  hover: { enabled: false },
  quickSuggestions: false,
  parameterHints: { enabled: false },
  suggestOnTriggerCharacters: false,
  stickyScroll: { enabled: false },
  largeFileOptimizations: true,
  maxTokenizationLineLength: 2000,
  scrollBeyondLastLine: false,
};
