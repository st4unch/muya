// Created by Claude — Classification: INTERNAL
//
// The panda in the rail's empty space (docs/prd-rail-panda.md). While no agent works it
// sleeps on its bamboo and now and then rolls down a hill; while one does it takes turns
// playing a game, snapping bamboo, eating tofu or mantı, and once in a while farts and runs.
// sleeping/gaming are LottieFiles animations (Lottie Simple License — credits in
// resources/THIRD_PARTY_LICENSES.txt), shrunk for the 64 px rail; the other five reuse the
// gaming panda's head with a jointed body drawn in the same style.
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
import { PANDA_EVENT, SCENE_MS, firstScene, nextScene, pandaEnabled, type PandaScene } from "../lib/panda";

const SRC: Record<PandaScene, string> = {
  sleeping: sleepingUrl,
  roll: rollUrl,
  gaming: gamingUrl,
  bamboo: bambooUrl,
  tofu: tofuUrl,
  manti: mantiUrl,
  fart: fartUrl,
};

/** Below this the rail has no room for the panda. */
export const PANDA_MIN_HEIGHT = 72;

export default function RailPanda({ busy }: { busy: boolean }) {
  const [enabled, setEnabled] = useState(pandaEnabled);
  const [fits, setFits] = useState(true);
  const [hidden, setHidden] = useState(() => typeof document !== "undefined" && document.hidden);
  const [scene, setScene] = useState<PandaScene>(() => firstScene(busy));
  const boxRef = useRef<HTMLDivElement>(null);

  // A change of mood starts over with that mood's first scene (during render, so the old
  // mood's scene never shows for a frame).
  const [mood, setMood] = useState(busy);
  if (mood !== busy) {
    setMood(busy);
    setScene(firstScene(busy));
  }

  // Take turns while the panda is on screen (an <img> restarts its animation when swapped).
  const showing = enabled && fits && !hidden;
  useEffect(() => {
    if (!showing) return;
    const t = window.setTimeout(() => setScene((s) => nextScene(busy, s)), SCENE_MS[scene]);
    return () => window.clearTimeout(t);
  }, [showing, busy, scene]);

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

  const label = busy ? "Muya's panda is playing while your agents work" : "Muya's panda is asleep — nothing is running";
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
          data-mood={busy ? "busy" : "idle"}
          data-scene={scene}
          style={{ width: scene === "sleeping" || scene === "roll" ? 62 : 58, height: "auto", display: "block", userSelect: "none", filter: "var(--panda-halo)" }}
        />
      )}
    </div>
  );
}
