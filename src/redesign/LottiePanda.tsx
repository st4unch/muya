// Created by Claude — Classification: INTERNAL
//
// A rail panda scene that ships as a Lottie animation (docs/prd-rail-panda.md). The player
// (lottie-web's "light" build: SVG renderer, no expression engine, so no eval under the app's
// CSP) and the animation are loaded only when the scene is shown, and the player is destroyed
// when it goes away — nothing runs while the panda is hidden or another scene is up.

import { useEffect, useRef } from "react";

export type LottieData = () => Promise<{ default: unknown }>;

export default function LottiePanda({ load, label, mood, scene, width }: { load: LottieData; label: string; mood: string; scene: string; width: number }) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let gone = false;
    let anim: { destroy(): void } | undefined;
    Promise.all([import("lottie-web/build/player/lottie_light"), load()])
      .then(([player, data]) => {
        if (gone || !ref.current) return;
        anim = player.default.loadAnimation({
          container: ref.current,
          renderer: "svg",
          loop: true,
          autoplay: true,
          // the player annotates the data it is given; keep the cached module pristine
          animationData: structuredClone(data.default),
          rendererSettings: { preserveAspectRatio: "xMidYMax meet" },
        });
      })
      .catch(() => {
        /* a missing animation just leaves the rail empty */
      });
    return () => {
      gone = true;
      anim?.destroy();
    };
  }, [load]);

  return (
    <div
      ref={ref}
      role="img"
      aria-label={label}
      title={label}
      className="rp-img"
      data-mood={mood}
      data-scene={scene}
      style={{ width, height: width, flexShrink: 0, userSelect: "none", filter: "var(--panda-halo)" }}
    />
  );
}
