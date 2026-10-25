// Created by Claude — Classification: INTERNAL
//
// The single agent model (PLAN F3). App feeds it the raw signals it already has — open
// tabs, the ~15s Claude session poll, live cwds — and each terminal's parsed screen; it
// returns the AgentVM[] every redesigned surface renders from, plus the counts.
// Status-change timestamps ("waiting for 1m") are recorded here, on the transition.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { ScreenMode, ScreenState } from "../lib/screenState";
import { isRecent, readLastActive, touchActive, writeLastActive, type LastActive } from "./recentActivity";
import type { AgentVM } from "./types";
import {
  buildAgents,
  countAgents,
  recordTransitions,
  type AgentCounts,
  type AgentTab,
  type SessionStatus,
  type StatusStamp,
} from "./agentModel";

/** sessionStorage, not localStorage: a webview reload keeps the wait clock, a new app
 *  launch (new PTYs, new prompts) starts it fresh. */
const WAITING_SINCE_KEY = "muya.waitingSince";

function readWaitingSince(): Record<string, number> {
  try {
    const v = JSON.parse(sessionStorage.getItem(WAITING_SINCE_KEY) ?? "{}");
    return v && typeof v === "object" ? v : {};
  } catch {
    return {};
  }
}

function sameStatusMap(a: Record<string, unknown>, b: Record<string, unknown>): boolean {
  const ka = Object.keys(a);
  return ka.length === Object.keys(b).length && ka.every((k) => a[k] === b[k]);
}

export interface AgentModel {
  agents: AgentVM[];
  counts: AgentCounts;
  /** Feed the latest polled Claude session status per tab key. */
  reportSessionStatus: (byKey: Record<string, SessionStatus | undefined>) => void;
  /** Feed one terminal's parsed screen (Terminal's onScreen). */
  reportScreen: (key: string, state: ScreenState) => void;
  /** The operator just answered this agent's prompt — stop trusting a stale "waiting". */
  markAnswered: (key: string) => void;
  /** Latest parsed screen for a key (approve/deny read the option keys from it). */
  screenOf: (key: string) => ScreenState | undefined;
}

export function useAgentModel(args: {
  tabs: AgentTab[];
  liveCwds: Record<string, string>;
  branchByCwd: Record<string, string>;
}): AgentModel {
  const { tabs, liveCwds, branchByCwd } = args;
  const [sessionStatus, setSessionStatus] = useState<Record<string, SessionStatus | undefined>>({});
  const [screens, setScreens] = useState<Record<string, ScreenState | undefined>>({});
  const [answered, setAnswered] = useState<Record<string, number>>({});
  const [now, setNow] = useState(() => Date.now());
  const stampsRef = useRef<Record<string, StatusStamp>>({});
  const screensRef = useRef(screens);
  screensRef.current = screens;
  const lastModesRef = useRef<Record<string, ScreenMode | undefined>>({});
  const lastActiveRef = useRef<LastActive>(readLastActive());
  /** Claude transcript times by session id, read once at launch (seeds "Recent"). */
  const [transcriptTimes, setTranscriptTimes] = useState<Record<string, number>>({});

  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    let cancelled = false;
    invoke<{ sessionId: string; lastModified: number }[]>("list_session_history")
      .then((list) => {
        if (cancelled || !Array.isArray(list)) return;
        const byId: Record<string, number> = {};
        for (const s of list) if (s?.sessionId && typeof s.lastModified === "number") byId[s.sessionId] = s.lastModified;
        setTranscriptTimes(byId);
      })
      .catch(() => {
        /* no history — Recent still learns from working/waiting */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const reportSessionStatus = useCallback((byKey: Record<string, SessionStatus | undefined>) => {
    setSessionStatus((prev) => (sameStatusMap(prev, byKey) ? prev : byKey));
  }, []);
  const reportScreen = useCallback((key: string, state: ScreenState) => {
    if (state.modeDetected) lastModesRef.current[key] = state.mode;
    setScreens((prev) => ({ ...prev, [key]: state }));
  }, []);
  const markAnswered = useCallback((key: string) => {
    setAnswered((prev) => ({ ...prev, [key]: Date.now() }));
    setNow(Date.now());
  }, []);
  const screenOf = useCallback((key: string) => screensRef.current[key], []);

  const agents = useMemo(() => {
    const input = { tabs, sessionStatus, screens, lastModes: lastModesRef.current, liveCwds, branchByCwd, answered, stamps: stampsRef.current, now };
    let built = buildAgents(input);
    const next = recordTransitions(stampsRef.current, built, now, readWaitingSince());
    if (next !== stampsRef.current) {
      stampsRef.current = next;
      built = buildAgents({ ...input, stamps: next });
    }
    const seeds: LastActive = {};
    for (const t of tabs) {
      const at = t.sessionId ? transcriptTimes[t.sessionId] : undefined;
      if (at) seeds[t.key] = at;
    }
    lastActiveRef.current = touchActive(lastActiveRef.current, built, now, seeds);
    const lastActive = lastActiveRef.current;
    return built.map((a) => ({ ...a, recent: isRecent(a.status, lastActive[a.key], now) }));
  }, [tabs, sessionStatus, screens, liveCwds, branchByCwd, answered, now, transcriptTimes]);

  // Keep "last active" across launches; written only when the map actually changed.
  const savedLastActiveRef = useRef<LastActive | null>(null);
  useEffect(() => {
    if (savedLastActiveRef.current === lastActiveRef.current) return;
    savedLastActiveRef.current = lastActiveRef.current;
    writeLastActive(lastActiveRef.current);
  }, [agents]);

  // Persist the wait clocks. A stored stamp is dropped only after this page has seen
  // that agent WAITING and then not waiting — before its first parse it merely looks idle.
  const seenWaitingRef = useRef<Set<string>>(new Set());
  useEffect(() => {
    const stored = readWaitingSince();
    for (const [k, s] of Object.entries(stampsRef.current)) {
      if (s.status === "waiting") {
        stored[k] = s.at;
        seenWaitingRef.current.add(k);
      } else if (seenWaitingRef.current.has(k)) {
        delete stored[k];
        seenWaitingRef.current.delete(k);
      }
    }
    try {
      sessionStorage.setItem(WAITING_SINCE_KEY, JSON.stringify(stored));
    } catch {
      /* storage unavailable — the clock just restarts on reload */
    }
  }, [agents]);

  const counts = useMemo(() => countAgents(agents), [agents]);
  return { agents, counts, reportSessionStatus, reportScreen, markAnswered, screenOf };
}
