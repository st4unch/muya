// Created by Claude — Classification: INTERNAL
//
// Shared Monaco setup (FileEditor, ReviewDiffPane).
import { loader } from "@monaco-editor/react";
import * as monaco from "monaco-editor";
import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import jsonWorker from "monaco-editor/esm/vs/language/json/json.worker?worker";
import cssWorker from "monaco-editor/esm/vs/language/css/css.worker?worker";
import htmlWorker from "monaco-editor/esm/vs/language/html/html.worker?worker";
import tsWorker from "monaco-editor/esm/vs/language/typescript/ts.worker?worker";

// Use the locally-bundled Monaco (no CDN fetch — matters for an offline, security-
// conscious desktop app) and wire its web workers through Vite.
self.MonacoEnvironment = {
  getWorker(_: unknown, label: string) {
    if (label === "json") return new jsonWorker();
    if (label === "css" || label === "scss" || label === "less") return new cssWorker();
    if (label === "html" || label === "handlebars" || label === "razor")
      return new htmlWorker();
    if (label === "typescript" || label === "javascript") return new tsWorker();
    return new editorWorker();
  },
};
loader.config({ monaco });

// Monaco decides "too large for tokenization / folding / bracket matching" at MODEL creation
// (300k lines or 20 MB) from the global `editor.largeFileOptimizations` setting. @monaco-editor/react
// creates the model BEFORE the editor, so the option passed to <Editor options> comes too late.
// Creating (and disposing) one throwaway editor with the option false writes it to the global
// configuration; our own policy (lib/largeFile.ts) decides when a file is degraded instead.
if (typeof document !== "undefined") {
  const probe = document.createElement("div");
  monaco.editor.create(probe, { largeFileOptimizations: false, automaticLayout: false }).dispose();
}
