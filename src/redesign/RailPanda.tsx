// Created by Claude — Classification: INTERNAL
//
// The panda in the rail's empty space (docs/prd-rail-panda.md): asleep on its bamboo while
// no agent works, playing a game while one does. Two animated SVGs from LottieFiles (Lottie
// Simple License — credits in resources/THIRD_PARTY_LICENSES.txt), shrunk for the 64 px rail
// (embedded bitmaps scaled down, path precision trimmed; drawing unchanged).
//
// Shown as <img>: the SVG animates itself, needs no player and can't touch the page. Only
// the current one is mounted, and nothing is mounted while the window is hidden, so the
// animation costs nothing when nobody can see it.

import { useEffect, useRef, useState } from "react";
import sleepingUrl from "../assets/panda/sleeping.svg";
import gamingUrl from "../assets/panda/gaming.svg";
import { PANDA_EVENT, pandaEnabled } from "../lib/panda";

/** Below this the rail has no room for the panda. */
export const PANDA_MIN_HEIGHT = 72;

export default function RailPanda({ busy }: { busy: boolean }) {
  const [enabled, setEnabled] = useState(pandaEnabled);
  const [fits, setFits] = useState(true);
  const [hidden, setHidden] = useState(() => typeof document !== "undefined" && document.hidden);
  const boxRef = useRef<HTMLDivElement>(null);

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
          key={busy ? "gaming" : "sleeping"}
          className="rp-img"
          src={busy ? gamingUrl : sleepingUrl}
          alt={label}
          title={label}
          draggable={false}
          data-mood={busy ? "busy" : "idle"}
          style={{ width: busy ? 58 : 62, height: "auto", display: "block", userSelect: "none", filter: "var(--panda-halo)" }}
        />
      )}
    </div>
  );
}
