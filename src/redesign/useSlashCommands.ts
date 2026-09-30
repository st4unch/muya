// Created by Claude — Classification: INTERNAL
//
// Slash commands for the composer popover: the captured built-ins (slashBuiltins.ts)
// merged with what the Rust `list_slash_commands` finds on disk (project / user
// commands, skills). Fetched each time the popover opens (`enabled`) so a command the
// user just added shows up; built-ins are available immediately.

import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { builtinsFor } from "./slashBuiltins";
import type { SlashAgent } from "./slashBuiltins";

export type SlashSource = "builtin" | "project" | "user" | "skill";

export interface SlashItem {
  name: string;
  description: string;
  source: SlashSource;
}

interface DiskCommand {
  name: string;
  description: string;
  source: "project" | "user" | "skill";
}

const SOURCE_RANK: Record<SlashSource, number> = { project: 0, user: 1, skill: 2, builtin: 3 };

/** Built-ins first, then disk items; a custom command that shadows a built-in keeps
 *  the built-in (it is what the CLI runs first), duplicates within disk keep the first. */
export function mergeSlashItems(agent: SlashAgent, disk: DiskCommand[]): SlashItem[] {
  const out: SlashItem[] = builtinsFor(agent).map((b) => ({ ...b, source: "builtin" as const }));
  const seen = new Set(out.map((i) => i.name));
  const extra = [...disk].sort((a, b) => SOURCE_RANK[a.source] - SOURCE_RANK[b.source]);
  for (const d of extra) {
    if (seen.has(d.name)) continue;
    seen.add(d.name);
    out.push({ name: d.name, description: d.description, source: d.source });
  }
  return out;
}

export function useSlashCommands(agent: SlashAgent, cwd: string | undefined, enabled: boolean): { items: SlashItem[]; loading: boolean } {
  const [disk, setDisk] = useState<DiskCommand[]>([]);
  const [loading, setLoading] = useState(false);
  useEffect(() => {
    if (!enabled) return;
    let alive = true;
    setLoading(true);
    invoke<DiskCommand[]>("list_slash_commands", { agent, cwd: cwd ?? null })
      .then((r) => alive && setDisk(Array.isArray(r) ? r : []))
      .catch(() => alive && setDisk([]))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [agent, cwd, enabled]);
  return { items: mergeSlashItems(agent, disk), loading };
}
