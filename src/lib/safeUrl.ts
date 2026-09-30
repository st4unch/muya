/** True only for a parseable `https:` URL — the gate before handing data from disk or a
 *  marketplace to the system opener. */
export function isHttpsUrl(v: unknown): v is string {
  if (typeof v !== "string") return false;
  try {
    return new URL(v).protocol === "https:";
  } catch {
    return false;
  }
}
