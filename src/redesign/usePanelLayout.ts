// Created by Claude — Classification: INTERNAL
//
// Control screen's panel layout (docs/prd-v04-followups.md §1–2): which side panels are
// open, their widths, and the Files section's state. Persisted in localStorage.
// null width = "never dragged": the panel uses its responsive default (296/320, narrower
// at ≤1360) instead of a stored number.

import { useCallback, useEffect, useState } from "react";
import { asBool, asClampedNumber, usePersistentState } from "./usePersistentState";
import { FILES_MAX, FILES_MIN } from "./FilesSection";

export const AGENTS_W = { min: 220, max: 480, default: 296 } as const;
export const INSPECTOR_W = { min: 260, max: 520, default: 320 } as const;

const KEY = {
  agentsOpen: "muya.panels.agentsOpen",
  inspectorOpen: "muya.panels.inspectorOpen",
  agentsW: "muya.panels.agentsWidth",
  inspectorW: "muya.panels.inspectorWidth",
  filesOpen: "muya.panels.filesOpen",
  filesH: "muya.panels.filesHeight",
} as const;


/** Keyboard: ⌘B agents, ⌥⌘B inspector. `code`, not `key`: ⌥B types "∫" on macOS. */
export function panelShortcut(e: Pick<KeyboardEvent, "metaKey" | "ctrlKey" | "shiftKey" | "altKey" | "code">): "agents" | "inspector" | null {
  if (!e.metaKey || e.ctrlKey || e.shiftKey || e.code !== "KeyB") return null;
  return e.altKey ? "inspector" : "agents";
}

/** `narrow`: the window is below the inspector's breakpoint (1280px). There the inspector
 *  starts hidden, and its toggle shows it for this session only — the stored wide-screen
 *  preference is left alone. The returned `inspectorOpen` is what is actually on screen,
 *  so the header button's pressed state can never disagree with the layout (L54). */
export function usePanelLayout(narrow = false) {
  const [agentsOpen, setAgentsOpen] = usePersistentState<boolean>(KEY.agentsOpen, true, asBool);
  const [inspectorOpen, setInspectorOpen] = usePersistentState<boolean>(KEY.inspectorOpen, true, asBool);
  // null = never dragged (responsive default); a number once the operator resized.
  const [agentsW, setAgentsW] = usePersistentState<number | null>(KEY.agentsW, null, asClampedNumber(AGENTS_W.min, AGENTS_W.max));
  const [inspectorW, setInspectorW] = usePersistentState<number | null>(KEY.inspectorW, null, asClampedNumber(INSPECTOR_W.min, INSPECTOR_W.max));
  const [filesOpen, setFilesOpen] = usePersistentState<boolean>(KEY.filesOpen, false, asBool);
  // null = fill: the expanded Files section takes all the height the agents list
  // doesn't need. A number once the operator drags the split.
  const [filesH, setFilesH] = usePersistentState<number | null>(KEY.filesH, null, asClampedNumber(FILES_MIN, FILES_MAX));

  const toggleAgents = useCallback(() => setAgentsOpen(!agentsOpen), [agentsOpen, setAgentsOpen]);
  const [narrowInspector, setNarrowInspector] = useState(false);
  const inspectorVisible = narrow ? narrowInspector : inspectorOpen;
  const toggleInspector = useCallback(() => {
    if (narrow) setNarrowInspector((v) => !v);
    else setInspectorOpen(!inspectorOpen);
  }, [narrow, inspectorOpen, setInspectorOpen]);

  // Window capture phase, like ⌘K in App.tsx: a focused xterm swallows keys before any
  // bubbling listener would see them.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const which = panelShortcut(e);
      if (!which) return;
      e.preventDefault();
      e.stopPropagation();
      if (which === "agents") toggleAgents();
      else toggleInspector();
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [toggleAgents, toggleInspector]);

  return {
    agentsOpen,
    inspectorOpen: inspectorVisible,
    toggleAgents,
    toggleInspector,
    agentsW,
    setAgentsW,
    inspectorW,
    setInspectorW,
    filesOpen,
    toggleFiles: () => setFilesOpen(!filesOpen),
    filesH,
    setFilesH,
  };
}
