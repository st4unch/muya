import { useCallback, useEffect, useState, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { copyToClipboard } from "../lib/clipboard";
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
  ChevronDown,
  ChevronRight,
  Search as SearchIcon,
  Fingerprint,
} from "lucide-react";

import CredentialPicker from "./CredentialPicker";
import { BTN, BTN_GHOST, CARD, ICON_BTN, ICON_BTN_DANGER, INPUT, LABEL } from "./sshStyles";

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
  /** Operator-assigned group card this server lives under; "" = Ungrouped. */
  group: string;
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
type CredMeta = { id: string; label: string; username: string; secretKind: SecretKind; description: string; group: string };
type CredStoreStatus = { initialized: boolean; unlocked: boolean };

type Tab = "servers" | "cyberark" | "store";

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
  group: "",
  tags: [],
});

// ---------------------------------------------------------------------------
// Grouping — shared by the Servers and Password Store tabs
// ---------------------------------------------------------------------------
// `group` is free text on both `Server` and `CredMeta`; empty means the item
// has no group. It is bucketed under this literal name, always sorted last so
// the operator's named groups stay at the top of the page.
const UNGROUPED = "Ungrouped";

function groupItems<T>(items: T[], groupOf: (item: T) => string): [string, T[]][] {
  const buckets = new Map<string, T[]>();
  for (const item of items) {
    const name = (groupOf(item) || "").trim() || UNGROUPED;
    const bucket = buckets.get(name);
    if (bucket) bucket.push(item);
    else buckets.set(name, [item]);
  }
  return [...buckets.entries()].sort(([a], [b]) =>
    a === UNGROUPED ? 1 : b === UNGROUPED ? -1 : a.localeCompare(b),
  );
}

/** Existing group names for the form's datalist — "Ungrouped" is not one of them. */
function groupNames<T>(items: T[], groupOf: (item: T) => string): string[] {
  return [...new Set(items.map((i) => (groupOf(i) || "").trim()).filter(Boolean))].sort();
}

// Collapse state is persisted so a folded group stays folded across reloads.
// Groups that disappear simply leave a stale name behind — harmless, and a new
// group defaults to expanded because absence means "open".
function useCollapsedGroups(storageKey: string) {
  const [collapsed, setCollapsed] = useState<Set<string>>(() => {
    try {
      const raw = localStorage.getItem(storageKey);
      return new Set<string>(raw ? (JSON.parse(raw) as string[]) : []);
    } catch {
      return new Set<string>();
    }
  });
  const toggle = useCallback(
    (name: string) => {
      setCollapsed((prev) => {
        const next = new Set(prev);
        if (!next.delete(name)) next.add(name);
        try {
          localStorage.setItem(storageKey, JSON.stringify([...next]));
        } catch {
          // Cosmetic state only — a storage failure must never break the page.
        }
        return next;
      });
    },
    [storageKey],
  );
  return { collapsed, toggle };
}

/** One card per group: clickable header (name · count · chevron) + a responsive item grid. */
function GroupCard({
  name,
  count,
  collapsed,
  onToggle,
  children,
}: {
  name: string;
  count: number;
  collapsed: boolean;
  onToggle: () => void;
  children: ReactNode;
}) {
  return (
    <div className={`${CARD} space-y-3`}>
      <button
        type="button"
        onClick={onToggle}
        className="flex w-full items-center gap-1.5 text-left cursor-pointer"
        aria-expanded={!collapsed}
      >
        {collapsed ? (
          <ChevronRight className="h-4 w-4 shrink-0 text-[var(--text-faint)]" />
        ) : (
          <ChevronDown className="h-4 w-4 shrink-0 text-[var(--text-faint)]" />
        )}
        <span className="text-sm font-medium truncate">{name}</span>
        <span className="text-xs text-[var(--text-muted)] shrink-0">({count})</span>
      </button>
      {!collapsed && <div className="grid gap-3 md:grid-cols-2 2xl:grid-cols-3">{children}</div>}
    </div>
  );
}

/** Free-text group field backed by a datalist of the groups that already exist. */
function GroupField({
  value,
  onChange,
  listId,
  options,
  className,
}: {
  value: string;
  onChange: (v: string) => void;
  listId: string;
  options: string[];
  className?: string;
}) {
  return (
    <>
      <input
        className={`${INPUT} ${className ?? ""}`}
        placeholder="Group (optional)"
        list={listId}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
      <datalist id={listId}>
        {options.map((g) => (
          <option key={g} value={g} />
        ))}
      </datalist>
    </>
  );
}

