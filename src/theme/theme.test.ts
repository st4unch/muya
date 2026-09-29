import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { renderHook, act } from "@testing-library/react";
import {
  resolveTheme,
  nextPreference,
  applyThemeToDocument,
  readStoredPreference,
  storePreference,
  THEME_STORAGE_KEY,
  useTheme,
} from "./theme";

describe("resolveTheme (pure)", () => {
  it("system follows the OS", () => {
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");
  });
  it("an explicit preference ignores the OS", () => {
    expect(resolveTheme("light", true)).toBe("light");
    expect(resolveTheme("dark", false)).toBe("dark");
  });
});

describe("nextPreference (§6 cycle order)", () => {
  it("system -> light -> dark -> system", () => {
    expect(nextPreference("system")).toBe("light");
    expect(nextPreference("light")).toBe("dark");
    expect(nextPreference("dark")).toBe("system");
  });
});

describe("applyThemeToDocument", () => {
  it("sets data-theme and toggles the legacy .dark class", () => {
    const root = document.createElement("html");
    applyThemeToDocument("dark", root);
    expect(root.dataset.theme).toBe("dark");
    expect(root.classList.contains("dark")).toBe(true);

    applyThemeToDocument("light", root);
    expect(root.dataset.theme).toBe("light");
    expect(root.classList.contains("dark")).toBe(false);
  });
});

describe("stored preference round-trip", () => {
  beforeEach(() => localStorage.clear());

  it("defaults to system when nothing is stored", () => {
    expect(readStoredPreference()).toBe("system");
  });

  it("round-trips a valid stored value", () => {
    storePreference("dark");
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("dark");
    expect(readStoredPreference()).toBe("dark");
  });

  it("falls back to system for a garbage stored value", () => {
    localStorage.setItem(THEME_STORAGE_KEY, "purple");
    expect(readStoredPreference()).toBe("system");
  });
});

// --- matchMedia mock plumbing ------------------------------------------------
// jsdom has no matchMedia implementation; useTheme needs one that supports the
// modern addEventListener/removeEventListener("change", …) API so the hook can
// live-track OS theme changes.
function installMatchMediaMock(initialDark: boolean) {
  let dark = initialDark;
  const listeners = new Set<(e: MediaQueryListEvent) => void>();
  const mql = {
    get matches() {
      return dark;
    },
    media: "(prefers-color-scheme: dark)",
    addEventListener: (_: "change", cb: (e: MediaQueryListEvent) => void) => listeners.add(cb),
    removeEventListener: (_: "change", cb: (e: MediaQueryListEvent) => void) => listeners.delete(cb),
    // Legacy API some code paths may still call — harmless no-ops here.
    addListener: () => {},
    removeListener: () => {},
    dispatchEvent: () => true,
    onchange: null,
  } as unknown as MediaQueryList;

  vi.stubGlobal(
    "matchMedia",
    vi.fn().mockImplementation(() => mql)
  );

  return {
    setDark(next: boolean) {
      dark = next;
      const event = { matches: next } as MediaQueryListEvent;
      for (const cb of listeners) cb(event);
    },
  };
}

describe("useTheme (live system tracking + cycle)", () => {
  beforeEach(() => {
    localStorage.clear();
    document.documentElement.removeAttribute("data-theme");
    document.documentElement.classList.remove("dark");
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("resolves to the current OS theme under the default 'system' preference", () => {
    installMatchMediaMock(true);
    const { result } = renderHook(() => useTheme());
    expect(result.current.preference).toBe("system");
    expect(result.current.resolved).toBe("dark");
    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
  });

  it("live-tracks a system theme change while preference stays 'system'", () => {
    const mock = installMatchMediaMock(false);
    const { result } = renderHook(() => useTheme());
    expect(result.current.resolved).toBe("light");

    act(() => mock.setDark(true));

    expect(result.current.resolved).toBe("dark");
    expect(document.documentElement.dataset.theme).toBe("dark");
  });

  it("an explicit preference is not moved by a system change", () => {
    const mock = installMatchMediaMock(false);
    const { result } = renderHook(() => useTheme());

    act(() => result.current.setPreference("light"));
    expect(result.current.resolved).toBe("light");

    act(() => mock.setDark(true));
    // Still "light" — explicit preference overrides the OS.
    expect(result.current.resolved).toBe("light");
    expect(result.current.preference).toBe("light");
  });

  it("cycle() advances system -> light -> dark -> system and persists each step", () => {
    installMatchMediaMock(false);
    const { result } = renderHook(() => useTheme());

    act(() => result.current.cycle());
    expect(result.current.preference).toBe("light");
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("light");

    act(() => result.current.cycle());
    expect(result.current.preference).toBe("dark");
    expect(result.current.resolved).toBe("dark");

    act(() => result.current.cycle());
    expect(result.current.preference).toBe("system");
  });
});
