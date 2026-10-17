import { describe, expect, it } from "vitest";
import { escapeForShell, isWebUrl } from "./termMenu";

describe("escapeForShell", () => {
  it("backslashes spaces and shell characters so a path stays one word", () => {
    expect(escapeForShell("/Users/a/My Files/x (1).txt")).toBe("/Users/a/My\\ Files/x\\ \\(1\\).txt");
    expect(escapeForShell("a&b;c$d'e\"f")).toBe("a\\&b\\;c\\$d\\'e\\\"f");
  });
  it("drops one trailing newline so the pasted path is not run", () => {
    expect(escapeForShell("/tmp/x\n")).toBe("/tmp/x");
  });
  it("leaves plain paths untouched", () => {
    expect(escapeForShell("/usr/local/bin/tool-1.2_x")).toBe("/usr/local/bin/tool-1.2_x");
  });
});

describe("isWebUrl", () => {
  it("accepts one http(s) URL", () => {
    expect(isWebUrl(" https://github.com/st4unch/muya ")).toBe(true);
    expect(isWebUrl("http://localhost:1420/?mock=1")).toBe(true);
  });
  it("rejects anything else", () => {
    expect(isWebUrl("see https://a.com now")).toBe(false);
    expect(isWebUrl("file:///etc/hosts")).toBe(false);
    expect(isWebUrl("javascript:alert(1)")).toBe(false);
    expect(isWebUrl("")).toBe(false);
  });
});
