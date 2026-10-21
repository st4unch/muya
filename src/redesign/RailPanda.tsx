// Created by Claude — Classification: INTERNAL
//
// The panda in the rail's empty space (docs/prd-rail-panda.md, docs/prd-rive-panda.md). Our
// own rigged panda, animated in Rive (tools/panda-studio; artwork credits in
// resources/THIRD_PARTY_LICENSES.txt): when an agent starts, the teacher points at a board that
// shows what Claude is doing ("Thinking…"), then gaming, the kung-fu cookie run, the bamboo
// splits, the fan dance, the traveller and the businessman take turns. When the work is done
// the panda celebrates once; with nothing running it waves, flips, bows, rolls down a hill and
// snacks; after 5 quiet minutes it sleeps on its bamboo branch.
//
// Each scene (RivePanda) loads the runtime and its file only while shown. Only the current scene
// is mounted, and nothing is mounted while the window is hidden, so the panda costs nothing
// when nobody looks.

import { useEffect, useRef, useState } from "react";
import RivePanda, { type Crop, type RiveSrc, type Size } from "./RivePanda";
import { PANDA_EVENT, SCENE_MS, SLEEP_AFTER_MS, firstScene, nextScene, pandaEnabled, pandaMood, type PandaMood, type PandaScene } from "../lib/panda";

// Rive scenes, fetched only when shown. `size` is the artboard; `crop` is the square of it the
// rail shows (the panda and its props), measured from rendered frames by
// tools/panda-studio/crops.py.
const SCENES: Record<PandaScene, { load: RiveSrc; size: Size; crop: Crop }> = {
  sleep: { load: () => import("../assets/panda/rive/sleep.riv?url"), size: [1000, 1100], crop: [79, 240, 930, 1092] },
  wave: { load: () => import("../assets/panda/rive/wave.riv?url"), size: [1000, 1100], crop: [124, 299, 896, 1070] },
  flip: { load: () => import("../assets/panda/rive/flip.riv?url"), size: [1000, 1100], crop: [-26, 69, 1025, 1120] },
  bow: { load: () => import("../assets/panda/rive/bow.riv?url"), size: [1000, 1100], crop: [119, 310, 889, 1079] },
  roll: { load: () => import("../assets/panda/rive/roll.riv?url"), size: [1500, 1260], crop: [-30, -289, 1530, 1271] },
  fart: { load: () => import("../assets/panda/rive/fart.riv?url"), size: [1500, 1100], crop: [139, 243, 1033, 1138] },
  bamboo_eat: { load: () => import("../assets/panda/rive/bamboo_eat.riv?url"), size: [1000, 1100], crop: [112, 295, 894, 1076] },
  tofu_eat: { load: () => import("../assets/panda/rive/tofu_eat.riv?url"), size: [1000, 1100], crop: [118, 282, 911, 1075] },
  manti: { load: () => import("../assets/panda/rive/manti.riv?url"), size: [1150, 1100], crop: [168, 295, 949, 1076] },
  celebrate: { load: () => import("../assets/panda/rive/celebrate.riv?url"), size: [1000, 1100], crop: [16, 99, 1021, 1105] },
  teacher: { load: () => import("../assets/panda/rive/teacher.riv?url"), size: [1250, 1100], crop: [136, 91, 1126, 1081] },
  gaming: { load: () => import("../assets/panda/rive/gaming.riv?url"), size: [1000, 1100], crop: [99, 314, 900, 1115] },
  cookie: { load: () => import("../assets/panda/rive/cookie.riv?url"), size: [1100, 1150], crop: [-48, -22, 1147, 1173] },
  bamboo: { load: () => import("../assets/panda/rive/bamboo.riv?url"), size: [1000, 1150], crop: [-40, 91, 1039, 1171] },
  dance: { load: () => import("../assets/panda/rive/dance.riv?url"), size: [1000, 1100], crop: [115, 310, 884, 1078] },
  traveller: { load: () => import("../assets/panda/rive/traveller.riv?url"), size: [1100, 1100], crop: [53, 243, 947, 1138] },
  business: { load: () => import("../assets/panda/rive/business.riv?url"), size: [1000, 1100], crop: [53, 243, 947, 1138] },
};

const SPIN = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"];

/** The teacher's board: Claude's spinner and what it is doing, like Claude's own status line. */
function Board({ text }: { text: string }) {
  const [i, setI] = useState(0);
  useEffect(() => {
    const t = window.setInterval(() => setI((n) => (n + 1) % SPIN.length), 120);
    return () => window.clearInterval(t);
  }, []);
  return (
    <div
      className="rp-board"
      title={text}
      style={{
        boxSizing: "border-box", width: 58, marginBottom: 1, padding: "2px 4px", borderRadius: 6,
        border: "1px solid var(--border-strong)", background: "var(--bg-control)", color: "var(--text)",
        font: "600 8.5px/1.3 var(--font-sans)", letterSpacing: "-0.1px", whiteSpace: "nowrap", overflow: "hidden",
      }}
    >
      <span style={{ color: "var(--agent-claude)", display: "inline-block", width: 8 }}>{SPIN[i]}</span>
      {text}
    </div>
  );
}

