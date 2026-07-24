// Pure helpers for the "needs decision" blink on terminal tabs.
//
// A waiting tab blinks until the operator opens (activates) it. Opening it
// acknowledges the prompt, so it stops blinking even before the ~15s session
// poll notices the answer. The acknowledgement is dropped once the tab is no
// longer waiting, so the NEXT prompt on the same tab blinks again.

/** Recompute the acknowledged set: activating a waiting tab acknowledges it;
 *  prior acks survive only while their tab is still waiting. */
export function nextAcked(
  prev: Set<string>,
  activeKey: string | null,
  waiting: Set<string>,
): Set<string> {
  const next = new Set<string>();
  if (activeKey && waiting.has(activeKey)) next.add(activeKey);
  for (const k of prev) if (waiting.has(k)) next.add(k);
  return next;
}

/** Tabs that should blink now: waiting, not the active tab, not acknowledged. */
export function deriveBlinkKeys(
  waiting: Set<string>,
  activeKey: string | null,
  acked: Set<string>,
): Set<string> {
  const s = new Set<string>();
  for (const k of waiting) if (k !== activeKey && !acked.has(k)) s.add(k);
  return s;
}
