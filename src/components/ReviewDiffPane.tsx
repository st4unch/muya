// Created by Claude — Classification: INTERNAL
//
// Read-only side-by-side diff for the Review changes dialog. Lazy-loaded so Monaco
// stays out of the main bundle until a review is opened.
import { DiffEditor } from "@monaco-editor/react";
import "./monacoSetup";
import { langFromPath } from "../lib/format";

export default function ReviewDiffPane({ path, original, modified, theme }: { path: string; original: string; modified: string; theme: "light" | "dark" }) {
  return (
    <DiffEditor
      keepCurrentOriginalModel
      keepCurrentModifiedModel
      original={original}
      modified={modified}
      theme={theme === "dark" ? "vs-dark" : "light"}
      language={langFromPath(path)}
      loading={<div style={{ padding: 16, fontSize: 12, color: "var(--text-muted)" }}>diff…</div>}
      options={{
        fontSize: 12,
        fontFamily: '"JetBrains Mono", ui-monospace, monospace',
        renderSideBySide: true,
        readOnly: true,
        minimap: { enabled: false },
        automaticLayout: true,
        scrollBeyondLastLine: false,
      }}
    />
  );
}
