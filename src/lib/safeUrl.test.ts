import { describe, it, expect } from "vitest";
import { isHttpsUrl } from "./safeUrl";

describe("isHttpsUrl", () => {
  it("accepts https only", () => {
    expect(isHttpsUrl("https://github.com/a/b")).toBe(true);
    for (const bad of ["http://x.com", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "/rel/path", "", "not a url", undefined, null, 5])
      expect(isHttpsUrl(bad)).toBe(false);
  });
});
