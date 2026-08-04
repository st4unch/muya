import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  Server as ServerIcon,
  ShieldCheck,
  Lock,
  Unlock,
  Plus,
  Trash2,
  KeyRound,
  Pencil,
  X,
  Eye,
  EyeOff,
  Download,
  Upload,
  Copy,
  Check,
  Loader2,
} from "lucide-react";

import CredentialPicker from "./CredentialPicker";

// Small dev/prod-safe helpers around the Tauri dialog plugin.
async function pickSavePath(title: string, defaultPath: string): Promise<string | null> {
  const { save } = await import("@tauri-apps/plugin-dialog");
  return (await save({ title, defaultPath })) as string | null;
}
async function pickOpenPath(title: string): Promise<string | null> {
  const { open } = await import("@tauri-apps/plugin-dialog");
  const r = await open({ title, multiple: false, directory: false });
  return (typeof r === "string" ? r : null) as string | null;
}

// ---- Types (mirror src-tauri/src/ssh.rs + credstore.rs serde shapes) --------
type CredentialSource = {
  kind: "prompt" | "local" | "cyberark";
  localCredId?: string | null;
  cyberarkAccountId?: string | null;
};
type Server = {
  id: string;
  label: string;
  host: string;
  port: number;
  username: string;
  connectionType: "direct" | "psmp";
  psmpProfileId?: string | null;
  credentialSource: CredentialSource;
  /** Opt-in: may the muya-ssh MCP broker expose this server to Claude agents? */
  agentAccess?: boolean;
  /** Provenance: was this server registered by a Claude agent via ssh_add_server? */
  agentAdded?: boolean;
  /** Extra raw ssh CLI options, e.g. `-X -L 8080:localhost:80 -J jump@host`. */
  sshOptions?: string | null;
  lastConnectedAt?: string | null;
  tags: string[];
};
type PsmpProfile = {
  id: string;
  label: string;
  psmpAddress: string;
  vaultUser: string;
  userDelim: string;
  paramDelim: string;
  // ssh_scp (PRD ssh-scp, AC5): extra `-o KEY=VAL …` tokens this PSMP profile's
  // scp transfers need. The agent can never set `-o` itself — this is the ONLY
  // way scp gets PSMP-required `-o` options, operator-authored only.
  scpOptions?: string;
};
type CyberarkConfig = {
  baseUrl: string;
  username: string;
  authMethod: "Cyberark" | "LDAP" | "RADIUS" | "Windows";
  tlsVerify: boolean;
  caCertPath?: string | null;
  credentialSource: CredentialSource;
};
type SshConfig = {
  version: number;
  servers: Server[];
  psmpProfiles: PsmpProfile[];
  cyberark?: CyberarkConfig | null;
};
type SecretKind = "password" | "key" | "token" | "api_key";
type CredMeta = { id: string; label: string; username: string; secretKind: SecretKind; description: string };
type CredStoreStatus = { initialized: boolean; unlocked: boolean };

type Tab = "servers" | "cyberark" | "store";

const CARD =
  "rounded-lg border border-neutral-200 dark:border-[#3d3f44] bg-white dark:bg-[#25272b] p-4";
const INPUT =
  "w-full px-2.5 py-1.5 rounded border border-neutral-300 dark:border-[#3d3f44] bg-white dark:bg-[#1e1f23] text-sm outline-none focus:border-indigo-500";
const BTN =
  "px-3 py-1.5 rounded text-sm font-medium bg-indigo-600 hover:bg-indigo-500 text-white disabled:opacity-50 cursor-pointer";
const BTN_GHOST =
  "px-2.5 py-1.5 rounded text-sm text-neutral-600 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-[#2f3136] cursor-pointer";

const emptyServer = (): Server => ({
  id: "",
  label: "",
  host: "",
  port: 22,
  username: "",
  connectionType: "direct",
  psmpProfileId: null,
  credentialSource: { kind: "prompt" },
  agentAccess: false,
  tags: [],
});

