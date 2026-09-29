// Dev-only entry point used to verify the mock backend renders the app outside
// Tauri (Playwright against `npm run dev`, or a manual browser check). NOT
// referenced by index.html / main.tsx — the orchestrator wires `maybeInstallMock()`
// into the real entry (see installMock.ts's top comment for the one-line change).
//
// Installs the mock (only takes effect given `?mock=1` — see installMock.ts's own
// guards) and THEN imports the real app entry, so App.tsx's `useState` initializers
// (which read localStorage synchronously on first render) see the seeded fixture
// data.
import { maybeInstallMock } from "./installMock";

maybeInstallMock();

await import("../main");
