import "@testing-library/jest-dom";

// The jsdom environment hands back a bare object for `localStorage` (no
// getItem/setItem), so anything that persists UI state — SSH group collapse,
// App.tsx panel widths — is untestable. Install a minimal in-memory Storage.
if (typeof localStorage?.getItem !== "function") {
  const mem = new Map<string, string>();
  const storage: Storage = {
    get length() {
      return mem.size;
    },
    clear: () => mem.clear(),
    getItem: (k) => mem.get(String(k)) ?? null,
    key: (i) => [...mem.keys()][i] ?? null,
    removeItem: (k) => void mem.delete(String(k)),
    setItem: (k, v) => void mem.set(String(k), String(v)),
  };
  Object.defineProperty(globalThis, "localStorage", { value: storage, configurable: true });
}
