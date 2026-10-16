// Created by Claude — Classification: INTERNAL
//
// Local file versions + the auto-save setting (docs/prd-file-versions.md).
// Versions live in ~/.claude/muya-file-history (src-tauri/src/file_history.rs).
import { invoke } from "@tauri-apps/api/core";
import type { ReviewSource } from "../components/ReviewChanges";

export type VersionKind = "opened" | "draft" | "saved" | "before-restore";

export interface FileVersion {
  id: string;
  /** Unix milliseconds. */
  at: number;
  size: number;
  kind: VersionKind;
}

/** Fired on window with `{ path }` after a new version was stored. */
export const VERSIONS_EVENT = "muya:file-versions-changed";

export const KIND_LABEL: Record<VersionKind, string> = {
  opened: "opened",
  draft: "unsaved edit",
  saved: "saved",
  "before-restore": "before restore",
};

/** Store `content` as a version of `path` (the backend skips unchanged text). */
export async function snapshotVersion(path: string, content: string, kind: VersionKind): Promise<void> {
  try {
    const v = await invoke<FileVersion | null>("file_history_snapshot", { path, content, kind });
    if (v) window.dispatchEvent(new CustomEvent(VERSIONS_EVENT, { detail: { path } }));
  } catch {
    // history is best-effort: never block editing or saving on it
  }
}

export function listVersions(path: string): Promise<FileVersion[]> {
  return invoke<FileVersion[]>("file_history_list", { path });
}

/** "14:05:09" today, "Oct 15 14:05" otherwise. */
export function versionTime(at: number, now = Date.now()): string {
  const d = new Date(at);
  const time = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  if (new Date(now).toDateString() === d.toDateString()) return time;
  return `${d.toLocaleDateString([], { month: "short", day: "numeric" })} ${time.slice(0, 5)}`;
}

/** The Review dialog over a file's versions: each version vs the file on disk now,
 *  with Restore. */
export function versionsSource(path: string, versions: FileVersion[], onRestored?: () => void): ReviewSource {
  const name = path.split("/").pop() ?? path;
  return {
    title: `Versions · ${name}`,
    files: versions.map((v) => ({ code: v.kind === "saved" ? "S" : v.kind === "draft" ? "E" : v.kind === "opened" ? "O" : "R", path: `${versionTime(v.at)} · ${KIND_LABEL[v.kind]}`, langPath: path, id: v.id })),
    unit: "Version",
    labels: { before: "this version", after: "file now" },
    load: async (f) => {
      const [original, modified] = await Promise.all([
        invoke<string>("file_history_read", { path, id: f.id }),
        invoke<string>("read_file", { path }).catch(() => ""),
      ]);
      return { original, modified };
    },
    action: {
      label: "Restore this version",
      run: async (f) => {
        const [old, now] = await Promise.all([
          invoke<string>("file_history_read", { path, id: f.id }),
          invoke<string>("read_file", { path }).catch(() => ""),
        ]);
        await snapshotVersion(path, now, "before-restore");
        await invoke("write_file", { path, content: old });
        await snapshotVersion(path, old, "saved");
        onRestored?.();
      },
    },
  };
}

// ── Auto-save (Settings → Editor) ──────────────────────────────────────────

export const AUTO_SAVE_KEY = "muya.autoSave";
export const AUTO_SAVE_EVENT = "muya:auto-save-changed";
export const AUTO_SAVE_MS = 1000;
export const DRAFT_MS = 3000;

export function loadAutoSave(): boolean {
  try {
    return localStorage.getItem(AUTO_SAVE_KEY) === "1";
  } catch {
    return false;
  }
}

export function saveAutoSave(on: boolean): void {
  try {
    if (on) localStorage.setItem(AUTO_SAVE_KEY, "1");
    else localStorage.removeItem(AUTO_SAVE_KEY);
  } catch {
    /* storage unavailable — the switch just won't persist */
  }
  window.dispatchEvent(new Event(AUTO_SAVE_EVENT));
}
