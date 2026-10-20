// Created by Claude — Classification: INTERNAL
//
// A rail panda scene: one Rive animation of our own rigged panda (docs/prd-rive-panda.md,
// tools/panda-studio). The Rive web runtime ("lite": no text, audio or layout engine) and its
// wasm come from the app bundle, never a CDN, and load only when the panda is first shown. One
// Rive instance per mounted scene, cleaned up when the scene changes or the panda goes away, so
// nothing runs while it is hidden.
//
// Framing: the whole artboard is drawn on a canvas sized so that the scene's `crop` square
// fills the rail's box, and the box (overflow hidden) shows just that square.

import { useEffect, useRef } from "react";

export type RiveSrc = () => Promise<{ default: string }>;
/** Artboard width and height. */
export type Size = readonly [number, number];
/** The square of the artboard to show, [x0, y0, x1, y1] in artboard units (may run past its edges). */
export type Crop = readonly [number, number, number, number];

type Runtime = typeof import("@rive-app/canvas-lite");
let runtime: Promise<Runtime> | undefined;

function loadRuntime(): Promise<Runtime> {
  runtime ??= Promise.all([import("@rive-app/canvas-lite"), import("@rive-app/canvas-lite/rive.wasm?url")]).then(([mod, wasm]) => {
    // the package is CommonJS: depending on the bundler its API is the module or its default
    const rive = ("RuntimeLoader" in mod ? mod : (mod as unknown as { default: Runtime }).default) as Runtime;
    rive.RuntimeLoader.setWasmUrl(wasm.default);
    return rive;
  });
  return runtime;
}

export default function RivePanda({ load, size, crop, label, mood, scene, width }: { load: RiveSrc; size: Size; crop: Crop; label: string; mood: string; scene: string; width: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const scale = width / (crop[2] - crop[0]);
  const cssW = size[0] * scale;
  const cssH = size[1] * scale;

  useEffect(() => {
    let gone = false;
    let anim: { cleanup(): void } | undefined;
    Promise.all([loadRuntime(), load()])
      .then(([rive, src]) => {
        const canvas = ref.current;
        if (gone || !canvas) return;
        const dpr = Math.min(3, window.devicePixelRatio || 1);
        canvas.width = Math.round(cssW * dpr);
        canvas.height = Math.round(cssH * dpr);
        anim = new rive.Rive({
          src: src.default,
          canvas,
          autoplay: true,
          stateMachines: "State Machine 1",
          layout: new rive.Layout({ fit: rive.Fit.Contain, alignment: rive.Alignment.Center }),
        });
      })
      .catch(() => {
        /* a scene that fails to load just leaves the rail empty */
      });
    return () => {
      gone = true;
      anim?.cleanup();
    };
  }, [load, cssW, cssH]);

  return (
    <div
      role="img"
      aria-label={label}
      title={label}
      className="rp-img"
      data-mood={mood}
      data-scene={scene}
      style={{ position: "relative", width, height: width, flexShrink: 0, overflow: "hidden", userSelect: "none", filter: "var(--panda-halo)" }}
    >
      <canvas
        ref={ref}
        style={{ position: "absolute", left: -crop[0] * scale, top: -crop[1] * scale, width: cssW, height: cssH, display: "block" }}
      />
    </div>
  );
}
