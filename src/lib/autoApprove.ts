// Created by Claude — Classification: INTERNAL
//
// "Auto-allow permission prompts": when on, a permission prompt that nobody answers
// within AUTO_APPROVE_MS is approved as if the user clicked Allow. Applies to every
// session, visible or not. Off unless the user turns it on in Settings.

export const AUTO_APPROVE_KEY = "muya.autoApprove";
export const AUTO_APPROVE_MS = 2000;
/** Fired on window when the setting changes, so App picks it up without a restart. */
export const AUTO_APPROVE_EVENT = "muya:auto-approve-changed";

export function loadAutoApprove(): boolean {
  try {
    return localStorage.getItem(AUTO_APPROVE_KEY) === "1";
  } catch {
    return false;
  }
}

export function saveAutoApprove(on: boolean): void {
  try {
    if (on) localStorage.setItem(AUTO_APPROVE_KEY, "1");
    else localStorage.removeItem(AUTO_APPROVE_KEY);
  } catch {
    /* storage unavailable — the switch just won't persist */
  }
  window.dispatchEvent(new CustomEvent(AUTO_APPROVE_EVENT, { detail: on }));
}

interface WaitingAgent {
  key: string;
  status: string;
  approval?: { actionable?: boolean };
}

/** Keys whose prompt can be auto-approved right now: waiting on a prompt whose
 *  Allow option was read from the screen. */
export function approvableKeys(agents: readonly WaitingAgent[]): string[] {
  return agents.filter((a) => a.status === "waiting" && a.approval && a.approval.actionable !== false).map((a) => a.key);
}
