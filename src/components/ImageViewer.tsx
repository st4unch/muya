import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { convertFileSrc } from "@tauri-apps/api/core";

/**
 * Renders a local image file. `read_file` (used by the Monaco editor) requires
 * UTF-8 text and errors on binary — images go through Tauri's asset protocol
 * instead: grant this ONE file read access (`allow_asset_path`, file-scoped, not
 * the whole folder), then load it via `asset://` like any other <img> src.
 */
export default function ImageViewer({ path }: { path: string }) {
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
      <div className="flex-1 overflow-auto flex items-center justify-center bg-[repeating-conic-gradient(#00000008_0%_25%,transparent_0%_50%)] bg-[length:16px_16px] dark:bg-neutral-900">
        {status === "error" ? (
          <div className="p-4 text-xs font-mono text-rose-600 dark:text-red-400">{error}</div>
        ) : status === "loading" ? (
          <div className="text-xs font-mono text-neutral-400 dark:text-neutral-500">loading…</div>
        ) : (
          // eslint-disable-next-line jsx-a11y/img-redundant-alt -- filename IS the useful description here
          <img
            src={convertFileSrc(path)}
            alt={path.split("/").pop()}
            className="max-w-full max-h-full object-contain select-none"
            draggable={false}
          />
        )}
      </div>
    </div>
  );
}
