import { describe, it, expect } from "vitest";
import { relTime, shortCwd, langFromPath, viewerKindFor, monacoModelPath } from "./format";

describe("relTime", () => {
  const now = 1_000_000_000_000;
  it("handles missing and recent", () => {
    expect(relTime(0, now)).toBe("—");
    expect(relTime(now, now)).toBe("just now");
    expect(relTime(now - 30_000, now)).toBe("just now");
  });
  it("formats minutes/hours/days", () => {
    expect(relTime(now - 5 * 60_000, now)).toBe("5m ago");
    expect(relTime(now - 2 * 3_600_000, now)).toBe("2h ago");
    expect(relTime(now - 3 * 86_400_000, now)).toBe("3d ago");
  });
});

describe("shortCwd", () => {
  it("collapses home prefix", () => {
    expect(shortCwd("/Users/staunch/Documents/x")).toBe("~/Documents/x");
  });
  it("leaves other paths untouched", () => {
    expect(shortCwd("/opt/data")).toBe("/opt/data");
  });
});

describe("langFromPath", () => {
  it("maps known extensions", () => {
    expect(langFromPath("a/b.tsx")).toBe("typescript");
    expect(langFromPath("Cargo.toml")).toBe("ini");
    expect(langFromPath("main.rs")).toBe("rust");
  });
  it("returns undefined for unknown", () => {
    expect(langFromPath("file.xyz")).toBeUndefined();
    expect(langFromPath("noext")).toBeUndefined();
  });
});

describe("viewerKindFor", () => {
  it("routes markdown to mdview", () => {
    expect(viewerKindFor("README.md")).toBe("mdview");
    expect(viewerKindFor("notes.MDX")).toBe("mdview");
  });
  it("routes images to imgview, case-insensitively", () => {
    for (const ext of ["png", "JPG", "jpeg", "gif", "webp", "bmp", "ico", "svg"]) {
      expect(viewerKindFor(`pic.${ext}`)).toBe("imgview");
    }
  });
  it("routes pdf to pdfview", () => {
    expect(viewerKindFor("report.pdf")).toBe("pdfview");
  });
  it("falls back to editor (Monaco) for everything else, including no extension", () => {
    expect(viewerKindFor("src/App.tsx")).toBe("editor");
    expect(viewerKindFor("Dockerfile")).toBe("editor");
    expect(viewerKindFor("archive.pdf.bak")).toBe("editor"); // extension is .bak, not .pdf
  });
});

describe("monacoModelPath: a filename must never be parsed as a URI scheme", () => {
  it("neutralises the colon that made Monaco throw UriError", () => {
    // macOS stores a Finder-displayed "Report 2026/08.csv" as "Report 2026:08.csv".
    const out = monacoModelPath("/Users/x/Downloads/Report 2026:08.csv");
    expect(out).not.toContain(":");
    expect(out.endsWith(".csv")).toBe(true); // language detection still works
  });

  it("keeps the extension for every common type", () => {
    expect(monacoModelPath("/a/b.ts").endsWith(".ts")).toBe(true);
    expect(monacoModelPath("/a/b c.json").endsWith(".json")).toBe(true);
  });

  it("gives same-named files in different folders distinct model paths", () => {
    expect(monacoModelPath("/one/a.csv")).not.toBe(monacoModelPath("/two/a.csv"));
  });
});
