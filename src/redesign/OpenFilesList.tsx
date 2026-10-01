// Created by Claude — Classification: INTERNAL
//
// Files rail: the left column listing every OPEN file (the Agents column's twin).
// Click shows the file, × closes it (an unsaved file asks first — the caller's
// closeTerminal does that), a dot marks unsaved changes. The file tree stays below
// (filesSection) so more files can be opened from here.

import type { ReactNode } from "react";
import type { OpenFileVM } from "./types";
import { FileCodeIcon, FileImageIcon, FileMarkdownIcon, FilePdfIcon } from "./icons";

export interface OpenFilesListProps {
  files: OpenFileVM[];
  selectedKey: string | null;
  onSelect: (key: string) => void;
  onClose: (key: string) => void;
  width?: number;
  resizeHandle?: ReactNode;
  filesSection?: ReactNode;
  /** The tree below is set to fill the column: the list then takes only what it needs. */
  filesFill?: boolean;
}

const KIND = {
  code: { Icon: FileCodeIcon, label: "Code" },
  markdown: { Icon: FileMarkdownIcon, label: "Markdown" },
  image: { Icon: FileImageIcon, label: "Image" },
  pdf: { Icon: FilePdfIcon, label: "PDF" },
} as const;

export function OpenFilesList({ files, selectedKey, onSelect, onClose, width, resizeHandle, filesSection, filesFill }: OpenFilesListProps) {
  return (
    <aside
      aria-label="Open files"
      className="rd-agent-list"
      data-custom={width !== undefined ? "" : undefined}
      style={{
        position: "relative",
        width: width ?? 296,
        flexShrink: 0,
        display: "flex",
        flexDirection: "column",
        borderRight: "1px solid var(--border)",
        background: "var(--bg-panel)",
        minHeight: 0,
      }}
    >
      {resizeHandle}
      <div style={{ display: "flex", alignItems: "center", padding: "16px 16px 10px", minHeight: 30 }}>
        <h2 style={{ margin: 0, fontSize: 14, fontWeight: 600 }}>
          Files <span style={{ color: "var(--text-muted)", fontWeight: 400 }}>{files.length}</span>
        </h2>
      </div>

      <div
        role="list"
        aria-label="Open files"
        style={{
          flex: filesFill ? "0 1 auto" : "1 1 0",
          maxHeight: filesFill ? "50%" : undefined,
          overflow: "auto",
          padding: "0 10px 8px",
          display: "flex",
          flexDirection: "column",
          gap: 2,
          minHeight: filesSection && !filesFill ? 120 : 0,
        }}
      >
        {files.length === 0 ? (
          <div style={{ padding: "8px 6px", fontSize: 12, lineHeight: 1.5, color: "var(--text-muted)" }}>
            No open files. Pick one in the tree below, or with ⌘K.
          </div>
        ) : (
          files.map((f) => <OpenFileRow key={f.key} file={f} selected={f.key === selectedKey} onSelect={onSelect} onClose={onClose} />)
        )}
      </div>

      {filesSection}
    </aside>
  );
}

function OpenFileRow({ file, selected, onSelect, onClose }: { file: OpenFileVM; selected: boolean; onSelect: (key: string) => void; onClose: (key: string) => void }) {
  const { Icon, label } = KIND[file.kind];
  return (
    <div
      role="listitem"
      className="rd-open-file"
      data-selected={selected ? "" : undefined}
      style={{
        position: "relative",
        display: "flex",
        alignItems: "center",
        borderRadius: 8,
        border: `1px solid ${selected ? "var(--border-selected)" : "transparent"}`,
        background: selected ? "var(--bg-selected)" : "transparent",
      }}
    >
      <button
        type="button"
        onClick={() => onSelect(file.key)}
        onAuxClick={(e) => {
          if (e.button === 1) onClose(file.key); // middle-click closes, like browser tabs
        }}
        aria-current={selected ? "true" : undefined}
        title={`${file.dir}/${file.name}`}
        style={{
          flex: 1,
          minWidth: 0,
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "7px 4px 7px 10px",
          border: "none",
          background: "transparent",
          color: "var(--text)",
          textAlign: "left",
        }}
      >
        <Icon aria-label={label} style={{ flexShrink: 0, color: "var(--text-muted)" }} />
        <span style={{ display: "flex", flexDirection: "column", minWidth: 0, gap: 1 }}>
          <span className="rd-ellipsis" style={{ fontSize: 13, fontWeight: selected ? 600 : 400 }}>
            {file.name}
          </span>
          <span className="rd-ellipsis" style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)" }}>
            {file.dir}
          </span>
        </span>
      </button>
      {file.dirty && (
        <span title="Unsaved changes" aria-label="Unsaved changes" style={{ width: 7, height: 7, borderRadius: 4, background: "var(--warning)", flexShrink: 0, marginRight: 2 }} />
      )}
      <button
        type="button"
        aria-label={`Close ${file.name}`}
        title="Close"
        onClick={() => onClose(file.key)}
        className="rd-open-file-close"
        style={{
          width: 24,
          height: 24,
          marginRight: 6,
          flexShrink: 0,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          border: "none",
          borderRadius: 6,
          background: "transparent",
          color: "var(--text-muted)",
          fontSize: 15,
          lineHeight: 1,
        }}
      >
        ×
      </button>
    </div>
  );
}
