// Created by Claude — Classification: INTERNAL
//
// The panda in the rail's empty space (docs/prd-rail-panda.md). Lazy while no agent
// works (eats bamboo, somersaults, sleeps, rolls down a hill, a kung-fu chop), busy while
// one does (wakes up, breaks bamboo, smashes stones, eats tofu). Pure SVG + CSS
// transforms; the scene changes every few seconds and nothing runs while hidden.

import { useEffect, useRef, useState } from "react";
import { BUSY_SCENES, IDLE_SCENES, PANDA_EVENT, nextScene, pandaEnabled, sceneMs, trickFor, type PandaScene } from "../lib/panda";
import "./panda.css";

/** Below this the rail has no room for the scene. */
export const PANDA_MIN_HEIGHT = 96;

function Stalk({ x }: { x: number }) {
  return (
    <g>
      <rect x={x - 2} y={34} width={4} height={55} rx={2} fill="var(--bamboo)" />
      {[48, 63, 77].map((y) => (
        <rect key={y} x={x - 2.6} y={y} width={5.2} height={1.6} rx={0.8} fill="var(--bamboo-dark)" />
      ))}
      <path d={`M${x} 42 q7 -7 13 -4 q-6 2 -13 4z`} fill="var(--bamboo)" />
      <path d={`M${x} 56 q-7 -6 -12 -3 q6 2 12 3z`} fill="var(--bamboo)" />
    </g>
  );
}

/** What gets broken: a bamboo log, or a stone, in two halves. */
function Target({ kind }: { kind: "log" | "stone" }) {
  return kind === "log" ? (
    <g className="rp-target">
      <g className="rp-half-l">
        <rect x={40} y={80} width={10} height={6} rx={2} fill="var(--bamboo)" />
        <rect x={45} y={80} width={1.4} height={6} fill="var(--bamboo-dark)" />
      </g>
      <g className="rp-half-r">
        <rect x={50} y={80} width={10} height={6} rx={2} fill="var(--bamboo)" />
        <rect x={55} y={80} width={1.4} height={6} fill="var(--bamboo-dark)" />
      </g>
    </g>
  ) : (
    <g className="rp-target">
      <path className="rp-half-l" d="M50 78 a7 7 0 0 0 -8 8 h8z" fill="var(--stone)" />
      <path className="rp-half-r" d="M50 78 a7 7 0 0 1 8 8 h-8z" fill="var(--stone)" />
    </g>
  );
}

/** The panda, sitting, in a 64×64 box with its feet at the bottom. */
function Panda({ held }: { held: "bamboo" | "tofu" | null }) {
  return (
    <g className="rp-panda">
      <ellipse cx={23} cy={58} rx={6.5} ry={4.5} fill="var(--panda-ink)" />
      <ellipse cx={41} cy={58} rx={6.5} ry={4.5} fill="var(--panda-ink)" />
      <ellipse className="rp-body" cx={32} cy={45} rx={14} ry={13} fill="var(--panda-fur)" stroke="var(--panda-line)" strokeWidth={0.8} />
      <g className="rp-arm-l">
        <ellipse cx={19} cy={43} rx={4.5} ry={7.5} fill="var(--panda-ink)" />
      </g>
      <g className="rp-arm-r">
        <ellipse cx={45} cy={43} rx={4.5} ry={7.5} fill="var(--panda-ink)" />
        {/* Held in the paw (the arm's lower end), so lifting the arm brings it to the mouth. */}
        {held === "bamboo" && (
          <g>
            <rect x={36} y={47.5} width={18} height={3} rx={1.5} fill="var(--bamboo)" />
            <rect x={44} y={47} width={1.2} height={4} fill="var(--bamboo-dark)" />
            <path d="M37 48 q-4 -5 -8 -4 q4 2 8 4z" fill="var(--bamboo)" />
          </g>
        )}
        {held === "tofu" && <rect x={41} y={46} width={8} height={7} rx={1.5} fill="var(--tofu)" stroke="var(--panda-line)" strokeWidth={0.6} />}
      </g>
      <g className="rp-head">
        <circle cx={22} cy={15} r={4.6} fill="var(--panda-ink)" />
        <circle cx={42} cy={15} r={4.6} fill="var(--panda-ink)" />
        <circle cx={32} cy={25} r={12.5} fill="var(--panda-fur)" stroke="var(--panda-line)" strokeWidth={0.8} />
        <ellipse cx={27} cy={24} rx={3.4} ry={4.6} transform="rotate(25 27 24)" fill="var(--panda-ink)" />
        <ellipse cx={37} cy={24} rx={3.4} ry={4.6} transform="rotate(-25 37 24)" fill="var(--panda-ink)" />
        <g className="rp-eyes-open">
          <circle cx={27.6} cy={23.4} r={1.3} fill="var(--panda-fur)" />
          <circle cx={36.4} cy={23.4} r={1.3} fill="var(--panda-fur)" />
        </g>
        <g className="rp-eyes-closed" stroke="var(--panda-fur)" strokeWidth={1} strokeLinecap="round">
          <line x1={25.8} y1={24.4} x2={28.6} y2={24.4} />
          <line x1={35.4} y1={24.4} x2={38.2} y2={24.4} />
        </g>
        <ellipse cx={32} cy={29} rx={1.9} ry={1.3} fill="var(--panda-ink)" />
        <path className="rp-mouth" d="M30 31.3 q2 1.6 4 0" stroke="var(--panda-ink)" strokeWidth={0.8} fill="none" strokeLinecap="round" />
      </g>
    </g>
  );
}

