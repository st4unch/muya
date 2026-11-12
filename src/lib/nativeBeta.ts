// Created by Claude — Classification: INTERNAL
//
// Glue between the update flow / Settings and the Native-beta offer modal.

import { invoke } from "@tauri-apps/api/core";

export type BetaOffer = { version: string; notes: string };
export type SwitchoverCheck = {
  status: "show" | "hidden" | "installed";
  version?: string | null;
  notes?: string | null;
  reason?: string | null;
};

let offeredThisSession = false;

/** Test hook: forget that the offer was already shown. */
export function resetNativeBetaSession() {
  offeredThisSession = false;
}

/** After the normal update flow ended with "up to date": the offer to show, or null.
 *  At most once per app session; every failure is swallowed (never interrupts anything). */
export async function checkNativeBetaAfterUpdate(): Promise<BetaOffer | null> {
  if (offeredThisSession) return null;
  try {
    const r = await invoke<SwitchoverCheck>("switchover_check", { trigger: "afterUpdate" });
    if (r?.status !== "show" || !r.version) return null;
    if (offeredThisSession) return null;
    offeredThisSession = true;
    return { version: r.version, notes: r.notes ?? "" };
  } catch {
    return null;
  }
}
