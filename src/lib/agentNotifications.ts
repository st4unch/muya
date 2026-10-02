// Created by Claude — Classification: INTERNAL
//
// Header-bell notifications: a log of agent events ("waiting for you", "finished").
// An entry stays until the operator clears the list — it does not disappear when the
// agent moves on. Events for the agent the operator is looking at are not logged.

export interface StatusOf {
  key: string;
  name: string;
  status: "waiting" | "working" | "idle";
}

export interface AgentNotification {
  id: string;
  key: string;
  name: string;
  kind: "waiting" | "finished";
  at: number;
}

/** Newest first; older entries past this are dropped. */
export const MAX_NOTIFICATIONS = 100;

/** Events between the previous and current statuses. Both events need the agent to
 *  have been WORKING just before: on app start / reload every agent first reads idle
 *  until its screen is parsed, and that idle → waiting/working settling is not news. */
export function detectEvents(
  prevStatus: Record<string, string>,
  agents: readonly StatusOf[],
  watched: ReadonlySet<string>,
  now: number,
): AgentNotification[] {
  const out: AgentNotification[] = [];
  for (const a of agents) {
    const prev = prevStatus[a.key];
    if (prev === undefined || prev === a.status || watched.has(a.key)) continue;
    if (prev !== "working") continue;
    const kind = a.status === "waiting" ? "waiting" : a.status === "idle" ? "finished" : null;
    if (kind) out.push({ id: `${a.key}:${now}:${kind}`, key: a.key, name: a.name, kind, at: now });
  }
  return out;
}

/** Validator for the persisted list (usePersistentState). */
export function asNotifications(raw: unknown): AgentNotification[] | null {
  if (!Array.isArray(raw)) return null;
  return raw
    .filter(
      (n): n is AgentNotification =>
        !!n && typeof n.id === "string" && typeof n.key === "string" && typeof n.name === "string" &&
        (n.kind === "waiting" || n.kind === "finished") && typeof n.at === "number",
    )
    .slice(0, MAX_NOTIFICATIONS);
}
