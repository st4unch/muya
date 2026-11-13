// Created by Claude — Classification: INTERNAL
// Times the rendered-Markdown path (marked -> DOMPurify -> innerHTML -> layout) for ?mb=N.
import { marked } from "marked";
import DOMPurify from "dompurify";
import { generate } from "./gen";
const mb = Number(new URLSearchParams(location.search).get("mb") ?? "1");
const text = generate("md", Math.round(mb * 1048576));
const out = document.getElementById("out")!;
const t0 = performance.now();
const dirty = marked.parse(text, { async: false }) as string;
const t1 = performance.now();
const clean = DOMPurify.sanitize(dirty);
const t2 = performance.now();
out.innerHTML = clean;
void out.offsetHeight;
const t3 = performance.now();
(window as unknown as { __md: unknown }).__md = { parseMs: Math.round(t1 - t0), sanitizeMs: Math.round(t2 - t1), injectLayoutMs: Math.round(t3 - t2), totalMs: Math.round(t3 - t0) };
