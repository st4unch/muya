// Created by Claude — Classification: INTERNAL
// Perf harness: mounts the real FileEditor with a mocked backend serving generated text.
// ?kind=json|log|ts|minjs|md &mb=20 &mode=policy|full
//   policy: file_probe reports the real size (what the app does)
//   full:   file_probe reports a tiny size, so the editor opens with every feature on
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import React from "react";
import ReactDOM from "react-dom/client";
import FileEditor from "../../src/components/FileEditor";
import "../../src/styles/tokens.css";
import "../../src/index.css";
import * as monaco from "monaco-editor";
import { EXT, generate, type Kind } from "./gen";

const q = new URLSearchParams(location.search);
const kind = (q.get("kind") ?? "json") as Kind;
const mb = Number(q.get("mb") ?? "1");
const mode = q.get("mode") ?? "policy";
const bytes = Math.round(mb * 1024 * 1024);

const t0 = performance.now();
const text = generate(kind, bytes);
const genMs = performance.now() - t0;
const head = text.replace(/\n/, "\nCHANGED LINE\n");
(window as unknown as { __perf: unknown }).__perf = { genMs, bytes: text.length, kind, mode, mountAt: 0 };

(window as unknown as { __monaco: unknown }).__monaco = monaco;
if (q.get("nodiag") === "1") {
  // experiment: language-service diagnostics off
  (monaco.languages as any).json?.jsonDefaults?.setDiagnosticsOptions({ validate: false });
  (monaco.languages as any).typescript?.typescriptDefaults?.setDiagnosticsOptions({ noSemanticValidation: true, noSyntaxValidation: true });
}
mockWindows("main");
mockIPC((cmd) => {
  switch (cmd) {
    case "file_probe":
      return { size: mode === "full" ? 100 : text.length, binary: false };
    case "read_file":
      return text;
    case "read_file_prefix":
      return text.slice(0, 8 * 1024 * 1024);
    case "read_head_file":
      return head;
    default:
      return null;
  }
});
document.documentElement.setAttribute("data-theme", q.get("theme") ?? "dark");
(window as unknown as { __perf: { mountAt: number } }).__perf.mountAt = performance.now();
ReactDOM.createRoot(document.getElementById("root")!).render(
  <div style={{ height: "100vh", display: "flex", flexDirection: "column" }}>
    <FileEditor path={`/r/big.${EXT[kind]}`} theme={(q.get("theme") as "dark" | "light") ?? "dark"} />
  </div>,
);