export default function RailPanda({ busy }: { busy: boolean }) {
  const [enabled, setEnabled] = useState(pandaEnabled);
  const [scene, setScene] = useState<PandaScene>(() => (busy ? "wake" : "eat"));
  const [fits, setFits] = useState(true);
  const [hidden, setHidden] = useState(() => typeof document !== "undefined" && document.hidden);
  const boxRef = useRef<HTMLDivElement>(null);
  const busyRef = useRef(busy);
  busyRef.current = busy;

  useEffect(() => {
    const on = () => setEnabled(pandaEnabled());
    window.addEventListener(PANDA_EVENT, on);
    return () => window.removeEventListener(PANDA_EVENT, on);
  }, []);

  // Dev builds only: `window.dispatchEvent(new CustomEvent("muya:panda-scene", { detail: "roll" }))`
  // shows one scene (screenshots of every scene in the mock UI).
  useEffect(() => {
    if (!import.meta.env.DEV) return;
    const on = (e: Event) => setScene((e as CustomEvent<PandaScene>).detail);
    window.addEventListener("muya:panda-scene", on);
    return () => window.removeEventListener("muya:panda-scene", on);
  }, []);

  useEffect(() => {
    const on = () => setHidden(document.hidden);
    document.addEventListener("visibilitychange", on);
    return () => document.removeEventListener("visibilitychange", on);
  }, []);

  // Room for the scene? (Short windows leave the rail no space.)
  useEffect(() => {
    const el = boxRef.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => setFits(el.clientHeight >= PANDA_MIN_HEIGHT));
    ro.observe(el);
    return () => ro.disconnect();
  }, [enabled]);

  // Work starts → wake up now; work ends → back to lazy things.
  useEffect(() => {
    setScene((s) => (busy ? (BUSY_SCENES.includes(s) || s === "wake" ? s : "wake") : IDLE_SCENES.includes(s) ? s : nextScene(s, false)));
  }, [busy]);

  useEffect(() => {
    if (!enabled || hidden || !fits) return;
    const t = setTimeout(() => setScene((s) => nextScene(s, busyRef.current)), sceneMs(scene));
    return () => clearTimeout(t);
  }, [scene, enabled, hidden, fits]);

  if (!enabled) return <div style={{ flexGrow: 1 }} />;

  const held = scene === "eat" ? "bamboo" : scene === "tofu" ? "tofu" : null;
  return (
    <div ref={boxRef} style={{ flexGrow: 1, minHeight: 0, width: 64, display: "flex", alignItems: "flex-end", justifyContent: "center", overflow: "hidden" }}>
      {fits && (
        <button
          type="button"
          className="rp"
          data-scene={scene}
          data-paused={hidden || undefined}
          onClick={() => setScene((s) => trickFor(s, busyRef.current))}
          title={busy ? "Muya's panda is working with your agents" : "Muya's panda — click for a trick"}
          aria-label="Panda — click for a trick"
          style={{ width: 64, height: 96, padding: 0, border: "none", background: "transparent", cursor: "pointer", flexShrink: 0 }}
        >
          <svg key={scene} viewBox="0 0 64 96" width={64} height={96} aria-hidden="true" style={{ overflow: "visible", display: "block" }}>
            <path className="rp-hill" d="M0 58 Q22 60 34 76 T64 92 L64 96 L0 96Z" fill="var(--bamboo-dark)" />
            <line x1={4} y1={89} x2={60} y2={89} stroke="var(--panda-line)" strokeWidth={1} strokeLinecap="round" opacity={0.35} />
            <g className="rp-grove">
              <Stalk x={8} />
              <Stalk x={57} />
            </g>
            {(scene === "chop" || scene === "kungfu") && <Target kind="log" />}
            {scene === "stone" && <Target kind="stone" />}
            <g transform="translate(0 28)">
              <Panda held={held} />
            </g>
            <g className="rp-z" fill="var(--panda-z)" fontFamily="var(--font-sans)" fontWeight={700}>
              <text x={44} y={46} fontSize={8}>z</text>
              <text x={50} y={38} fontSize={10}>z</text>
              <text x={56} y={28} fontSize={12}>Z</text>
            </g>
            <g className="rp-pow" fill="var(--warning)">
              <path d="M50 70 l2 4 4 -2 -2 4 4 2 -4 1 1 4 -3 -3 -3 3 1 -4 -4 -1 4 -2 -2 -4 4 2z" />
            </g>
          </svg>
        </button>
      )}
    </div>
  );
}
