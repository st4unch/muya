// Browser-only mock backend for the redesign pixel diff (?mock=1, dev builds only).
// Must stay the first import — see src/mock/boot.ts.
import "./mock/boot";
import React, { Profiler } from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
// Bundled fonts (offline app — no Google Fonts). Weights per
// docs/design/redesign-v0.4/PROMPT.md §1: IBM Plex Sans 400/500/600,
// JetBrains Mono 400/500/700.
import "@fontsource/ibm-plex-sans/400.css";
import "@fontsource/ibm-plex-sans/500.css";
import "@fontsource/ibm-plex-sans/600.css";
import "@fontsource/jetbrains-mono/400.css";
import "@fontsource/jetbrains-mono/500.css";
import "@fontsource/jetbrains-mono/700.css";
import "./styles/tokens.css";
import "./index.css";
import { startPerfHarness, recordCommit } from "./perf/harness";
import { invoke } from "@tauri-apps/api/core";

// Forward uncaught frontend errors to the Rust log file (tauri-plugin-log) so
// problems on another machine can be diagnosed from the log.
window.addEventListener("error", (e) => {
  void invoke("frontend_log", {
    level: "error",
    message: `${e.message} @ ${e.filename}:${e.lineno}:${e.colno}`,
  }).catch(() => {});
});
window.addEventListener("unhandledrejection", (e) => {
  void invoke("frontend_log", { level: "error", message: `unhandledrejection: ${String(e.reason)}` }).catch(() => {});
});

const perf = import.meta.env.VITE_APEX_PERF === "1";

// Dev-only: record every App commit's actual duration so the harness can show
// how much main-thread time each poll-driven re-render burns. No-op in prod.
const onCommit = perf
  ? (_id: string, _phase: "mount" | "update" | "nested-update", actualDuration: number) =>
      recordCommit(actualDuration)
  : undefined;

// Disable browser right-click context menu (prevents accidental devtools open).
document.addEventListener("contextmenu", (e) => e.preventDefault());

const tree = perf ? (
  <Profiler id="App" onRender={onCommit!}>
    <App />
  </Profiler>
) : (
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(tree);

if (perf) startPerfHarness();