/** Below this the rail has no room for the panda. */
export const PANDA_MIN_HEIGHT = 72;

const LABEL: Record<PandaMood, string> = {
  busy: "Muya's panda is busy while your agents work",
  idle: "Muya's panda is hanging around — nothing is running",
  asleep: "Muya's panda fell asleep — nothing has happened for 5 minutes",
};

// Anything the user does in the window counts as "someone is here". Capture phase, so keys
// typed into a terminal or the editor count too.
const ACTIVITY = ["keydown", "pointerdown", "pointermove", "wheel"] as const;

/** True once nothing ran and nobody touched Muya for SLEEP_AFTER_MS. */
function useQuiet(busy: boolean, on: boolean): boolean {
  const last = useRef(Date.now());
  const [quiet, setQuiet] = useState(false);
  const quietRef = useRef(false);
  const set = (v: boolean) => {
    if (quietRef.current !== v) {
      quietRef.current = v;
      setQuiet(v);
    }
  };

  // Work counts as activity: the countdown starts when the last agent stops.
  useEffect(() => {
    last.current = Date.now();
    set(false);
  }, [busy]);

  useEffect(() => {
    if (!on) return;
    const touch = () => {
      last.current = Date.now();
      set(false);
    };
    for (const e of ACTIVITY) window.addEventListener(e, touch, { capture: true, passive: true });
    const tick = window.setInterval(() => {
      if (!busy && Date.now() - last.current >= SLEEP_AFTER_MS) set(true);
    }, 5_000);
    return () => {
      for (const e of ACTIVITY) window.removeEventListener(e, touch, { capture: true });
      window.clearInterval(tick);
    };
  }, [on, busy]);

  return quiet;
}

/** busy: an agent is working · status: what it is doing ("Thinking…"), shown on the teacher's board */
export default function RailPanda({ busy, status }: { busy: boolean; status?: string }) {
  const [enabled, setEnabled] = useState(pandaEnabled);
  const [fits, setFits] = useState(true);
  const [hidden, setHidden] = useState(() => typeof document !== "undefined" && document.hidden);
  const quiet = useQuiet(busy, enabled);
  const mood = pandaMood(busy, quiet ? SLEEP_AFTER_MS : 0);
  const [scene, setScene] = useState<PandaScene>(() => firstScene(mood));
  const boxRef = useRef<HTMLDivElement>(null);

  // A change of mood starts over with that mood's first scene (during render, so the old
  // mood's scene never shows for a frame).
  const [shownMood, setShownMood] = useState(mood);
  if (shownMood !== mood) {
    setShownMood(mood);
    setScene(firstScene(mood, shownMood));
  }

  // Take turns while the panda is on screen (a remounted scene starts its animation over).
  const showing = enabled && fits && !hidden;
  useEffect(() => {
    if (!showing) return;
    const t = window.setTimeout(() => setScene((s) => nextScene(mood, s)), SCENE_MS[scene]);
    return () => window.clearTimeout(t);
  }, [showing, mood, scene]);

  useEffect(() => {
    const on = () => setEnabled(pandaEnabled());
    window.addEventListener(PANDA_EVENT, on);
    return () => window.removeEventListener(PANDA_EVENT, on);
  }, []);

  useEffect(() => {
    const on = () => setHidden(document.hidden);
    document.addEventListener("visibilitychange", on);
    return () => document.removeEventListener("visibilitychange", on);
  }, []);

  // Room for the panda? (Short windows leave the rail no space.)
  useEffect(() => {
    const el = boxRef.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => setFits(el.clientHeight >= PANDA_MIN_HEIGHT));
    ro.observe(el);
    return () => ro.disconnect();
  }, [enabled]);

  if (!enabled) return <div style={{ flexGrow: 1 }} />;

  const label = LABEL[mood];
  return (
    <div ref={boxRef} style={{ flexGrow: 1, minHeight: 0, width: 64, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "flex-end", overflow: "hidden" }}>
      {fits && !hidden && scene === "teacher" && status && <Board text={status} />}
      {fits && !hidden && <RivePanda key={scene} load={SCENES[scene].load} size={SCENES[scene].size} crop={SCENES[scene].crop} label={label} mood={mood} scene={scene} width={62} />}
    </div>
  );
}
