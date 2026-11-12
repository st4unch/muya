// Created by Claude — Classification: INTERNAL
//
// Large-file policy (docs/prd-large-file-open.md). Pure: the viewers feed it what the
// backend `file_probe` reported and act on the answer.

export const MB = 1024 * 1024;
/** From here the editor drops tokenization, minimap, wrap, folding and diff. */
export const LARGE_BYTES = 1 * MB;
/** Above this a file is not loaded until the operator asks; "Open anyway" shows the head. */
export const PROMPT_BYTES = 8 * MB;
/** Largest chunk of a file "Open anyway" reads (read-only). */
export const HEAD_BYTES = 8 * MB;
/** Markdown above this is not parsed/sanitised/injected (that froze the window). */
export const MD_RENDER_MAX = 512 * 1024;

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
