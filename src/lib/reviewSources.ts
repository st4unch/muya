// Created by Claude — Classification: INTERNAL
//
// Where the Review changes dialog gets its files and both sides of each diff
// (docs/prd-review-changes.md).
import { invoke } from "@tauri-apps/api/core";
import type { ReviewFile, ReviewSource } from "../components/ReviewChanges";

const trimSlash = (p: string) => p.replace(/\/+$/, "");

/** `abs` relative to `root` (kept as-is when outside it). Folders keep their trailing "/". */
export function relativeTo(root: string, abs: string): string {
  const r = trimSlash(root);
  return abs.startsWith(r + "/") ? abs.slice(r.length + 1) : abs;
}

/** Uncommitted changes of the repo at `root`: HEAD vs the file on disk. */
export async function workingTreeSource(root: string, title: string): Promise<ReviewSource> {
  const pairs = await invoke<[string, string][]>("git_status", { root });
  const files: ReviewFile[] = pairs.map(([abs, code]) => ({ code, path: relativeTo(root, abs), abs }));
  return {
    title,
    files,
    load: async (f) => {
      const abs = f.abs ?? `${trimSlash(root)}/${f.path}`;
      const [original, modified] = await Promise.all([
        invoke<string>("read_head_file", { path: abs }).catch(() => ""),
        f.code === "D" ? Promise.resolve("") : invoke<string>("read_file", { path: abs }),
      ]);
      return { original, modified };
    },
  };
}

/** A branch's changes since it left `base`: merge-base vs branch tip. */
export function branchSource(repo: string, base: string, branch: string, paths: string[]): ReviewSource {
  return {
    title: `${branch} vs ${base}`,
    files: paths.map((path) => ({ code: "M", path })),
    load: async (f) => {
      const [original, modified] = await invoke<[string, string]>("git_branch_file_pair", { repo, base, branch, path: f.path });
      return { original, modified };
    },
  };
}