export default function SshPage({ onConnect }: { onConnect?: (serverId: string, label: string) => void } = {}) {
  const [tab, setTab] = useState<Tab>("servers");
  const [cfg, setCfg] = useState<SshConfig>({ version: 1, servers: [], psmpProfiles: [], cyberark: null });
  const [store, setStore] = useState<CredStoreStatus>({ initialized: false, unlocked: false });
  const [creds, setCreds] = useState<CredMeta[]>([]);
  // CyberArk accounts fetched after logon (lifted here so the Servers form's
  // credential picker can offer them too). Cleared on logoff.
  const [cyberAccounts, setCyberAccounts] = useState<CyberarkAccount[]>([]);
  const [err, setErr] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const c = await invoke<SshConfig>("ssh_get_config");
      setCfg(c);
      const s = await invoke<CredStoreStatus>("credstore_status");
      setStore(s);
      if (s.unlocked) setCreds(await invoke<CredMeta[]>("credstore_cred_list"));
      else setCreds([]);
    } catch (e) {
      setErr(String(e));
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return (
    <div className="flex-1 overflow-auto">
      <div className="mx-auto max-w-4xl p-6 space-y-4">
        <div className="flex items-center gap-2">
          <ServerIcon className="h-5 w-5 text-indigo-500" />
          <h1 className="text-lg font-semibold">SSH Configuration</h1>
        </div>

        {/* Tabs */}
        <div className="flex gap-1 border-b border-neutral-200 dark:border-[#3d3f44]">
          {([
            ["servers", "Servers"],
            ["cyberark", "CyberArk"],
            ["store", "Password Store"],
          ] as [Tab, string][]).map(([t, label]) => (
            <button
              key={t}
              type="button"
              onClick={() => setTab(t)}
              className={`px-3 py-2 text-sm cursor-pointer border-b-2 -mb-px ${
                tab === t
                  ? "border-indigo-500 text-indigo-600 dark:text-indigo-400 font-semibold"
                  : "border-transparent text-neutral-500 hover:text-neutral-800 dark:hover:text-neutral-200"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {err && (
          <div className="text-sm rounded bg-rose-50 dark:bg-rose-950/40 text-rose-700 dark:text-rose-300 px-3 py-2 flex items-center justify-between">
            <span>{err}</span>
            <button type="button" className="cursor-pointer" onClick={() => setErr(null)}>
              <X className="h-4 w-4" />
            </button>
          </div>
        )}

        {tab === "servers" && (
          <ServersTab
            cfg={cfg}
            creds={creds}
            unlocked={store.unlocked}
            cyberAccounts={cyberAccounts}
            onChange={refresh}
            setErr={setErr}
            onConnect={onConnect}
          />
        )}
        {tab === "cyberark" && (
          <CyberarkTab
            cfg={cfg}
            creds={creds}
            unlocked={store.unlocked}
            cyberAccounts={cyberAccounts}
            setCyberAccounts={setCyberAccounts}
            onChange={refresh}
            setErr={setErr}
          />
        )}
        {tab === "store" && (
          <StoreTab store={store} creds={creds} onChange={refresh} setErr={setErr} />
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Servers tab
// ---------------------------------------------------------------------------
function ServersTab({
  cfg,
  creds,
  unlocked,
  cyberAccounts,
  onChange,
  setErr,
  onConnect,
}: {
  cfg: SshConfig;
  creds: CredMeta[];
  unlocked: boolean;
  cyberAccounts: CyberarkAccount[];
  onChange: () => Promise<void>;
  setErr: (e: string | null) => void;
  onConnect?: (serverId: string, label: string) => void;
}) {
  const [draft, setDraft] = useState<Server | null>(null);

  const save = async () => {
    if (!draft) return;
    try {
      setErr(null);
      await invoke<string>("ssh_upsert_server", { server: draft });
      setDraft(null);
      await onChange();
    } catch (e) {
      setErr(String(e)); // dedup / validation errors surface here
    }
  };
  const remove = async (id: string) => {
    try {
      await invoke("ssh_remove_server", { id });
      await onChange();
    } catch (e) {
      setErr(String(e));
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex justify-between items-center">
        <p className="text-sm text-neutral-500">{cfg.servers.length} server(s)</p>
        <button type="button" className={BTN} onClick={() => setDraft(emptyServer())}>
          <Plus className="h-4 w-4 inline -mt-0.5 mr-1" /> Add server
        </button>
      </div>

      {cfg.servers.length === 0 && (
        <div className={`${CARD} text-sm text-neutral-500`}>No servers yet. Start with "Add server".</div>
      )}

      <div className="space-y-2">
        {cfg.servers.map((s) => (
          <div key={s.id} className={`${CARD} flex items-center justify-between`}>
            <div className="min-w-0">
              <div className="font-medium truncate flex items-center gap-1.5">
                <span className="truncate">{s.label || `${s.username}@${s.host}`}</span>
                {s.agentAdded && (
                  <span
                    className="shrink-0 rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-900/40 dark:text-amber-300"
                    title="Registered by a Claude agent via ssh_add_server — verify the host before attaching a credential."
                  >
                    agent-added
                  </span>
                )}
              </div>
              <div className="text-xs text-neutral-500 font-mono truncate">
                {s.username}@{s.host}:{s.port} · {s.connectionType === "psmp" ? "PSMP" : "direct"} ·{" "}
                {s.credentialSource.kind}
                {s.lastConnectedAt ? ` · last: ${s.lastConnectedAt}` : ""}
              </div>
            </div>
            <div className="flex gap-1 shrink-0 items-center">
              {onConnect && (
                <button type="button" className={BTN} onClick={() => onConnect(s.id, s.label || `${s.username}@${s.host}`)}>
                  Connect
                </button>
              )}
              <button type="button" className={BTN_GHOST} onClick={() => setDraft(s)}>
                <Pencil className="h-4 w-4" />
              </button>
              <button
                type="button"
                className={`${BTN_GHOST} text-rose-600`}
                onClick={() => remove(s.id)}
              >
                <Trash2 className="h-4 w-4" />
              </button>
            </div>
          </div>
        ))}
      </div>

      {draft && (
        <div className={`${CARD} space-y-3`}>
          <div className="font-medium text-sm">{draft.id ? "Edit server" : "New server"}</div>
          <div className="grid grid-cols-2 gap-2">
            <label className="text-xs space-y-1">
              <span className="text-neutral-500">Label</span>
              <input className={INPUT} value={draft.label} onChange={(e) => setDraft({ ...draft, label: e.target.value })} />
            </label>
            <label className="text-xs space-y-1">
              <span className="text-neutral-500">Username</span>
              <input className={INPUT} value={draft.username} onChange={(e) => setDraft({ ...draft, username: e.target.value })} />
            </label>
            <label className="text-xs space-y-1">
              <span className="text-neutral-500">Host / address</span>
              <input className={INPUT} value={draft.host} onChange={(e) => setDraft({ ...draft, host: e.target.value })} />
            </label>
            <label className="text-xs space-y-1">
              <span className="text-neutral-500">Port</span>
              <input
                type="number"
                className={INPUT}
                value={draft.port}
                onChange={(e) => setDraft({ ...draft, port: parseInt(e.target.value || "22", 10) })}
              />
            </label>
            <label className="text-xs space-y-1">
              <span className="text-neutral-500">Connection type</span>
              <select
                className={INPUT}
                value={draft.connectionType}
                onChange={(e) => setDraft({ ...draft, connectionType: e.target.value as Server["connectionType"] })}
              >
                <option value="direct">Direct</option>
                <option value="psmp">PSMP (jump server)</option>
              </select>
            </label>
            {draft.connectionType === "psmp" && (
              <label className="text-xs space-y-1">
                <span className="text-neutral-500">PSMP profile</span>
                <select
                  className={INPUT}
                  value={draft.psmpProfileId ?? ""}
                  onChange={(e) => setDraft({ ...draft, psmpProfileId: e.target.value || null })}
                >
                  <option value="">— select —</option>
                  {cfg.psmpProfiles.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.label} ({p.psmpAddress})
                    </option>
                  ))}
                </select>
              </label>
            )}
            <label className="text-xs space-y-1 col-span-2">
              <span className="text-neutral-500">Credential source</span>
              <CredentialPicker
                creds={creds}
                unlocked={unlocked}
                cyberarkAccounts={cyberAccounts}
                value={draft.credentialSource}
                onChange={(cs) => setDraft({ ...draft, credentialSource: cs })}
                onRefresh={onChange}
                setErr={setErr}
              />
            </label>
            <label className="text-xs space-y-1 col-span-2">
              <span className="text-neutral-500">Extra SSH options (optional)</span>
              <input
                className={`${INPUT} font-mono`}
                placeholder="-X -L 8080:localhost:80 -J jump@host"
                value={draft.sshOptions ?? ""}
                onChange={(e) => setDraft({ ...draft, sshOptions: e.target.value || null })}
              />
            </label>
            <label className="text-xs flex items-center gap-2 col-span-2 cursor-pointer">
              <input
                type="checkbox"
                checked={!!draft.agentAccess}
                onChange={(e) => setDraft({ ...draft, agentAccess: e.target.checked })}
              />
              <span className="text-neutral-500">
                Agent may use this server (exposes it by alias to Claude via the muya-ssh MCP; the password is never shared)
              </span>
            </label>
          </div>
          <div className="flex gap-2 justify-end">
            <button type="button" className={BTN_GHOST} onClick={() => setDraft(null)}>
              Cancel
            </button>
            <button type="button" className={BTN} onClick={save}>
              Save
            </button>
          </div>
        </div>
      )}

      <PsmpProfiles cfg={cfg} onChange={onChange} setErr={setErr} />
    </div>
  );
}

function PsmpProfiles({
  cfg,
  onChange,
  setErr,
}: {
  cfg: SshConfig;
  onChange: () => Promise<void>;
  setErr: (e: string | null) => void;
}) {
  const [draft, setDraft] = useState<PsmpProfile | null>(null);
  const blank = (): PsmpProfile => ({ id: "", label: "", psmpAddress: "", vaultUser: "", userDelim: "@", paramDelim: "#", scpOptions: "" });
  const save = async () => {
    if (!draft) return;
    try {
      await invoke<string>("ssh_upsert_psmp_profile", { profile: draft });
      setDraft(null);
      await onChange();
    } catch (e) {
      setErr(String(e));
    }
  };
  return (
    <div className={`${CARD} space-y-2`}>
      <div className="flex justify-between items-center">
        <span className="text-sm font-medium">PSMP jump-server profiles</span>
        <button type="button" className={BTN_GHOST} onClick={() => setDraft(blank())}>
          <Plus className="h-4 w-4" />
        </button>
      </div>
      {cfg.psmpProfiles.map((p) => (
        <div key={p.id} className="text-xs font-mono text-neutral-500 flex justify-between items-center">
          <span className="truncate">
            {p.label}: {p.vaultUser}@…@{p.psmpAddress}
          </span>
          <div className="flex gap-1 shrink-0 items-center">
            <button
              type="button"
              className="text-neutral-500 hover:text-indigo-500 cursor-pointer"
              title="Edit profile"
              onClick={() => setDraft({ ...p })}
            >
              <Pencil className="h-3.5 w-3.5" />
            </button>
            <button
              type="button"
              className="text-rose-600 cursor-pointer"
              title="Delete profile"
              onClick={async () => {
                try {
                  await invoke("ssh_remove_psmp_profile", { id: p.id });
                  await onChange();
                } catch (e) {
                  setErr(String(e));
                }
              }}
            >
              <Trash2 className="h-3.5 w-3.5" />
            </button>
          </div>
        </div>
      ))}
      {draft && (
        <div className="grid grid-cols-2 gap-2 pt-2">
          <input className={INPUT} placeholder="Label" value={draft.label} onChange={(e) => setDraft({ ...draft, label: e.target.value })} />
          <input className={INPUT} placeholder="PSMP address" value={draft.psmpAddress} onChange={(e) => setDraft({ ...draft, psmpAddress: e.target.value })} />
          <input className={INPUT} placeholder="Vault user" value={draft.vaultUser} onChange={(e) => setDraft({ ...draft, vaultUser: e.target.value })} />
          <div className="grid grid-cols-2 gap-2 col-span-2">
            <input className={INPUT} placeholder="User delimiter (default @)" value={draft.userDelim} onChange={(e) => setDraft({ ...draft, userDelim: e.target.value })} />
            <input className={INPUT} placeholder="Param delimiter (default #)" value={draft.paramDelim} onChange={(e) => setDraft({ ...draft, paramDelim: e.target.value })} />
          </div>
          <input
            className={`${INPUT} col-span-2`}
            placeholder='ssh_scp -o options for this profile (e.g. "-o ProxyCommand=... -o ServerAliveInterval=30")'
            value={draft.scpOptions ?? ""}
            onChange={(e) => setDraft({ ...draft, scpOptions: e.target.value })}
          />
          <div className="flex gap-2 justify-end col-span-2">
            <button type="button" className={BTN_GHOST} onClick={() => setDraft(null)}>Cancel</button>
            <button type="button" className={BTN} onClick={save}>{draft.id ? "Save changes" : "Add"}</button>
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// CyberArk tab (Faz 1 = config only; real connection test lands in Faz 3)
// ---------------------------------------------------------------------------
function CyberarkTab({
  cfg,
  creds,
  unlocked,
  cyberAccounts,
  setCyberAccounts,
  onChange,
  setErr,
}: {
  cfg: SshConfig;
  creds: CredMeta[];
  unlocked: boolean;
  cyberAccounts: CyberarkAccount[];
  setCyberAccounts: (a: CyberarkAccount[]) => void;
  onChange: () => Promise<void>;
  setErr: (e: string | null) => void;
}) {
  const [form, setForm] = useState<CyberarkConfig>(
    cfg.cyberark ?? { baseUrl: "", username: "", authMethod: "Cyberark", tlsVerify: true, caCertPath: null, credentialSource: { kind: "prompt" } },
  );
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    if (cfg.cyberark) setForm(cfg.cyberark);
  }, [cfg.cyberark]);

  const save = async () => {
    try {
      setErr(null);
      await invoke("ssh_set_cyberark_config", { config: form });
      await onChange();
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } catch (e) {
      setErr(String(e));
    }
  };

  return (
    <div className={`${CARD} space-y-3`}>
      <div className="flex items-center gap-2">
        <ShieldCheck className="h-4 w-4 text-emerald-500" />
        <span className="font-medium text-sm">CyberArk PAM connection</span>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <label className="text-xs space-y-1">
          <span className="text-neutral-500">PVWA API URL</span>
          <input className={INPUT} placeholder="https://pvwa.corp" value={form.baseUrl} onChange={(e) => setForm({ ...form, baseUrl: e.target.value })} />
        </label>
        <label className="text-xs space-y-1">
          <span className="text-neutral-500">Vault username</span>
          <input className={INPUT} placeholder="vault-user" value={form.username} onChange={(e) => setForm({ ...form, username: e.target.value })} />
        </label>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <label className="text-xs space-y-1">
          <span className="text-neutral-500">Auth method</span>
          <select className={INPUT} value={form.authMethod} onChange={(e) => setForm({ ...form, authMethod: e.target.value as CyberarkConfig["authMethod"] })}>
            <option>Cyberark</option>
            <option>LDAP</option>
            <option>RADIUS</option>
            <option>Windows</option>
          </select>
        </label>
        <label className="text-xs space-y-1">
          <span className="text-neutral-500">Internal CA cert path (optional)</span>
          <input className={INPUT} placeholder="/path/to/ca.pem" value={form.caCertPath ?? ""} onChange={(e) => setForm({ ...form, caCertPath: e.target.value || null })} />
        </label>
      </div>
      <div className="space-y-1">
        <span className="text-xs text-neutral-500">Login credential</span>
        <CredentialPicker
          creds={creds}
          unlocked={unlocked}
          value={form.credentialSource}
          onChange={(cs) => setForm({ ...form, credentialSource: cs })}
          onRefresh={onChange}
          setErr={setErr}
          promptLabel="Ask each time (session-only)"
        />
      </div>
      <label className="flex items-center gap-2 text-xs text-neutral-600 dark:text-neutral-300">
        <input type="checkbox" checked={form.tlsVerify} onChange={(e) => setForm({ ...form, tlsVerify: e.target.checked })} />
        TLS verification on (recommended — no disable option)
      </label>
      <div className="flex items-center justify-between pt-1">
        <span className="text-xs text-neutral-400">
          Pick a stored credential to reuse it, or "Ask each time".
        </span>
        <div className="flex items-center gap-2">
          {saved && (
            <span className="text-xs text-emerald-600 dark:text-emerald-400 flex items-center gap-1">
              <ShieldCheck className="h-3.5 w-3.5" /> Saved
            </span>
          )}
          <button type="button" className={BTN} onClick={save}>
            Save settings
          </button>
        </div>
      </div>

      <CyberarkTester form={form} setErr={setErr} accounts={cyberAccounts} setAccounts={setCyberAccounts} />
    </div>
  );
}

// ---------------------------------------------------------------------------
// CyberArk live test + account browser (Faz 3). Establishes a PVWA session
// (token cached in Rust — never exposed to JS), then lists accounts so the
// operator can assign them to servers. The master password is session-only.
// ---------------------------------------------------------------------------
type CyberarkAccount = { id: string; name: string; address: string; username: string; safe: string; platformId: string };

function CyberarkTester({
  form,
  setErr,
  accounts,
  setAccounts,
}: {
  form: CyberarkConfig;
  setErr: (e: string | null) => void;
  accounts: CyberarkAccount[];
  setAccounts: (a: CyberarkAccount[]) => void;
}) {
  const [master, setMaster] = useState("");
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [loggedOn, setLoggedOn] = useState(false);
  const [search, setSearch] = useState("");

  useEffect(() => {
    void invoke<boolean>("cyberark_status").then(setLoggedOn).catch(() => {});
  }, []);

  const test = async () => {
    if (!form.baseUrl.trim()) return setErr("Save a PVWA API URL first.");
    if (!form.username.trim()) return setErr("Enter the vault username first.");
    setBusy(true);
    setStatus(null);
    try {
      const msg = await invoke<string>("cyberark_test_connection", { config: form, username: form.username, master });
      setStatus(msg);
      setMaster("");
      setLoggedOn(true);
    } catch (e) {
      setStatus(null);
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };
  const listAccounts = async () => {
    setBusy(true);
    try {
      const a = await invoke<CyberarkAccount[]>("cyberark_list_accounts", { search: search || null });
      setAccounts(a);
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };
  const logoff = async () => {
    try {
      await invoke("cyberark_logoff");
      setLoggedOn(false);
      setAccounts([]);
      setStatus(null);
    } catch (e) {
      setErr(String(e));
    }
  };

  return (
    <div className="rounded border border-neutral-200 dark:border-[#3d3f44] p-3 space-y-2">
      <div className="text-xs font-medium">Test connection & browse accounts</div>
      <div className="flex gap-2">
        <input
          type="password"
          className={INPUT}
          placeholder="PVWA login password (session-only)"
          value={master}
          onChange={(e) => setMaster(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && test()}
        />
        <button type="button" className={BTN} disabled={busy} onClick={test}>
          Test connection
        </button>
        {loggedOn && (
          <button type="button" className={BTN_GHOST} onClick={logoff}>
            Log off
          </button>
        )}
      </div>
      {status && (
        <div className="text-xs text-emerald-600 dark:text-emerald-400">{status}</div>
      )}

      {loggedOn && (
        <div className="space-y-2 pt-1">
          <div className="flex gap-2">
            <input className={INPUT} placeholder="Search accounts (name / address / user)" value={search} onChange={(e) => setSearch(e.target.value)} onKeyDown={(e) => e.key === "Enter" && listAccounts()} />
            <button type="button" className={BTN_GHOST} disabled={busy} onClick={listAccounts}>
              Search
            </button>
          </div>
          {accounts.length > 0 && (
            <div className="max-h-48 overflow-auto space-y-1">
              {accounts.map((a) => (
                <div key={a.id} className="text-xs font-mono text-neutral-600 dark:text-neutral-300 flex justify-between border-b border-neutral-100 dark:border-[#2f3136] py-0.5">
                  <span className="truncate">{a.name || a.address} · {a.username}@{a.address}</span>
                  <span className="text-neutral-400 shrink-0 ml-2">{a.safe}</span>
                </div>
              ))}
              <p className="text-[11px] text-neutral-400 pt-1">
                {accounts.length} account(s). Assign one to a server in the Servers tab (credential source → CyberArk).
              </p>
            </div>
          )}
        </div>
      )}
      {!loggedOn && (
        <p className="text-[11px] text-neutral-400">
          Log on to fetch the account list, then set a server's credential source to a CyberArk account.
        </p>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Password Store tab
// ---------------------------------------------------------------------------
function StoreTab({
  store,
  creds,
  onChange,
  setErr,
}: {
  store: CredStoreStatus;
  creds: CredMeta[];
  onChange: () => Promise<void>;
  setErr: (e: string | null) => void;
}) {
  const [master, setMaster] = useState("");
  const [busy, setBusy] = useState(false);
  const [showMaster, setShowMaster] = useState(false);
  const [draft, setDraft] = useState<{ id?: string; label: string; username: string; secretKind: SecretKind; secret: string; description: string } | null>(null);
  const [importDraft, setImportDraft] = useState<{ label: string; username: string } | null>(null);
  const [revealed, setRevealed] = useState<Record<string, string>>({});
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const doInit = async () => {
    if (master.length < 4) return setErr("master password must be at least 4 characters");
    setBusy(true);
    try {
      await invoke("credstore_init", { master });
      setMaster("");
      await onChange();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };
  const doUnlock = async () => {
    setBusy(true);
    try {
      await invoke("credstore_unlock", { master });
      setMaster("");
      await onChange();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };
  const lock = async () => {
    await invoke("credstore_lock");
    await onChange();
  };
  const exportBackup = async () => {
    try {
      const dest = await pickSavePath("Export encrypted store backup", "muya-ssh-vault.enc.bak");
      if (!dest) return;
      await invoke("credstore_export", { dest });
      setErr(`Encrypted backup exported to: ${dest}`);
    } catch (e) {
      setErr(String(e));
    }
  };
  // Literal master-password export (plaintext file, explicit operator request).
  const exportMaster = async () => {
    if (master.length < 4) return setErr("type the master password above first, then export it");
    try {
      const dest = await pickSavePath("Export master password (PLAINTEXT)", "muya-master-password.txt");
      if (!dest) return;
      await invoke("credstore_export_master", { dest, master });
      setErr(`⚠️ Master password written in plaintext to: ${dest} — store it somewhere safe.`);
    } catch (e) {
      setErr(String(e));
    }
  };
  const importKey = async () => {
    if (!importDraft) return;
    try {
      const src = await pickOpenPath("Select SSH private key file");
      if (!src) return;
      await invoke<string>("credstore_import_key", {
        label: importDraft.label || "imported key",
        username: importDraft.username,
        srcPath: src,
      });
      setImportDraft(null);
      await onChange();
    } catch (e) {
      setErr(String(e));
    }
  };
  const exportCred = async (c: CredMeta) => {
    try {
      const ext = c.secretKind === "key" ? "" : ".txt";
      const dest = await pickSavePath(`Export ${c.secretKind}`, `${c.label || c.username}${ext}`);
      if (!dest) return;
      await invoke("credstore_export_cred", { id: c.id, dest });
      setErr(`${c.secretKind === "key" ? "SSH key" : "Password"} exported to: ${dest}`);
    } catch (e) {
      setErr(String(e));
    }
  };
  const addCred = async () => {
    if (!draft) return;
    try {
      await invoke<string>("credstore_cred_upsert", { cred: draft });
      setDraft(null);
      await onChange();
    } catch (e) {
      setErr(String(e));
    }
  };
  const removeCred = async (id: string) => {
    try {
      await invoke("credstore_cred_remove", { id });
      await onChange();
    } catch (e) {
      setErr(String(e));
    }
  };
  // Operator-only reveal (Tauri command, never an MCP path). Toggles inline view;
  // fetches on demand so plaintext isn't preloaded for every row.
  const toggleReveal = async (id: string) => {
    if (id in revealed) {
      setRevealed((r) => {
        const { [id]: _drop, ...rest } = r;
        return rest;
      });
      return;
    }
    try {
      const value = await invoke<string>("credstore_reveal_cred", { id });
      setRevealed((r) => ({ ...r, [id]: value }));
    } catch (e) {
      setErr(String(e));
    }
  };
  const copyCred = async (id: string) => {
    try {
      const value = revealed[id] ?? (await invoke<string>("credstore_reveal_cred", { id }));
      await navigator.clipboard.writeText(value);
      setCopiedId(id);
      setTimeout(() => setCopiedId((c) => (c === id ? null : c)), 1500);
    } catch (e) {
      setErr(String(e));
    }
  };
  const editCred = async (c: CredMeta) => {
    try {
      const secret = await invoke<string>("credstore_reveal_cred", { id: c.id });
      setDraft({ id: c.id, label: c.label, username: c.username, secretKind: c.secretKind, secret, description: c.description ?? "" });
    } catch (e) {
      setErr(String(e));
    }
  };

  if (!store.initialized) {
    return (
      <div className={`${CARD} space-y-3`}>
        <div className="flex items-center gap-2">
          <KeyRound className="h-4 w-4 text-indigo-500" />
          <span className="font-medium text-sm">Create password store</span>
        </div>
        <p className="text-xs text-neutral-500">
          Your credentials are stored encrypted with AES-256-GCM. Keep your master password safe — the app never
          stores it, so you can also export an encrypted backup once unlocked.
        </p>
        <div className="relative">
          <input type={showMaster ? "text" : "password"} className={INPUT} placeholder="Master password" value={master} disabled={busy} onChange={(e) => setMaster(e.target.value)} />
          <button type="button" className="absolute right-2 top-1.5 text-neutral-400 hover:text-neutral-600 cursor-pointer" onClick={() => setShowMaster(!showMaster)} title={showMaster ? "Hide" : "Show"}>
            {showMaster ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        </div>
        {busy && <p className="text-xs text-neutral-500">Deriving the key (Argon2id) — this can take a second or two.</p>}
        <div className="flex gap-2">
          <button type="button" className={BTN} disabled={busy} onClick={doInit}>
            {busy ? <><Loader2 className="h-4 w-4 inline -mt-0.5 mr-1 animate-spin" /> Creating…</> : "Create"}
          </button>
          <button type="button" className={BTN_GHOST} onClick={exportMaster}>
            <Download className="h-4 w-4 inline -mt-0.5 mr-1" /> Export master password
          </button>
        </div>
        <p className="text-[11px] text-amber-600 dark:text-amber-400">
          ⚠️ "Export master password" saves it to a plaintext file you pick. Prefer keeping it in a password manager — the app never stores it.
        </p>
      </div>
    );
  }

  if (!store.unlocked) {
    return (
      <div className={`${CARD} space-y-3`}>
        <div className="flex items-center gap-2">
          <Lock className="h-4 w-4 text-amber-500" />
          <span className="font-medium text-sm">Store locked</span>
        </div>
        <div className="relative">
          <input
            type={showMaster ? "text" : "password"}
            className={INPUT}
            placeholder="Master password"
            value={master}
            disabled={busy}
            onChange={(e) => setMaster(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && !busy && doUnlock()}
          />
          <button type="button" className="absolute right-2 top-1.5 text-neutral-400 hover:text-neutral-600 cursor-pointer" onClick={() => setShowMaster(!showMaster)} title={showMaster ? "Hide" : "Show"}>
            {showMaster ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        </div>
        <button type="button" className={BTN} disabled={busy} onClick={doUnlock}>
          {busy ? (
            <><Loader2 className="h-4 w-4 inline -mt-0.5 mr-1 animate-spin" /> Unlocking…</>
          ) : (
            <><Unlock className="h-4 w-4 inline -mt-0.5 mr-1" /> Unlock</>
          )}
        </button>
        {busy ? (
          <p className="text-xs text-neutral-500">Deriving the key (Argon2id) — this can take a second or two, hang tight.</p>
        ) : (
          <p className="text-xs text-neutral-400">Touch ID auto-unlock arrives with Faz 1 (Keychain).</p>
        )}
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="flex justify-between items-center">
        <span className="text-sm text-emerald-600 dark:text-emerald-400 flex items-center gap-1">
          <Unlock className="h-4 w-4" /> Unlocked · {creds.length} item(s)
        </span>
        <div className="flex gap-2">
          <button type="button" className={BTN} onClick={() => setDraft({ label: "", username: "", secretKind: "password", secret: "", description: "" })}>
            <Plus className="h-4 w-4 inline -mt-0.5 mr-1" /> Add credential
          </button>
          <button type="button" className={BTN_GHOST} onClick={() => setImportDraft({ label: "", username: "" })}>
            <Upload className="h-4 w-4 inline -mt-0.5 mr-1" /> Import SSH key
          </button>
          <button type="button" className={BTN_GHOST} onClick={exportBackup}>
            Export backup
          </button>
          <button type="button" className={BTN_GHOST} onClick={lock}>
            <Lock className="h-4 w-4 inline -mt-0.5 mr-1" /> Lock
          </button>
        </div>
      </div>

      {creds.map((c) => (
        <div key={c.id} className={`${CARD} flex flex-col gap-2`}>
          <div className="flex justify-between items-center">
            <div className="text-sm">
              <span className="font-medium">{c.label}</span>{" "}
              <span className="text-xs text-neutral-500 font-mono">
                {c.username} · {c.secretKind === "key" ? "SSH key" : c.secretKind === "token" ? "token" : c.secretKind === "api_key" ? "API key" : "password"}
              </span>
              {c.description && <div className="text-xs text-neutral-400 mt-0.5">{c.description}</div>}
            </div>
            <div className="flex gap-1 shrink-0">
              <button type="button" className={BTN_GHOST} onClick={() => toggleReveal(c.id)} title={c.id in revealed ? "Hide value" : "View value"}>
                {c.id in revealed ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
              </button>
              <button type="button" className={BTN_GHOST} onClick={() => copyCred(c.id)} title="Copy value">
                {copiedId === c.id ? <Check className="h-4 w-4 text-emerald-600" /> : <Copy className="h-4 w-4" />}
              </button>
              <button type="button" className={BTN_GHOST} onClick={() => editCred(c)} title="Edit credential">
                <Pencil className="h-4 w-4" />
              </button>
              <button type="button" className={BTN_GHOST} onClick={() => exportCred(c)} title={`Export ${c.secretKind}`}>
                <Download className="h-4 w-4" />
              </button>
              <button type="button" className={`${BTN_GHOST} text-rose-600`} onClick={() => removeCred(c.id)}>
                <Trash2 className="h-4 w-4" />
              </button>
            </div>
          </div>
          {c.id in revealed && (
            <pre className="text-xs font-mono bg-neutral-100 dark:bg-neutral-800 rounded p-2 whitespace-pre-wrap break-all select-text max-h-40 overflow-auto">
              {revealed[c.id]}
            </pre>
          )}
        </div>
      ))}

      {importDraft && (
        <div className={`${CARD} space-y-2`}>
          <div className="text-sm font-medium">Import SSH private key from file</div>
          <div className="grid grid-cols-2 gap-2">
            <input className={INPUT} placeholder="Label" value={importDraft.label} onChange={(e) => setImportDraft({ ...importDraft, label: e.target.value })} />
            <input className={INPUT} placeholder="Username" value={importDraft.username} onChange={(e) => setImportDraft({ ...importDraft, username: e.target.value })} />
          </div>
          <div className="flex gap-2 justify-end">
            <button type="button" className={BTN_GHOST} onClick={() => setImportDraft(null)}>Cancel</button>
            <button type="button" className={BTN} onClick={importKey}>
              <Upload className="h-4 w-4 inline -mt-0.5 mr-1" /> Choose file & import
            </button>
          </div>
        </div>
      )}

      {draft && (
        <div className={`${CARD} space-y-2`}>
          <div className="font-medium text-sm">{draft.id ? "Edit credential" : "New credential"}</div>
          <div className="grid grid-cols-2 gap-2">
            <input className={INPUT} placeholder="Label" value={draft.label} onChange={(e) => setDraft({ ...draft, label: e.target.value })} />
            <input className={INPUT} placeholder="Username" value={draft.username} onChange={(e) => setDraft({ ...draft, username: e.target.value })} />
            <select className={INPUT} value={draft.secretKind} onChange={(e) => setDraft({ ...draft, secretKind: e.target.value as SecretKind })}>
              <option value="password">Password</option>
              <option value="key">SSH private key</option>
              <option value="token">Token</option>
              <option value="api_key">API key</option>
            </select>
            {draft.secretKind === "password" ? (
              <input type="password" className={INPUT} placeholder="Password" value={draft.secret} onChange={(e) => setDraft({ ...draft, secret: e.target.value })} />
            ) : draft.secretKind === "token" ? (
              <input type="password" className={INPUT} placeholder="Token / API key (or compact JSON)" value={draft.secret} onChange={(e) => setDraft({ ...draft, secret: e.target.value })} />
            ) : draft.secretKind === "api_key" ? (
              <input type="password" className={INPUT} placeholder="API key value" value={draft.secret} onChange={(e) => setDraft({ ...draft, secret: e.target.value })} />
            ) : (
              <textarea className={`${INPUT} col-span-2 font-mono h-24`} placeholder="-----BEGIN OPENSSH PRIVATE KEY-----" value={draft.secret} onChange={(e) => setDraft({ ...draft, secret: e.target.value })} />
            )}
            <input className={`${INPUT} col-span-2`} placeholder="Description (optional — shown to agents by name)" value={draft.description} onChange={(e) => setDraft({ ...draft, description: e.target.value })} />
          </div>
          <div className="flex gap-2 justify-end">
            <button type="button" className={BTN_GHOST} onClick={() => setDraft(null)}>Cancel</button>
            <button type="button" className={BTN} onClick={addCred}>Save</button>
          </div>
        </div>
      )}
    </div>
  );
}
