import React from "react";
import { invoke } from "@tauri-apps/api/core";
import { AlertTriangle } from "lucide-react";

/**
 * Contains a failure inside ONE tab's viewer instead of letting it blank the app.
 *
 * The viewers (FileEditor/Monaco ~3.7 MB, MarkdownView, ImageViewer, PdfViewer) are
 * `React.lazy`, and this codebase had no error boundary anywhere: if a lazy chunk
 * failed to load, or a viewer threw while rendering, React unmounted the ENTIRE tree
 * and the operator got a black window with no message and nothing in the log — a
 * dead app with zero diagnostic value (reported 2026-08-26, opening a .csv on a
 * different machine).
 *
 * A boundary turns that into: the rest of Muya keeps working, the failing tab shows
 * what went wrong, and the error reaches the persistent log via `frontend_log` so it
 * can actually be diagnosed afterwards.
 */
export default class ViewerErrorBoundary extends React.Component<
  { children: React.ReactNode; label?: string },
  { error: Error | null }
> {
  state: { error: Error | null } = { error: null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    // Best-effort: never let logging itself throw and re-break the boundary.
    void invoke("frontend_log", {
      level: "error",
      message:
        `viewer crash${this.props.label ? ` [${this.props.label}]` : ""}: ` +
        `${error?.message ?? error}\n${info?.componentStack ?? ""}`.slice(0, 4000),
    }).catch(() => {});
  }

  /** Reset when the tab switches to a different file, so one bad file doesn't
   *  poison the viewer for every subsequent one. */
  componentDidUpdate(prev: { label?: string }) {
    if (prev.label !== this.props.label && this.state.error) {
      this.setState({ error: null });
    }
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="flex-1 flex flex-col items-center justify-center gap-2 p-6 text-center">
        <AlertTriangle className="h-5 w-5 text-amber-500" />
        <p className="text-xs font-semibold text-neutral-700 dark:text-neutral-200">
          This file couldn&apos;t be displayed
        </p>
        <p className="text-[11px] text-neutral-500 dark:text-neutral-400 max-w-md break-words">
          {this.state.error.message || String(this.state.error)}
        </p>
        <p className="text-[10px] text-neutral-400 dark:text-neutral-500">
          The rest of Muya is unaffected — close this tab and carry on. The full error
          is in the app log.
        </p>
        <button
          type="button"
          onClick={() => this.setState({ error: null })}
          className="mt-1 text-[11px] px-2 py-1 rounded border border-neutral-300 dark:border-neutral-600 hover:bg-neutral-100 dark:hover:bg-neutral-800"
        >
          Try again
        </button>
      </div>
    );
  }
}
