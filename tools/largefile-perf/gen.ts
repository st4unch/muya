// Created by Claude — Classification: INTERNAL
// Deterministic realistic text generators for the large-file perf harness.
export type Kind = "json" | "log" | "ts" | "minjs" | "md";
export const EXT: Record<Kind, string> = { json: "json", log: "log", ts: "ts", minjs: "js", md: "md" };

function rnd(seed: number) {
  let s = seed >>> 0;
  return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296);
}

function jsonRecord(i: number, r: () => number): string {
  return JSON.stringify(
    { id: i, uuid: `u-${(r() * 1e9) | 0}-${i}`, name: `item ${i}`, active: r() > 0.5, score: +(r() * 100).toFixed(3), tags: ["alpha", "beta", `t${i % 17}`], nested: { a: i * 2, b: "value " + (i % 91), c: [1, 2, 3] } },
    null,
    2,
  );
}

const TS_BLOCK = (i: number) => `export interface Thing${i} {
  id: number;
  name: string;
  tags: string[];
}

export function build${i}(input: Partial<Thing${i}> = {}): Thing${i} {
  // Build a thing with sensible defaults; keep the signature stable.
  const base: Thing${i} = { id: ${i}, name: "thing-${i}", tags: ["a", "b"] };
  if (input.tags && input.tags.length > 3) {
    return { ...base, ...input, tags: input.tags.slice(0, 3) };
  }
  return { ...base, ...input };
}

`;

/** Returns text of at least `bytes` (ASCII, so chars == bytes). */
export function generate(kind: Kind, bytes: number): string {
  const r = rnd(42);
  const parts: string[] = [];
  let n = 0;
  let i = 0;
  if (kind === "minjs") {
    // One line of minified-looking JS.
    while (n < bytes) {
      const s = `function f${i}(a,b){var c=a+b*${i};return c>${i}?c-${i}:"s${i}"}var v${i}=f${i}(${i},2);`;
      parts.push(s);
      n += s.length;
      i++;
    }
    return parts.join("");
  }
  if (kind === "json") {
    parts.push("[\n");
    n += 2;
    while (n < bytes) {
      const s = (i ? ",\n" : "") + jsonRecord(i, r).replace(/^/gm, "  ");
      parts.push(s);
      n += s.length;
      i++;
    }
    parts.push("\n]\n");
    return parts.join("");
  }
  while (n < bytes) {
    let s: string;
    if (kind === "log") {
      const lvl = ["INFO", "WARN", "ERROR", "DEBUG"][(r() * 4) | 0];
      s = `2026-11-13T10:${String((i / 60) % 60 | 0).padStart(2, "0")}:${String(i % 60).padStart(2, "0")}.${String((r() * 999) | 0).padStart(3, "0")}Z ${lvl} svc.worker[${(r() * 64) | 0}] request id=${(r() * 1e9) | 0} path=/api/v1/items/${i} status=${200 + ((r() * 5) | 0)} took=${(r() * 900) | 0}ms\n`;
    } else if (kind === "ts") {
      s = TS_BLOCK(i);
    } else {
      s = `## Section ${i}\n\nSome *emphasis* and **bold** text with a [link](https://example.com/${i}) and \`code ${i}\`.\n\n- item one\n- item two ${i}\n- item three\n\n\`\`\`ts\nconst x${i} = ${i};\n\`\`\`\n\n`;
    }
    parts.push(s);
    n += s.length;
    i++;
  }
  return parts.join("");
}
