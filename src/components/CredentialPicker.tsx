import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Plus } from "lucide-react";

// Reusable "pick a credential from the encrypted Password Store, or save a new
// one" control. Used by the SSH CyberArk form and any future flow that needs a
// credential (direct SSH prompt, etc.). The picker stores only a REFERENCE
// (credential id) — the secret is pulled by Rust at use time and never revealed
// to the JS/webview layer.

export type CredMeta = { id: string; label: string; username: string; secretKind: "password" | "key" | "token" | "api_key"; description?: string };
export type CyberarkAccountRef = { id: string; name: string; username: string; address: string };
export type CredentialSource = {
  kind: "prompt" | "local" | "cyberark";
  localCredId?: string | null;
  cyberarkAccountId?: string | null;
};

const INPUT =
  "w-full px-2.5 py-1.5 rounded border border-neutral-300 dark:border-[#3d3f44] bg-white dark:bg-[#1e1f23] text-sm outline-none focus:border-indigo-500";
const BTN =
  "px-3 py-1.5 rounded text-sm font-medium bg-indigo-600 hover:bg-indigo-500 text-white disabled:opacity-50 cursor-pointer";
const BTN_GHOST =
  "px-2.5 py-1.5 rounded text-sm text-neutral-600 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-[#2f3136] cursor-pointer";

const PROMPT = "__prompt__";

const CYBER = "cyber:";
const LOCAL = "local:";

export default function CredentialPicker({
  creds,
  unlocked,
  value,
  onChange,
  onRefresh,
  setErr,
  promptLabel = "Ask each time (session-only)",
  cyberarkAccounts,
}: {
  creds: CredMeta[];
  unlocked: boolean;
  value: CredentialSource;
  onChange: (v: CredentialSource) => void;
  onRefresh: () => Promise<void>;
  setErr: (e: string | null) => void;
  promptLabel?: string;
  /** When provided, the picker also offers CyberArk accounts (server credential source). */
  cyberarkAccounts?: CyberarkAccountRef[];
}) {
  const [adding, setAdding] = useState<{ label: string; username: string; secret: string } | null>(null);

  // Single select carries prompt / local:<id> / cyber:<id>; prefixes avoid id collisions.
  const selectValue =
    value.kind === "local" && value.localCredId
      ? `${LOCAL}${value.localCredId}`
      : value.kind === "cyberark" && value.cyberarkAccountId
        ? `${CYBER}${value.cyberarkAccountId}`
        : PROMPT;

  const saveNew = async () => {
    if (!adding) return;
    try {
      const id = await invoke<string>("credstore_cred_upsert", {
        cred: { label: adding.label || adding.username, username: adding.username, secretKind: "password", secret: adding.secret },
      });
      setAdding(null);
      await onRefresh();
      onChange({ kind: "local", localCredId: id }); // auto-select the new one
    } catch (e) {
      setErr(String(e));
    }
  };

  return (
    <div className="space-y-2">
      <div className="flex gap-2 items-center">
        <select
          className={INPUT}
          value={selectValue}
          onChange={(e) => {
            const v = e.target.value;
            if (v === PROMPT) onChange({ kind: "prompt" });
            else if (v.startsWith(CYBER)) onChange({ kind: "cyberark", cyberarkAccountId: v.slice(CYBER.length) });
            else onChange({ kind: "local", localCredId: v.startsWith(LOCAL) ? v.slice(LOCAL.length) : v });
          }}
        >
          <option value={PROMPT}>{promptLabel}</option>
          {creds
            .filter((c) => c.secretKind === "password")
            .map((c) => (
              <option key={c.id} value={`${LOCAL}${c.id}`}>
                From store: {c.label} ({c.username})
              </option>
            ))}
          {cyberarkAccounts?.map((a) => (
            <option key={a.id} value={`${CYBER}${a.id}`}>
              CyberArk: {a.name || a.address} ({a.username})
            </option>
          ))}
        </select>
        {unlocked && (
          <button type="button" className={BTN_GHOST} title="Save a new credential to the store" onClick={() => setAdding({ label: "", username: "", secret: "" })}>
            <Plus className="h-4 w-4" />
          </button>
        )}
      </div>

      {!unlocked && (
        <p className="text-[11px] text-neutral-400">
          Unlock the Password Store (Password Store tab) to pick or save a credential.
        </p>
      )}

      {adding && (
        <div className="rounded border border-neutral-200 dark:border-[#3d3f44] p-2 space-y-2">
          <div className="text-xs font-medium">Save new credential to store</div>
          <div className="grid grid-cols-3 gap-2">
            <input className={INPUT} placeholder="Label" value={adding.label} onChange={(e) => setAdding({ ...adding, label: e.target.value })} />
            <input className={INPUT} placeholder="Username" value={adding.username} onChange={(e) => setAdding({ ...adding, username: e.target.value })} />
            <input type="password" className={INPUT} placeholder="Password" value={adding.secret} onChange={(e) => setAdding({ ...adding, secret: e.target.value })} />
          </div>
          <div className="flex gap-2 justify-end">
            <button type="button" className={BTN_GHOST} onClick={() => setAdding(null)}>Cancel</button>
            <button type="button" className={BTN} onClick={saveNew}>Save & use</button>
          </div>
        </div>
      )}
    </div>
  );
}