export default function SshPage({ onConnect }: { onConnect?: (serverId: string, label: string) => void } = {}) {
  const [tab, setTab] = useState<Tab>("servers");
  const [cfg, setCfg] = useState<SshConfig>({ version: 1, servers: [], psmpProfiles: [], cyberark: null });
  const [store, setStore] = useState<CredStoreStatus>({ initialized: false, unlocked: false });
  // Whether Touch ID unlock is enabled — a plain sync read (no Keychain access,
  // so checking this never pops the biometry prompt on its own).
  const [biometricAvailable, setBiometricAvailable] = useState(false);
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
      setBiometricAvailable(await invoke<boolean>("credstore_biometric_available"));
      if (s.unlocked) setCreds(await invoke<CredMeta[]>("credstore_cred_list"));
      else setCreds([]);
    } catch (e) {
      setErr(String(e));
    }
  }, []);

  // Re-read on every tab switch: the store can change behind this page's back.
  useEffect(() => {
    void refresh();
  }, [refresh, tab]);

  // The store can lock while this page isn't looking at it: App.tsx's 15-minute idle
  // timer fires whatever tab (or page) is showing, and SshPage stays mounted while
  // hidden. Only StoreTab used to listen, so on Servers/CyberArk the page kept saying
  // "unlocked" while agents were already refused. Listen here, for the whole page,
  // and also re-check when the window comes back to the front.
  useEffect(() => {
    const un = listen("muya://vault-locked", () => void refresh());
    const onFocus = () => void refresh();
    window.addEventListener("focus", onFocus);
    return () => {
      void un.then((f) => f());
      window.removeEventListener("focus", onFocus);
    };
  }, [refresh]);

  return (
    <div className="flex-1 overflow-auto">
      {/* No width cap: group cards lay their items out in columns, so the page
          earns the whole window instead of a centred 4xl strip. */}
      <div className="w-full p-6 space-y-4">
        <div className="flex items-center gap-2">
          <ServerIcon className="h-5 w-5 text-[var(--text-muted)]" />
          <h1 className="text-lg font-semibold">SSH Configuration</h1>
        </div>

        {/* Tabs */}
        <div className="flex gap-1 border-b border-[var(--border)]">
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
                  ? "border-[var(--text)] text-[var(--text)] font-semibold"
                  : "border-transparent text-[var(--text-muted)] hover:text-[var(--text)]"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {err && (
          <div className="text-sm rounded bg-[var(--danger-pill-bg)] text-[var(--danger-text)] px-3 py-2 flex items-center justify-between">
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
          <StoreTab store={store} creds={creds} biometricAvailable={biometricAvailable} onChange={refresh} setErr={setErr} />
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

  const { collapsed, toggle } = useCollapsedGroups("muya.servers.collapsed");
  const [query, setQuery] = useState("");
  // Group options always come from the FULL list so the datalist keeps offering
  // every group even while a search hides most servers.
  const names = groupNames(cfg.servers, (s) => s.group);
  const q = query.trim().toLowerCase();
  const filteredServers = q
    ? cfg.servers.filter((s) =>
        [s.label, s.host, s.username, s.group, ...s.tags].some((f) =>
          (f ?? "").toLowerCase().includes(q),
        ),
      )
    : cfg.servers;
  const groups = groupItems(filteredServers, (s) => s.group);

  // One draft at a time, so a single form element is reused wherever it belongs.
  const form = draft && (
    <ServerForm
      draft={draft}
      setDraft={setDraft}
      cfg={cfg}
      creds={creds}
      unlocked={unlocked}
      cyberAccounts={cyberAccounts}
      groupOptions={names}
      onChange={onChange}
      setErr={setErr}
      onSave={save}
    />
  );

  return (
    <div className="space-y-3">
      <div className="flex justify-between items-center">
        <p className="text-sm text-[var(--text-muted)]">{cfg.servers.length} server(s)</p>
        <button type="button" className={BTN} onClick={() => setDraft(emptyServer())}>
          <Plus className="h-4 w-4 inline -mt-0.5 mr-1" /> Add server
        </button>
      </div>

      {cfg.servers.length > 0 && (
        <div className="relative">
          <SearchIcon className="h-4 w-4 absolute left-2.5 top-1/2 -translate-y-1/2 text-[var(--text-faint)]" />
          <input
            className={`${INPUT} pl-8`}
            placeholder="Search servers — label, host, username, group, tag…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
      )}

      {cfg.servers.length === 0 && (
        <div className={`${CARD} text-sm text-[var(--text-muted)]`}>No servers yet. Start with "Add server".</div>
      )}
      {q && groups.length === 0 && (
        <p className="text-xs text-[var(--text-faint)] text-center py-4">No servers match &quot;{query}&quot;.</p>
      )}

      {/* A brand-new server has no row to sit in, so its form leads the list. */}
      {draft && !draft.id && form}

      {groups.map(([name, servers]) => (
        <GroupCard
          key={name}
          name={name}
          count={servers.length}
          // A search result stays visibly expanded regardless of the persisted
          // collapse state — the operator is looking for something, not browsing.
          collapsed={q ? false : collapsed.has(name)}
          onToggle={() => toggle(name)}
        >
          {servers.map((s) =>
            // Editing swaps the row for the form at the same spot — the operator
            // never has to hunt for a form appended to the bottom of the page.
            draft?.id === s.id ? (
              <div key={s.id}>{form}</div>
            ) : (
              <div key={s.id} className={`${CARD} flex items-center justify-between gap-2`}>
                <div className="min-w-0">
                  <div className="font-medium truncate flex items-center gap-1.5">
                    <span className="truncate">{s.label || `${s.username}@${s.host}`}</span>
                    {s.agentAdded && (
                      <span
                        className="shrink-0 rounded bg-[var(--warning-bg)] px-1.5 py-0.5 text-[10px] font-medium text-[var(--warning-text)]"
                        title="Registered by a Claude agent via ssh_add_server — verify the host before attaching a credential."
                      >
                        agent-added
                      </span>
                    )}
                  </div>
                  <div className="text-xs text-[var(--text-muted)] font-mono truncate">
                    {s.username}@{s.host}:{s.port} · {s.connectionType === "psmp" ? "PSMP" : "direct"} ·{" "}
                    {s.credentialSource.kind}
                    {s.lastConnectedAt ? ` · last: ${s.lastConnectedAt}` : ""}
                  </div>
                </div>
                <div className="flex gap-1 shrink-0 items-center">
                  {onConnect && (
                    <button type="button" className={BTN_GHOST} onClick={() => onConnect(s.id, s.label || `${s.username}@${s.host}`)}>
                      Connect
                    </button>
                  )}
                  <button type="button" className={ICON_BTN} title="Edit server" onClick={() => setDraft(s)}>
                    <Pencil className="h-4 w-4" />
                  </button>
                  <button
                    type="button"
                    className={ICON_BTN_DANGER}
                    title="Delete server"
                    onClick={() => remove(s.id)}
                  >
                    <Trash2 className="h-4 w-4" />
                  </button>
                </div>
              </div>
            ),
          )}
        </GroupCard>
      ))}

      <PsmpProfiles cfg={cfg} onChange={onChange} setErr={setErr} />
    </div>
  );
}

function ServerForm({
  draft,
  setDraft,
  cfg,
  creds,
  unlocked,
  cyberAccounts,
  groupOptions,
  onChange,
  setErr,
  onSave,
}: {
  draft: Server;
  setDraft: (s: Server | null) => void;
  cfg: SshConfig;
  creds: CredMeta[];
  unlocked: boolean;
  cyberAccounts: CyberarkAccount[];
  groupOptions: string[];
  onChange: () => Promise<void>;
  setErr: (e: string | null) => void;
  onSave: () => Promise<void>;
}) {
  return (
    <div className={`${CARD} space-y-3`}>
      <div className="font-medium text-sm">{draft.id ? "Edit server" : "New server"}</div>
      <div className="grid grid-cols-2 gap-2">
        <label className="text-xs space-y-1">
          <span className={LABEL}>Label</span>
          <input className={INPUT} value={draft.label} onChange={(e) => setDraft({ ...draft, label: e.target.value })} />
        </label>
        <label className="text-xs space-y-1">
          <span className={LABEL}>Username</span>
          <input className={INPUT} value={draft.username} onChange={(e) => setDraft({ ...draft, username: e.target.value })} />
        </label>
        <label className="text-xs space-y-1">
          <span className={LABEL}>Host / address</span>
          <input className={INPUT} value={draft.host} onChange={(e) => setDraft({ ...draft, host: e.target.value })} />
        </label>
        <label className="text-xs space-y-1">
          <span className={LABEL}>Port</span>
          <input
            type="number"
            className={INPUT}
            value={draft.port}
            onChange={(e) => setDraft({ ...draft, port: parseInt(e.target.value || "22", 10) })}
          />
        </label>
        <label className="text-xs space-y-1">
          <span className={LABEL}>Group</span>
          <GroupField
            value={draft.group ?? ""}
            onChange={(group) => setDraft({ ...draft, group })}
            listId="muya-server-groups"
            options={groupOptions}
          />
        </label>
        <label className="text-xs space-y-1">
          <span className={LABEL}>Connection type</span>
          <select
            className={`${INPUT} muya-select`}
            value={draft.connectionType}
            onChange={(e) => setDraft({ ...draft, connectionType: e.target.value as Server["connectionType"] })}
          >
            <option value="direct">Direct</option>
            <option value="psmp">PSMP (jump server)</option>
          </select>
        </label>
        {draft.connectionType === "psmp" && (
          <label className="text-xs space-y-1">
            <span className={LABEL}>PSMP profile</span>
            <select
              className={`${INPUT} muya-select`}
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
          <span className={LABEL}>Credential source</span>
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
          <span className={LABEL}>Extra SSH options (optional)</span>
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
          <span className="text-[var(--text-muted)]">
            Agent may use this server (exposes it by alias to Claude via the muya-mcp MCP; the password is never shared)
          </span>
        </label>
      </div>
      <div className="flex gap-2 justify-end">
        <button type="button" className={BTN_GHOST} onClick={() => setDraft(null)}>
          Cancel
        </button>
        <button type="button" className={BTN} onClick={onSave}>
          Save
        </button>
      </div>
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
        <button type="button" className={ICON_BTN} title="Add PSMP profile" onClick={() => setDraft(blank())}>
          <Plus className="h-4 w-4" />
        </button>
      </div>
      {cfg.psmpProfiles.map((p) => (
        <div key={p.id} className="text-xs font-mono text-[var(--text-muted)] flex justify-between items-center">
          <span className="truncate">
            {p.label}: {p.vaultUser}@…@{p.psmpAddress}
          </span>
          <div className="flex gap-1 shrink-0 items-center">
            <button
              type="button"
              className={ICON_BTN}
              title="Edit profile"
              onClick={() => setDraft({ ...p })}
            >
              <Pencil className="h-4 w-4" />
            </button>
            <button
              type="button"
              className={ICON_BTN_DANGER}
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
              <Trash2 className="h-4 w-4" />
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
        <ShieldCheck className="h-4 w-4 text-[var(--success-text)]" />
        <span className="font-medium text-sm">CyberArk PAM connection</span>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <label className="text-xs space-y-1">
          <span className={LABEL}>PVWA API URL</span>
          <input className={INPUT} placeholder="https://pvwa.corp" value={form.baseUrl} onChange={(e) => setForm({ ...form, baseUrl: e.target.value })} />
        </label>
        <label className="text-xs space-y-1">
          <span className={LABEL}>Vault username</span>
          <input className={INPUT} placeholder="vault-user" value={form.username} onChange={(e) => setForm({ ...form, username: e.target.value })} />
        </label>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <label className="text-xs space-y-1">
          <span className={LABEL}>Auth method</span>
          <select className={`${INPUT} muya-select`} value={form.authMethod} onChange={(e) => setForm({ ...form, authMethod: e.target.value as CyberarkConfig["authMethod"] })}>
            <option>Cyberark</option>
            <option>LDAP</option>
            <option>RADIUS</option>
            <option>Windows</option>
          </select>
        </label>
        <label className="text-xs space-y-1">
          <span className={LABEL}>Internal CA cert path (optional)</span>
          <input className={INPUT} placeholder="/path/to/ca.pem" value={form.caCertPath ?? ""} onChange={(e) => setForm({ ...form, caCertPath: e.target.value || null })} />
        </label>
      </div>
      <div className="space-y-1">
        <span className={LABEL}>Login credential</span>
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
      <label className="flex items-center gap-2 text-xs text-[var(--text-secondary)]">
        <input type="checkbox" checked={form.tlsVerify} onChange={(e) => setForm({ ...form, tlsVerify: e.target.checked })} />
        TLS verification on (recommended — no disable option)
      </label>
      <div className="flex items-center justify-between pt-1">
        <span className="text-xs text-[var(--text-faint)]">
          Pick a stored credential to reuse it, or "Ask each time".
        </span>
        <div className="flex items-center gap-2">
          {saved && (
            <span className="text-xs text-[var(--success-text)] flex items-center gap-1">
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
    <div className="rounded border border-[var(--border)] p-3 space-y-2">
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
        <div className="text-xs text-[var(--success-text)]">{status}</div>
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
                <div key={a.id} className="text-xs font-mono text-[var(--text-secondary)] flex justify-between border-b border-[var(--border)] py-0.5">
                  <span className="truncate">{a.name || a.address} · {a.username}@{a.address}</span>
                  <span className="text-[var(--text-faint)] shrink-0 ml-2">{a.safe}</span>
                </div>
              ))}
              <p className="text-[11px] text-[var(--text-faint)] pt-1">
                {accounts.length} account(s). Assign one to a server in the Servers tab (credential source → CyberArk).
              </p>
            </div>
          )}
        </div>
      )}
      {!loggedOn && (
        <p className="text-[11px] text-[var(--text-faint)]">
          Log on to fetch the account list, then set a server's credential source to a CyberArk account.
        </p>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Password Store tab
// ---------------------------------------------------------------------------
/** What the form edits — `CredInput` on the Rust side (secret included). */
type CredDraft = {
  id?: string;
  label: string;
  username: string;
  secretKind: SecretKind;
  secret: string;
  description: string;
  group: string;
};

function StoreTab({
  store,
  creds,
  biometricAvailable,
  onChange,
  setErr,
}: {
  store: CredStoreStatus;
  creds: CredMeta[];
  biometricAvailable: boolean;
  onChange: () => Promise<void>;
  setErr: (e: string | null) => void;
}) {
  const [master, setMaster] = useState("");
  const [busy, setBusy] = useState(false);
  const [showMaster, setShowMaster] = useState(false);
  const [draft, setDraft] = useState<CredDraft | null>(null);
  const [importDraft, setImportDraft] = useState<{ label: string; username: string } | null>(null);
  // Generic import (any secretKind) — the SSH-key import above predates secretKind/group
  // and stays kind-locked; this covers passwords/tokens/API keys the same way.
  const [importSecretDraft, setImportSecretDraft] = useState<{
    label: string; username: string; secretKind: SecretKind; description: string; group: string;
  } | null>(null);
  const [revealed, setRevealed] = useState<Record<string, string>>({});
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  // Above the locked/uninitialised early returns — hooks must stay unconditional.
  const { collapsed, toggle } = useCollapsedGroups("muya.vault.collapsed");

  // The store can now lock from OUTSIDE this screen (App.tsx's app-wide idle
  // timer, not just the Lock button here) — without this, this tab would keep
  // showing "Unlocked" (and any secret the operator had `reveal`ed stays sitting
  // in `revealed`'s React state) until something else happened to call
  // onChange(). Backend emits this on every lock, manual or idle-triggered.
  useEffect(() => {
    // SshPage itself re-reads the status on this event; here only drop what was revealed.
    const un = listen("muya://vault-locked", () => setRevealed({}));
    return () => { void un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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
  const [biometricBusy, setBiometricBusy] = useState(false);
  // Reads the Keychain-cached key — THIS is the call that pops the OS Touch
  // ID/passcode prompt (nothing on the frontend drives biometry directly).
  const doBiometricUnlock = async () => {
    setBiometricBusy(true);
    try {
      await invoke("credstore_unlock_biometric");
      await onChange();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBiometricBusy(false);
    }
  };
  const enableBiometric = async () => {
    try {
      await invoke("credstore_enable_biometric_unlock");
      await onChange();
    } catch (e) {
      setErr(String(e));
    }
  };
  const disableBiometric = async () => {
    try {
      await invoke("credstore_disable_biometric_unlock");
      await onChange();
    } catch (e) {
      setErr(String(e));
    }
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
  const importSecret = async () => {
    if (!importSecretDraft) return;
    try {
      const src = await pickOpenPath("Select file containing the secret value");
      if (!src) return;
      await invoke<string>("credstore_import_secret", {
        label: importSecretDraft.label || "imported credential",
        username: importSecretDraft.username,
        secretKind: importSecretDraft.secretKind,
        description: importSecretDraft.description,
        group: importSecretDraft.group,
        srcPath: src,
      });
      setImportSecretDraft(null);
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
      await copyToClipboard(value);
      setCopiedId(id);
      setTimeout(() => setCopiedId((c) => (c === id ? null : c)), 1500);
    } catch (e) {
      setErr(String(e));
    }
  };
  const editCred = async (c: CredMeta) => {
    try {
      const secret = await invoke<string>("credstore_reveal_cred", { id: c.id });
      setDraft({ id: c.id, label: c.label, username: c.username, secretKind: c.secretKind, secret, description: c.description ?? "", group: c.group ?? "" });
    } catch (e) {
      setErr(String(e));
    }
  };

  if (!store.initialized) {
    return (
      <div className={`${CARD} space-y-3`}>
        <div className="flex items-center gap-2">
          <KeyRound className="h-4 w-4 text-[var(--accent)]" />
          <span className="font-medium text-sm">Create password store</span>
        </div>
        <p className="text-xs text-[var(--text-muted)]">
          Your credentials are stored encrypted with AES-256-GCM. Keep your master password safe — the app never
          stores it, so you can also export an encrypted backup once unlocked.
        </p>
        <div className="relative">
          <input type={showMaster ? "text" : "password"} className={INPUT} placeholder="Master password" value={master} disabled={busy} onChange={(e) => setMaster(e.target.value)} />
          <button type="button" className="absolute right-2 top-1.5 text-[var(--text-faint)] hover:text-[var(--text)] cursor-pointer" onClick={() => setShowMaster(!showMaster)} title={showMaster ? "Hide" : "Show"}>
            {showMaster ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        </div>
        {busy && <p className="text-xs text-[var(--text-muted)]">Deriving the key (Argon2id) — this can take a second or two.</p>}
        <div className="flex gap-2">
          <button type="button" className={BTN} disabled={busy} onClick={doInit}>
            {busy ? <><Loader2 className="h-4 w-4 inline -mt-0.5 mr-1 animate-spin" /> Creating…</> : "Create"}
          </button>
          <button type="button" className={BTN_GHOST} onClick={exportMaster}>
            <Download className="h-4 w-4 inline -mt-0.5 mr-1" /> Export master password
          </button>
        </div>
        <p className="text-[11px] text-[var(--warning)]">
          ⚠️ "Export master password" saves it to a plaintext file you pick. Prefer keeping it in a password manager — the app never stores it.
        </p>
      </div>
    );
  }

  if (!store.unlocked) {
    return (
      <div className={`${CARD} space-y-3`}>
        <div className="flex items-center gap-2">
          <Lock className="h-4 w-4 text-[var(--warning)]" />
          <span className="font-medium text-sm">Store locked</span>
        </div>
        {biometricAvailable && (
          <button
            type="button"
            className={BTN}
            disabled={biometricBusy}
            onClick={doBiometricUnlock}
          >
            {biometricBusy ? (
              <><Loader2 className="h-4 w-4 inline -mt-0.5 mr-1 animate-spin" /> Waiting for Touch ID…</>
            ) : (
              <><Fingerprint className="h-4 w-4 inline -mt-0.5 mr-1" /> Unlock with Touch ID</>
            )}
          </button>
        )}
        {biometricAvailable && (
          <div className="flex items-center gap-2 text-[10px] text-[var(--text-faint)]">
            <div className="h-px flex-1 bg-[var(--bg-segment)]" />
            or use your master password
            <div className="h-px flex-1 bg-[var(--bg-segment)]" />
          </div>
        )}
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
          <button type="button" className="absolute right-2 top-1.5 text-[var(--text-faint)] hover:text-[var(--text)] cursor-pointer" onClick={() => setShowMaster(!showMaster)} title={showMaster ? "Hide" : "Show"}>
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
        {busy && (
          <p className="text-xs text-[var(--text-muted)]">Deriving the key (Argon2id) — this can take a second or two, hang tight.</p>
        )}
      </div>
    );
  }

  // Group options always come from the FULL list (not the filtered view) so the
  // datalist keeps offering every group even while a search hides most of them.
  const names = groupNames(creds, (c) => c.group);
  const q = query.trim().toLowerCase();
  const filteredCreds = q
    ? creds.filter((c) =>
        [c.label, c.username, c.description, c.group, c.secretKind].some((f) =>
          (f ?? "").toLowerCase().includes(q),
        ),
      )
    : creds;
  const groups = groupItems(filteredCreds, (c) => c.group);

  // One draft at a time, so a single form element is reused wherever it belongs.
  const form = draft && (
    <CredForm draft={draft} setDraft={setDraft} groupOptions={names} onSave={addCred} />
  );

  return (
    <div className="space-y-3">
      <div className="flex justify-between items-center">
        <span className="text-sm text-[var(--success-text)] flex items-center gap-1">
          <Unlock className="h-4 w-4" /> Unlocked · {creds.length} item(s)
        </span>
        <div className="flex gap-2">
          <button type="button" className={BTN} onClick={() => setDraft({ label: "", username: "", secretKind: "password", secret: "", description: "", group: "" })}>
            <Plus className="h-4 w-4 inline -mt-0.5 mr-1" /> Add credential
          </button>
          <button type="button" className={BTN_GHOST} onClick={() => setImportDraft({ label: "", username: "" })}>
            <Upload className="h-4 w-4 inline -mt-0.5 mr-1" /> Import SSH key
          </button>
          <button
            type="button"
            className={BTN_GHOST}
            onClick={() => setImportSecretDraft({ label: "", username: "", secretKind: "password", description: "", group: "" })}
          >
            <Upload className="h-4 w-4 inline -mt-0.5 mr-1" /> Import credential
          </button>
          <button type="button" className={BTN_GHOST} onClick={exportBackup}>
            Export backup
          </button>
          <button
            type="button"
            className={BTN_GHOST}
            onClick={biometricAvailable ? disableBiometric : enableBiometric}
            title={biometricAvailable ? "Stop offering Touch ID unlock" : "Unlock with Touch ID next time, without the master password"}
          >
            <Fingerprint className="h-4 w-4 inline -mt-0.5 mr-1" />
            {biometricAvailable ? "Disable Touch ID" : "Enable Touch ID"}
          </button>
          <button type="button" className={BTN_GHOST} onClick={lock}>
            <Lock className="h-4 w-4 inline -mt-0.5 mr-1" /> Lock
          </button>
        </div>
      </div>

      <div className="relative">
        <SearchIcon className="h-4 w-4 absolute left-2.5 top-1/2 -translate-y-1/2 text-[var(--text-faint)]" />
        <input
          className={`${INPUT} pl-8`}
          placeholder="Search credentials — label, username, group, note…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </div>

      {/* New-item forms lead the list; nothing below them moves. */}
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
      {importSecretDraft && (
        <div className={`${CARD} space-y-2`}>
          <div className="text-sm font-medium">Import a credential from file (password / token / API key / SSH key)</div>
          <div className="grid grid-cols-2 gap-2">
            <input className={INPUT} placeholder="Label" value={importSecretDraft.label} onChange={(e) => setImportSecretDraft({ ...importSecretDraft, label: e.target.value })} />
            <input className={INPUT} placeholder="Username (optional)" value={importSecretDraft.username} onChange={(e) => setImportSecretDraft({ ...importSecretDraft, username: e.target.value })} />
            <select
              aria-label="Import kind"
              className={`${INPUT} muya-select`}
              value={importSecretDraft.secretKind}
              onChange={(e) => setImportSecretDraft({ ...importSecretDraft, secretKind: e.target.value as SecretKind })}
            >
              <option value="password">Password</option>
              <option value="token">Token</option>
              <option value="api_key">API key</option>
              <option value="key">SSH key</option>
            </select>
            <GroupField
              value={importSecretDraft.group}
              onChange={(v) => setImportSecretDraft({ ...importSecretDraft, group: v })}
              options={names}
              listId="import-secret-groups"
            />
            <input className={`${INPUT} col-span-2`} placeholder="Note (optional)" value={importSecretDraft.description} onChange={(e) => setImportSecretDraft({ ...importSecretDraft, description: e.target.value })} />
          </div>
          <p className="text-xs text-[var(--text-faint)]">The file's contents become the secret value; a single trailing newline is dropped automatically (SSH keys are read byte-for-byte).</p>
          <div className="flex gap-2 justify-end">
            <button type="button" className={BTN_GHOST} onClick={() => setImportSecretDraft(null)}>Cancel</button>
            <button type="button" className={BTN} onClick={importSecret}>
              <Upload className="h-4 w-4 inline -mt-0.5 mr-1" /> Choose file & import
            </button>
          </div>
        </div>
      )}
      {draft && !draft.id && form}

      {q && groups.length === 0 && (
        <p className="text-xs text-[var(--text-faint)] text-center py-4">No credentials match &quot;{query}&quot;.</p>
      )}

      {groups.map(([name, items]) => (
        <GroupCard
          key={name}
          name={name}
          count={items.length}
          // A search result stays visibly expanded regardless of the persisted
          // collapse state — the operator is looking for something, not browsing.
          collapsed={q ? false : collapsed.has(name)}
          onToggle={() => toggle(name)}
        >
          {items.map((c) =>
            // Editing swaps the card for the form at the same spot — the operator
            // keeps their place instead of chasing a form at the bottom.
            draft?.id === c.id ? (
              <div key={c.id}>{form}</div>
            ) : (
              <div key={c.id} className={`${CARD} flex flex-col gap-2`}>
                <div className="flex justify-between items-center gap-2">
                  <div className="text-sm min-w-0">
                    <span className="font-medium">{c.label}</span>{" "}
                    <span className="text-xs text-[var(--text-muted)] font-mono">
                      {c.username} · {c.secretKind === "key" ? "SSH key" : c.secretKind === "token" ? "token" : c.secretKind === "api_key" ? "API key" : "password"}
                    </span>
                    {c.description && <div className="text-xs text-[var(--text-faint)] mt-0.5">{c.description}</div>}
                  </div>
                  <div className="flex gap-1 shrink-0">
                    <button type="button" className={ICON_BTN} onClick={() => toggleReveal(c.id)} title={c.id in revealed ? "Hide value" : "View value"}>
                      {c.id in revealed ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                    </button>
                    <button type="button" className={ICON_BTN} onClick={() => copyCred(c.id)} title="Copy value">
                      {copiedId === c.id ? <Check className="h-4 w-4 text-[var(--success-text)]" /> : <Copy className="h-4 w-4" />}
                    </button>
                    <button type="button" className={ICON_BTN} onClick={() => editCred(c)} title="Edit credential">
                      <Pencil className="h-4 w-4" />
                    </button>
                    <button type="button" className={ICON_BTN} onClick={() => exportCred(c)} title={`Export ${c.secretKind}`}>
                      <Download className="h-4 w-4" />
                    </button>
                    <button type="button" className={ICON_BTN_DANGER} onClick={() => removeCred(c.id)}>
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                </div>
                {c.id in revealed && (
                  <pre className="text-xs font-mono bg-[var(--bg-segment)] rounded p-2 whitespace-pre-wrap break-all select-text max-h-40 overflow-auto">
                    {revealed[c.id]}
                  </pre>
                )}
              </div>
            ),
          )}
        </GroupCard>
      ))}
    </div>
  );
}

function CredForm({
  draft,
  setDraft,
  groupOptions,
  onSave,
}: {
  draft: CredDraft;
  setDraft: (d: CredDraft | null) => void;
  groupOptions: string[];
  onSave: () => Promise<void>;
}) {
  return (
    <div className={`${CARD} space-y-2`}>
      <div className="font-medium text-sm">{draft.id ? "Edit credential" : "New credential"}</div>
      <div className="grid grid-cols-2 gap-2">
        <input className={INPUT} placeholder="Label" value={draft.label} onChange={(e) => setDraft({ ...draft, label: e.target.value })} />
        <input className={INPUT} placeholder="Username" value={draft.username} onChange={(e) => setDraft({ ...draft, username: e.target.value })} />
        <select aria-label="Secret kind" className={`${INPUT} muya-select`} value={draft.secretKind} onChange={(e) => setDraft({ ...draft, secretKind: e.target.value as SecretKind })}>
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
        <GroupField
          value={draft.group}
          onChange={(group) => setDraft({ ...draft, group })}
          listId="muya-cred-groups"
          options={groupOptions}
          className="col-span-2"
        />
        <input className={`${INPUT} col-span-2`} placeholder="Description (optional — shown to agents by name)" value={draft.description} onChange={(e) => setDraft({ ...draft, description: e.target.value })} />
      </div>
      <div className="flex gap-2 justify-end">
        <button type="button" className={BTN_GHOST} onClick={() => setDraft(null)}>Cancel</button>
        <button type="button" className={BTN} onClick={onSave}>Save</button>
      </div>
    </div>
  );
}
