// Created by Claude — Classification: INTERNAL
//
// The panda in the rail's empty space (docs/prd-rail-panda.md). When an agent starts it does
// kung fu (flying kick, flips, snaps bamboo), then takes turns playing a game, snapping
// bamboo, eating tofu or mantı, and once in a while farts and runs. With nothing running it
// stays awake (rolls down a hill, snacks) until nobody has touched Muya for 5 minutes, then
// sleeps on its bamboo. sleeping/gaming are LottieFiles animations (Lottie Simple License —
// credits in resources/THIRD_PARTY_LICENSES.txt), shrunk for the 64 px rail; the others reuse
// the gaming panda's head with a jointed body drawn in the same style.
//
// Shown as <img>: the SVG animates itself, needs no player and can't touch the page. Only
// the current one is mounted, and nothing is mounted while the window is hidden, so the
// animation costs nothing when nobody can see it.

import { useEffect, useRef, useState } from "react";
import sleepingUrl from "../assets/panda/sleeping.svg";
import gamingUrl from "../assets/panda/gaming.svg";
import bambooUrl from "../assets/panda/bamboo.svg";
import tofuUrl from "../assets/panda/tofu.svg";
import mantiUrl from "../assets/panda/manti.svg";
import fartUrl from "../assets/panda/fart.svg";
import rollUrl from "../assets/panda/roll.svg";
import kungfuUrl from "../assets/panda/kungfu.svg";
import { PANDA_EVENT, SCENE_MS, SLEEP_AFTER_MS, firstScene, nextScene, pandaEnabled, pandaMood, type PandaMood, type PandaScene } from "../lib/panda";

const SRC: Record<PandaScene, string> = {
  sleeping: sleepingUrl,
  roll: rollUrl,
  kungfu: kungfuUrl,
  gaming: gamingUrl,
  bamboo: bambooUrl,
  tofu: tofuUrl,
  manti: mantiUrl,
  fart: fartUrl,
};

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

export default function RailPanda({ busy }: { busy: boolean }) {
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
    setScene(firstScene(mood));
  }

  // Take turns while the panda is on screen (an <img> restarts its animation when swapped).
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
    <div ref={boxRef} style={{ flexGrow: 1, minHeight: 0, width: 64, display: "flex", alignItems: "flex-end", justifyContent: "center", overflow: "hidden" }}>
      {fits && !hidden && (
        <img
          key={scene}
          className="rp-img"
          src={SRC[scene]}
          alt={label}
          title={label}
          draggable={false}
          data-mood={mood}
          data-scene={scene}
          style={{ width: scene === "sleeping" || scene === "roll" || scene === "kungfu" ? 62 : 58, height: "auto", display: "block", userSelect: "none", filter: "var(--panda-halo)" }}
        />
      )}
    </div>
  );
}
