// DEV-ONLY in-memory fake of the Rust command backend.
//
// TAK-ÇIKAR: this file is only ever pulled in by (a) the browser dev shim
// (`installTauriMock`, gated behind the `VITE_BROWSER_MOCK` env flag and a
// dynamic import — absent from any release build) and (b) vitest component
// tests. It NEVER ships in a production bundle and NEVER runs inside the real
// Tauri app.
//
// It mirrors the observable behaviour of `src-tauri/src/ssh.rs` +
// `credstore.rs` (dedup rule, lock states) closely enough to drive/verify the
// SSH page UI without a running Rust core.

type Json = Record<string, unknown>;

type Server = {
  id: string;
  label: string;
  host: string;
  port: number;
  username: string;
  connectionType: "direct" | "psmp";
  psmpProfileId?: string | null;
  credentialSource: { kind: string; localCredId?: string | null; cyberarkAccountId?: string | null };
  lastConnectedAt?: string | null;
  tags: string[];
};
type Cred = { id: string; label: string; username: string; secretKind: "password" | "key" | "token" | "api_key"; secret: string; description?: string };

type State = {
  ssh: { version: number; servers: Server[]; psmpProfiles: any[]; cyberark: Json | null };
  store: { initialized: boolean; unlocked: boolean; master: string | null; creds: Cred[] };
};

let state: State = freshState();

function freshState(): State {
  return {
    ssh: { version: 1, servers: [], psmpProfiles: [], cyberark: null },
    store: { initialized: false, unlocked: false, master: null, creds: [] },
  };
}

/** Reset to a clean backend — used by tests between cases. */
export function resetMockBackend() {
  state = freshState();
}

function genId(): string {
  return Math.random().toString(16).slice(2) + Date.now().toString(16);
}

function dedupKey(host: string, port: number, username: string): string {
  return `${host.trim().toLowerCase()}|${port}|${username.trim()}`;
}

function upsertServer(input: Server): string {
  const server: Server = { ...input, port: input.port || 22 };
  if (!server.host?.trim()) throw "host is required";
  if (!server.username?.trim()) throw "username is required";
  if (server.connectionType === "psmp" && !server.psmpProfileId) throw "a PSMP server needs a psmpProfileId";
  const key = dedupKey(server.host, server.port, server.username);
  const editing = server.id || null;
  const collision = state.ssh.servers.some(
    (s) => dedupKey(s.host, s.port, s.username) === key && s.id !== editing,
  );
  if (collision) {
    throw `a server for ${server.username.trim()}@${server.host.trim().toLowerCase()}:${server.port} already exists (duplicate)`;
  }
  if (editing) {
    const i = state.ssh.servers.findIndex((s) => s.id === editing);
    if (i < 0) throw "server not found";
    state.ssh.servers[i] = { ...server, id: editing };
    return editing;
  }
  const id = genId();
  state.ssh.servers.push({ ...server, id });
  return id;
}

/**
 * The dev/test dispatcher. Mirrors `invoke(cmd, payload)`. Rejects with a plain
 * string to match how Tauri surfaces `Err(String)`.
 */
export async function mockInvoke(cmd: string, payload: Json = {}): Promise<unknown> {
  switch (cmd) {
    // ---- ssh.rs ----
    case "ssh_get_config":
      return state.ssh;
    case "ssh_list_servers":
      return state.ssh.servers;
    case "ssh_upsert_server":
      return upsertServer(payload.server as Server);
    case "ssh_remove_server": {
      const before = state.ssh.servers.length;
      state.ssh.servers = state.ssh.servers.filter((s) => s.id !== payload.id);
      if (state.ssh.servers.length === before) throw "server not found";
      return null;
    }
    case "ssh_upsert_psmp_profile": {
      const p = payload.profile as any;
      if (!p.psmpAddress?.trim() || !p.vaultUser?.trim()) throw "psmpAddress and vaultUser are required";
      if (p.id) {
        const i = state.ssh.psmpProfiles.findIndex((x: any) => x.id === p.id);
        if (i >= 0) state.ssh.psmpProfiles[i] = p;
        else state.ssh.psmpProfiles.push(p);
        return p.id;
      }
      const id = genId();
      state.ssh.psmpProfiles.push({ ...p, id, userDelim: p.userDelim || "@", paramDelim: p.paramDelim || "#" });
      return id;
    }
    case "ssh_remove_psmp_profile": {
      if (state.ssh.servers.some((s) => s.psmpProfileId === payload.id))
        throw "PSMP profile is in use by a server";
      state.ssh.psmpProfiles = state.ssh.psmpProfiles.filter((p: any) => p.id !== payload.id);
      return null;
    }
    case "ssh_set_cyberark_config": {
      const c = payload.config as Json;
      if (!String((c as any).baseUrl ?? "").trim()) throw "baseUrl is required";
      state.ssh.cyberark = c;
      return null;
    }

    // ---- credstore.rs ----
    case "credstore_status":
      return { initialized: state.store.initialized, unlocked: state.store.unlocked };
    case "credstore_init":
      state.store.initialized = true;
      state.store.unlocked = true;
      state.store.master = String(payload.master ?? "");
      return null;
    case "credstore_unlock":
      if (String(payload.master ?? "") !== state.store.master)
        throw "decryption failed (wrong master password or corrupted store)";
      state.store.unlocked = true;
      return null;
    case "credstore_lock":
      state.store.unlocked = false;
      return null;
    case "credstore_cred_list":
      if (!state.store.unlocked) throw "store is locked";
      return state.store.creds.map((c) => ({
        id: c.id,
        label: c.label,
        username: c.username,
        secretKind: c.secretKind,
        description: c.description ?? "",
      }));
    case "credstore_cred_upsert": {
      if (!state.store.unlocked) throw "store is locked";
      const c = payload.cred as Cred;
      if (c.id) {
        const i = state.store.creds.findIndex((x) => x.id === c.id);
        if (i >= 0) state.store.creds[i] = c;
        return c.id;
      }
      const id = genId();
      state.store.creds.push({ ...c, id });
      return id;
    }
    case "credstore_cred_remove":
      if (!state.store.unlocked) throw "store is locked";
      state.store.creds = state.store.creds.filter((c) => c.id !== payload.id);
      return null;

    // ---- Tauri plugin/event plumbing: keep the app from crashing in-browser ----
    default:
      if (cmd.startsWith("plugin:")) return 0;
      // Most other commands return arrays; an empty array is the safest default
      // so App.tsx's other pages boot without white-screening.
      return [];
  }
}
