import { useEffect, useState } from "react";
import { formatBytes, imageMime, readFileBytes } from "../lib/fileBytes";

/**
 * Renders a local image file from its bytes (`read_file_bytes` → blob: URL). The asset
 * protocol it used before refused some paths (dot-folders) and showed nothing. Fit to
 * the area by default; "100%" shows real pixels with scrolling.
 */
export default function ImageViewer({ path }: { path: string }) {
  const [src, setSrc] = useState<string | null>(null);
  const [bytes, setBytes] = useState(0);
  const [error, setError] = useState("");
  const [dims, setDims] = useState<{ w: number; h: number } | null>(null);
  const [actual, setActual] = useState(false);

  useEffect(() => {
    let url: string | null = null;
    let cancelled = false;
    setSrc(null);
    setError("");
    setDims(null);
    readFileBytes(path)
      .then((buf) => {
        if (cancelled) return;
        url = URL.createObjectURL(new Blob([buf], { type: imageMime(path) }));
        setBytes(buf.byteLength);
        setSrc(url);
      })
      .catch((e) => !cancelled && setError(String(e)));
    return () => {
      cancelled = true;
      if (url) URL.revokeObjectURL(url);
    };
  }, [path]);

  const name = path.split("/").pop() ?? path;
  return (
    <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column", overflow: "hidden", background: "var(--bg-app)" }}>
      <div
        style={{
          height: 32,
          flexShrink: 0,
          display: "flex",
          alignItems: "center",
          gap: 12,
          padding: "0 16px",
          borderBottom: "1px solid var(--border)",
          fontSize: 12,
          color: "var(--text-muted)",
          fontFamily: "var(--font-mono)",
        }}
      >
        <span>{dims ? `${dims.w} × ${dims.h}` : "—"}</span>
        <span>{bytes ? formatBytes(bytes) : ""}</span>
        <span style={{ flexGrow: 1 }} />
        <button
          type="button"
          onClick={() => setActual((a) => !a)}
          disabled={!src}
          title={actual ? "Fit to the window" : "Show actual pixels"}
          style={{ height: 24, padding: "0 10px", borderRadius: 6, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 12 }}
        >
          {actual ? "Fit" : "100%"}
        </button>
      </div>
      <div
        style={{
          flex: 1,
          minHeight: 0,
          overflow: "auto",
          display: "flex",
          alignItems: actual ? "flex-start" : "center",
          justifyContent: actual ? "flex-start" : "center",
          padding: 16,
          // Checkerboard so transparent images read as transparent.
          backgroundImage:
            "repeating-conic-gradient(color-mix(in srgb, var(--text) 7%, transparent) 0% 25%, transparent 0% 50%)",
          backgroundSize: "16px 16px",
        }}
      >
        {error ? (
          <div role="alert" style={{ fontSize: 12, fontFamily: "var(--font-mono)", color: "var(--danger-text)", maxWidth: 560 }}>
            {error}
          </div>
        ) : !src ? (
          <div style={{ fontSize: 12, color: "var(--text-muted)" }}>Loading…</div>
        ) : (
          <img
            src={src}
            alt={name}
            draggable={false}
            onLoad={(e) => setDims({ w: e.currentTarget.naturalWidth, h: e.currentTarget.naturalHeight })}
            onError={() => setError(`${name} could not be shown as an image.`)}
            style={actual ? { flexShrink: 0 } : { maxWidth: "100%", maxHeight: "100%", objectFit: "contain" }}
          />
        )}
      </div>
    </div>
  );
}
