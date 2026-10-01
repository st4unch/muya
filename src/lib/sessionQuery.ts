// Created by Claude — Classification: INTERNAL
//
// Sessions search language. Plain words search everywhere (name, folder, branch, id
// and inside the conversation), which on a long history matches almost everything.
// Filters narrow it down and combine with AND:
//
//   session=muya            the session's NAME contains "muya"   (also name=, s=)
//   include=v4.1            the CONVERSATION contains "v4.1"     (also text=, in=, has=)
//   path=control-plane      the working folder contains it       (also cwd=, dir=)
//   branch=main             the git branch contains it           (live sessions)
//   id=9d21                 the session id starts with it
//
// `key:value` works too, values with spaces go in quotes (include="release notes"),
// and repeating a filter requires all of its values.

export interface SessionQuery {
  name: string[];
  include: string[];
  path: string[];
  branch: string[];
  id: string[];
  /** Words without a filter key — matched anywhere, as before. */
  free: string;
}

const KEYS: Record<string, keyof Omit<SessionQuery, "free">> = {
  session: "name",
  name: "name",
  s: "name",
  include: "include",
  text: "include",
  in: "include",
  has: "include",
  path: "path",
  cwd: "path",
  dir: "path",
  folder: "path",
  branch: "branch",
  id: "id",
};

/** The filter keys, for the hint under the search box. */
export const FILTER_HINT = "session=  include=  path=  branch=  id=";

export function parseSessionQuery(input: string): SessionQuery {
  const q: SessionQuery = { name: [], include: [], path: [], branch: [], id: [], free: "" };
  const free: string[] = [];
  // key=value | key:value | key="quoted value" | "quoted words" | word
  const re = /(\w+)[=:](?:"([^"]*)"?|(\S*))|"([^"]*)"?|(\S+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(input)) !== null) {
    const [, key, quotedVal, val, quoted, word] = m;
    if (key !== undefined) {
      const field = KEYS[key.toLowerCase()];
      const v = (quotedVal ?? val ?? "").trim();
      if (field) {
        if (v) q[field].push(v.toLowerCase());
        continue;
      }
      free.push(m[0]); // unknown key: treat "foo=bar" as plain text
      continue;
    }
    const w = (quoted ?? word ?? "").trim();
    if (w) free.push(w);
  }
  q.free = free.join(" ").toLowerCase();
  return q;
}

export function isEmptyQuery(q: SessionQuery): boolean {
  return !q.free && !q.name.length && !q.include.length && !q.path.length && !q.branch.length && !q.id.length;
}

/** What the backend should grep transcripts for: the include= terms when given (all
 *  must appear), else the free text (≥2 chars), else nothing. */
export function contentTerms(q: SessionQuery): string[] {
  if (q.include.length) return q.include;
  return q.free.length >= 2 ? [q.free] : [];
}

export interface SessionFields {
  id: string;
  name: string;
  path: string;
  branch?: string;
  status?: string;
}

/**
 * Does a session pass the query? `contentHit` = every content term was found in its
 * transcript (from the backend). Filters AND together; free text matches the visible
 * fields OR the conversation (when it was searched as content).
 */
export function sessionMatches(q: SessionQuery, s: SessionFields, contentHit: boolean): boolean {
  const name = s.name.toLowerCase();
  const path = s.path.toLowerCase();
  const branch = (s.branch ?? "").toLowerCase();
  const id = s.id.toLowerCase();
  if (!q.name.every((v) => name.includes(v))) return false;
  if (!q.path.every((v) => path.includes(v))) return false;
  if (!q.branch.every((v) => branch.includes(v))) return false;
  if (!q.id.every((v) => id.startsWith(v))) return false;
  if (q.include.length && !contentHit) return false;
  if (q.free) {
    const meta = [name, path, branch, id, (s.status ?? "").toLowerCase()].some((f) => f.includes(q.free));
    // With include= the free words are only a metadata filter; without, the
    // conversation counts too (the old behavior).
    if (!meta && (q.include.length || !contentHit)) return false;
  }
  return true;
}

/** Human-readable reading of a query, for the line under the search box. */
export function describeQuery(q: SessionQuery): string[] {
  const out: string[] = [];
  const list = (vs: string[]) => vs.map((v) => `"${v}"`).join(" and ");
  if (q.name.length) out.push(`name contains ${list(q.name)}`);
  if (q.include.length) out.push(`conversation contains ${list(q.include)}`);
  if (q.path.length) out.push(`folder contains ${list(q.path)}`);
  if (q.branch.length) out.push(`branch contains ${list(q.branch)}`);
  if (q.id.length) out.push(`id starts with ${list(q.id)}`);
  if (q.free) out.push(q.include.length ? `details contain "${q.free}"` : `"${q.free}" anywhere`);
  return out;
}
