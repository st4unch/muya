import { describe, expect, it } from "vitest";
import { contentTerms, describeQuery, isEmptyQuery, parseSessionQuery, sessionMatches } from "./sessionQuery";

const muya = { id: "9d210ed5-aaaa", name: "muya-all", path: "/Users/x/Documents/claude-control-plane", branch: "main", status: "working" };
const other = { id: "0fb9a9ac-bbbb", name: "Kitap satış", path: "/Users/x/Documents/alisveris", branch: "", status: "idle" };

describe("parseSessionQuery", () => {
  it("reads filters, aliases, quotes and free words", () => {
    const q = parseSessionQuery('session=Muya include:v4.1 in="release notes" path=control dir=plane branch=main id=9d21 hello world');
    expect(q.name).toEqual(["muya"]);
    expect(q.include).toEqual(["v4.1", "release notes"]);
    expect(q.path).toEqual(["control", "plane"]);
    expect(q.branch).toEqual(["main"]);
    expect(q.id).toEqual(["9d21"]);
    expect(q.free).toBe("hello world");
  });

  it("keeps unknown keys and empty values as plain text / ignores them", () => {
    const q = parseSessionQuery("foo=bar session= x");
    expect(q.name).toEqual([]);
    expect(q.free).toBe("foo=bar x");
    expect(isEmptyQuery(parseSessionQuery("   "))).toBe(true);
  });
});

describe("sessionMatches", () => {
  it("session=muya include=v4.1: only muya sessions whose conversation has v4.1", () => {
    const q = parseSessionQuery("session=muya include=v4.1");
    expect(contentTerms(q)).toEqual(["v4.1"]);
    expect(sessionMatches(q, muya, true)).toBe(true);
    expect(sessionMatches(q, muya, false)).toBe(false); // name fits, text missing
    expect(sessionMatches(q, other, true)).toBe(false); // text found, wrong session
  });

  it("session= alone needs no content search", () => {
    const q = parseSessionQuery("s=MUYA");
    expect(contentTerms(q)).toEqual([]);
    expect(sessionMatches(q, muya, false)).toBe(true);
    expect(sessionMatches(q, other, false)).toBe(false);
  });

  it("plain text still matches details or the conversation (old behavior)", () => {
    const q = parseSessionQuery("alisveris");
    expect(contentTerms(q)).toEqual(["alisveris"]);
    expect(sessionMatches(q, other, false)).toBe(true); // in the path
    expect(sessionMatches(q, muya, true)).toBe(true); // in the conversation
    expect(sessionMatches(q, muya, false)).toBe(false);
  });

  it("id= is a prefix, path=/branch= are contains", () => {
    expect(sessionMatches(parseSessionQuery("id=9d21"), muya, false)).toBe(true);
    expect(sessionMatches(parseSessionQuery("id=aaaa"), muya, false)).toBe(false);
    expect(sessionMatches(parseSessionQuery("path=control branch=main"), muya, false)).toBe(true);
    expect(sessionMatches(parseSessionQuery("branch=dev"), muya, false)).toBe(false);
  });

  it("describes what it is filtering on", () => {
    expect(describeQuery(parseSessionQuery("session=muya include=v4.1"))).toEqual(['name contains "muya"', 'conversation contains "v4.1"']);
  });
});
