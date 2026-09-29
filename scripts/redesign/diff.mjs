// Created by Claude — Classification: INTERNAL
//
// Pixel diff between two same-size PNGs with masked rectangles.
// Library use: diffPngs({ ref, app, out, masks }) → { percent, differing, total }
//
// Masked pixels are painted identically in both images before comparing, and they
// are EXCLUDED from the denominator: a large mask must not dilute the percentage
// and make a bad match look good.

import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
import { readFileSync, writeFileSync } from "node:fs";

/** @param {{ref:string, app:string, out:string, masks:{x:number,y:number,width:number,height:number}[], threshold?:number}} o */
export function diffPngs({ ref, app, out, masks, threshold = 0.1 }) {
  const a = PNG.sync.read(readFileSync(ref));
  const b = PNG.sync.read(readFileSync(app));
  if (a.width !== b.width || a.height !== b.height) {
    throw new Error(`size mismatch: ref ${a.width}x${a.height} vs app ${b.width}x${b.height}`);
  }
  const { width, height } = a;
  const masked = new Uint8Array(width * height);
  for (const m of masks) {
    const x0 = Math.max(0, Math.floor(m.x)), y0 = Math.max(0, Math.floor(m.y));
    const x1 = Math.min(width, Math.ceil(m.x + m.width)), y1 = Math.min(height, Math.ceil(m.y + m.height));
    for (let y = y0; y < y1; y++) {
      for (let x = x0; x < x1; x++) {
        masked[y * width + x] = 1;
        const i = (y * width + x) * 4;
        for (const img of [a, b]) {
          img.data[i] = 255; img.data[i + 1] = 0; img.data[i + 2] = 255; img.data[i + 3] = 255;
        }
      }
    }
  }
  const diff = new PNG({ width, height });
  const differing = pixelmatch(a.data, b.data, diff.data, width, height, { threshold });
  writeFileSync(out, PNG.sync.write(diff));
  const total = width * height - masked.reduce((s, v) => s + v, 0);
  return { differing, total, percent: (100 * differing) / total };
}
