import { useEffect, useRef, useState } from "react";
import type { PDFDocumentLoadingTask, PDFDocumentProxy, RenderTask } from "pdfjs-dist/legacy/build/pdf.mjs";
import workerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";
import { formatBytes, readFileBytes } from "../lib/fileBytes";

/**
 * Renders a local PDF with pdf.js, page by page onto canvases. It used to hand the
 * file to WebKit's PDF plug-in via <embed>, which WKWebView doesn't run inside a page
 * (a blank white box). pdf.js is loaded on first use, so it costs nothing until a PDF
 * is opened. Fit-to-width by default; −/+ zoom; pages draw when scrolled near.
 */

type PageSize = { w: number; h: number };

const ZOOMS = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];
const GAP = 12;
const SIDE = 24;

let pdfjsPromise: Promise<typeof import("pdfjs-dist/legacy/build/pdf.mjs")> | null = null;
function loadPdfjs() {
  pdfjsPromise ??= import("pdfjs-dist/legacy/build/pdf.mjs").then((m) => {
    m.GlobalWorkerOptions.workerSrc = workerUrl;
    return m;
  });
  return pdfjsPromise;
}

export default function PdfViewer({ path }: { path: string }) {
  const [doc, setDoc] = useState<PDFDocumentProxy | null>(null);
  const [sizes, setSizes] = useState<PageSize[]>([]);
  const [bytes, setBytes] = useState(0);
  const [error, setError] = useState("");
  const [zoom, setZoom] = useState(1);
  const [width, setWidth] = useState(0);
  const [current, setCurrent] = useState(1);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let cancelled = false;
    let task: PDFDocumentLoadingTask | null = null; // destroying it frees the document and worker
    setDoc(null);
    setSizes([]);
    setError("");
    setZoom(1);
    (async () => {
      try {
        const [pdfjs, buf] = await Promise.all([loadPdfjs(), readFileBytes(path)]);
        if (cancelled) return;
        setBytes(buf.byteLength);
        task = pdfjs.getDocument({ data: new Uint8Array(buf) });
        const loaded = await task.promise;
        if (cancelled) return;
        const out: PageSize[] = [];
        for (let i = 1; i <= loaded.numPages; i++) {
          const vp = (await loaded.getPage(i)).getViewport({ scale: 1 });
          out.push({ w: vp.width, h: vp.height });
        }
        if (cancelled) return;
        setSizes(out);
        setDoc(loaded);
      } catch (e) {
        if (!cancelled) setError(`${path.split("/").pop()} could not be opened as a PDF: ${e instanceof Error ? e.message : String(e)}`);
      }
    })();
    return () => {
      cancelled = true;
      void task?.destroy();
    };
  }, [path]);

  useEffect(() => {
    const el = scrollRef.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    setWidth(el.clientWidth);
    return () => ro.disconnect();
  }, []);

  const widest = sizes.reduce((m, s) => Math.max(m, s.w), 0);
  const fit = widest && width ? Math.max(0.1, (width - SIDE * 2) / widest) : 1;
  const scale = fit * zoom;

  // Which page is in view, for the "3 / 12" counter.
  const onScroll = () => {
    const el = scrollRef.current;
    if (!el || !sizes.length) return;
    let y = SIDE;
    const mid = el.scrollTop + el.clientHeight / 3;
    for (let i = 0; i < sizes.length; i++) {
      y += sizes[i].h * scale + GAP;
      if (y > mid) return setCurrent(i + 1);
    }
    setCurrent(sizes.length);
  };

  const step = (dir: 1 | -1) =>
    setZoom((z) => {
      const i = ZOOMS.findIndex((v) => v >= z - 1e-6);
      const next = ZOOMS[Math.min(ZOOMS.length - 1, Math.max(0, (i === -1 ? ZOOMS.length - 1 : i) + dir))];
      return next;
    });

  const btn = { width: 26, height: 24, borderRadius: 6, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 14 } as const;
  return (
    <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column", overflow: "hidden", background: "var(--bg-app)" }}>
      <div style={{ height: 32, flexShrink: 0, display: "flex", alignItems: "center", gap: 8, padding: "0 16px", borderBottom: "1px solid var(--border)", fontSize: 12, color: "var(--text-muted)", fontFamily: "var(--font-mono)" }}>
        <span aria-label="Page">{sizes.length ? `${current} / ${sizes.length}` : "—"}</span>
        <span>{bytes ? formatBytes(bytes) : ""}</span>
        <span style={{ flexGrow: 1 }} />
        <button type="button" aria-label="Zoom out" title="Zoom out" disabled={!doc || zoom <= ZOOMS[0]} onClick={() => step(-1)} style={btn}>−</button>
        <button type="button" title="Fit to width" disabled={!doc} onClick={() => setZoom(1)} style={{ ...btn, width: 52, fontSize: 12 }}>
          {Math.round(zoom * 100)}%
        </button>
        <button type="button" aria-label="Zoom in" title="Zoom in" disabled={!doc || zoom >= ZOOMS[ZOOMS.length - 1]} onClick={() => step(1)} style={btn}>+</button>
      </div>
      <div ref={scrollRef} onScroll={onScroll} data-testid="pdf-pages" style={{ flex: 1, minHeight: 0, overflow: "auto", background: "var(--bg-segment)" }}>
        {error ? (
          <div role="alert" style={{ padding: 16, fontSize: 12, fontFamily: "var(--font-mono)", color: "var(--danger-text)" }}>{error}</div>
        ) : !doc ? (
          <div style={{ padding: 16, fontSize: 12, color: "var(--text-muted)" }}>Loading…</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: GAP, padding: SIDE, minWidth: "fit-content" }}>
            {sizes.map((s, i) => (
              <PdfPage key={i} doc={doc} index={i + 1} width={s.w * scale} height={s.h * scale} scale={scale} root={scrollRef} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function PdfPage({ doc, index, width, height, scale, root }: { doc: PDFDocumentProxy; index: number; width: number; height: number; scale: number; root: React.RefObject<HTMLDivElement | null> }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [near, setNear] = useState(false);

  useEffect(() => {
    const el = canvasRef.current;
    if (!el || typeof IntersectionObserver === "undefined") return setNear(true);
    const io = new IntersectionObserver(([e]) => setNear(e.isIntersecting), { root: root.current, rootMargin: "600px 0px" });
    io.observe(el);
    return () => io.disconnect();
  }, [root]);

  useEffect(() => {
    if (!near) return;
    let task: RenderTask | null = null;
    let cancelled = false;
    void doc.getPage(index).then((page) => {
      const canvas = canvasRef.current;
      if (cancelled || !canvas) return;
      const dpr = window.devicePixelRatio || 1;
      const viewport = page.getViewport({ scale: scale * dpr });
      canvas.width = Math.floor(viewport.width);
      canvas.height = Math.floor(viewport.height);
      task = page.render({ canvas, viewport });
      task.promise.catch(() => {}); // cancelled on zoom/scroll — not an error
    });
    return () => {
      cancelled = true;
      task?.cancel();
    };
  }, [doc, index, scale, near]);

  return (
    <canvas
      ref={canvasRef}
      aria-label={`Page ${index}`}
      style={{ width, height, flexShrink: 0, background: "var(--pdf-paper)", boxShadow: "var(--pdf-page-shadow)" }}
    />
  );
}
