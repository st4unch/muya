import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { convertFileSrc } from "@tauri-apps/api/core";

/**
 * Renders a local PDF via the OS's built-in PDF viewer, embedded through Tauri's
 * asset protocol (same file-scoped `allow_asset_path` grant as ImageViewer — see
 * that file's comment for why images/PDFs can't go through `read_file`/Monaco).
 * WebKit (macOS) renders `<embed type="application/pdf">` with native PDF.js-like
 * chrome (zoom, search, page nav) for free.
 */
export default function PdfViewer({ path }: { path: string }) {
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    setStatus("loading");
    invoke("allow_asset_path", { path })
      .then(() => { if (!cancelled) setStatus("ready"); })
      .catch((e) => { if (!cancelled) { setError(String(e)); setStatus("error"); } });
    return () => { cancelled = true; };
  }, [path]);

  return (
    <div className="flex-1 flex flex-col overflow-hidden">
      <div className="px-3 py-1 border-b border-neutral-200 dark:border-[#3d3f44] bg-neutral-50 dark:bg-[#1e1f23] text-[10px] font-mono text-neutral-500 dark:text-neutral-400 shrink-0">
        {path}
      </div>
      <div className="flex-1 overflow-hidden bg-neutral-200 dark:bg-neutral-800">
        {status === "error" ? (
          <div className="p-4 text-xs font-mono text-rose-600 dark:text-red-400">{error}</div>
        ) : status === "loading" ? (
          <div className="p-4 text-xs font-mono text-neutral-400 dark:text-neutral-500">loading…</div>
        ) : (
          <embed src={convertFileSrc(path)} type="application/pdf" className="w-full h-full" />
        )}
      </div>
    </div>
  );
}
