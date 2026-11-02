// Production bundle that still contains the browser mock (`?mock=1`), so the UI load
// test measures minified React without StrictMode double effects or dev-server HMR.
import { fileURLToPath } from "node:url";
import base from "../../vite.config.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));
const cfg = typeof base === "function" ? await base({ command: "build", mode: "production" }) : base;

export default {
  ...cfg,
  root,
  // The mock only installs when DEV is true (src/mock/boot.ts).
  define: { ...(cfg.define ?? {}), "import.meta.env.DEV": "true" },
  build: { ...(cfg.build ?? {}), outDir: fileURLToPath(new URL("../../node_modules/.loadtest-dist", import.meta.url)), emptyOutDir: true },
  preview: { port: 1431, strictPort: true },
};
