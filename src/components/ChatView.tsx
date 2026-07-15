import { useState, useEffect, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  Plus, X, Wifi, HardDrive, Send, Radio, Shield, Bot, User,
  Circle, RefreshCw, KeyRound,
} from "lucide-react";

// ─── Types mirroring the Rust bridge command surface ────────────────────────
// NOTE: the Rust structs (PinnedPeer, InboundRequest) derive Serialize WITHOUT
// #[serde(rename_all = "camelCase")], so Tauri returns snake_case keys. Tauri v2
// only camelCase→snake_case-maps command ARGUMENTS, not return-struct fields —
// so these interfaces MUST be snake_case to match the wire shape.
interface PinnedPeer {
  spki_hash: string;
  label: string;
  last_addr: string | null;
  paired_at: number;
}
interface InboundRequest {
  req_id: string;
  peer: string;
  capability: string;
  kind: string;
  payload: unknown;
  approval: string;
}

type ConnKind = "local" | "remote";
interface Conn {
  id: string;            // "local" or the peer spki hash
  kind: ConnKind;
  label: string;
  addr?: string | null;
}
interface Msg {
  id: string;
  from: "me" | "peer";
  text: string;
  ts: number;
}

const LOCAL_CONN: Conn = { id: "local", kind: "local", label: "Local (this machine)" };

export default function ChatView() {
  const [conns, setConns] = useState<Conn[]>([LOCAL_CONN]);
  const [activeId, setActiveId] = useState<string>("local");
  const [threads, setThreads] = useState<Record<string, Msg[]>>({ local: [] });
  const [draft, setDraft] = useState("");
  const [addOpen, setAddOpen] = useState(false);
  const [listening, setListening] = useState(false);
  const [invitePin, setInvitePin] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  const active = conns.find((c) => c.id === activeId) ?? LOCAL_CONN;
  const messages = threads[activeId] ?? [];

  // Load paired remote peers into the connection list.
  const refreshPeers = useCallback(async () => {
    try {
      const peers = await invoke<PinnedPeer[]>("bridge_list_peers");
      setConns((prev) => {
        const remotes: Conn[] = peers.map((p) => ({
          id: p.spki_hash, kind: "remote", label: p.label, addr: p.last_addr,
        }));
        return [LOCAL_CONN, ...remotes];
      });
    } catch { /* remote bridge not initialized yet — local still works */ }
  }, []);

  useEffect(() => { void refreshPeers(); }, [refreshPeers]);

  // Poll the broker queue for inbound messages/tasks and append to threads.
  useEffect(() => {
    const t = setInterval(async () => {
      try {
        const inbound = await invoke<InboundRequest[]>("bridge_poll_inbound");
        if (!inbound.length) return;
        setThreads((prev) => {
          const next = { ...prev };
          for (const r of inbound) {
            const key = r.peer && r.peer !== "local" ? r.peer : "local";
            const text = typeof r.payload === "string" ? r.payload : JSON.stringify(r.payload);
            const arr = next[key] ? [...next[key]] : [];
            arr.push({ id: r.req_id, from: "peer", text, ts: Date.now() });
            next[key] = arr;
          }
          return next;
        });
      } catch { /* bridge idle */ }
    }, 1500);
    return () => clearInterval(t);
  }, []);

  useEffect(() => { scrollRef.current?.scrollTo?.({ top: scrollRef.current.scrollHeight }); }, [messages.length, activeId]);

  const send = async () => {
    const text = draft.trim();
    if (!text) return;
    setDraft("");
    setThreads((prev) => {
      const arr = prev[activeId] ? [...prev[activeId]] : [];
      arr.push({ id: `me-${Date.now()}`, from: "me", text, ts: Date.now() });
      return { ...prev, [activeId]: arr };
    });
    try {
      await invoke("bridge_send", {
        peer: active.kind === "local" ? "local" : active.id,
        kind: "question",
        payload: text,
      });
    } catch (e) {
      setThreads((prev) => {
        const arr = prev[activeId] ? [...prev[activeId]] : [];
        arr.push({ id: `err-${Date.now()}`, from: "peer", text: `⚠️ send failed: ${e}`, ts: Date.now() });
        return { ...prev, [activeId]: arr };
      });
    }
  };

  // Toggle accepting incoming connections (remote listener + show pairing PIN).
  const toggleListen = async () => {
    try {
      if (!listening) {
        await invoke("bridge_local_listen", { enable: true });
        const res = await invoke<{ pin: string }>("bridge_pair_invite").catch(() => null);
        if (res?.pin) setInvitePin(res.pin);
        setListening(true);
      } else {
        await invoke("bridge_local_listen", { enable: false });
        setInvitePin(null);
        setListening(false);
      }
    } catch (e) {
      setInvitePin(null);
      alert(`Listen toggle failed: ${e}`);
    }
  };

  return (
    <div className="flex-1 flex overflow-hidden bg-white dark:bg-[#1e1f23]">
      {/* ── Connection rail ── */}
      <aside className="w-60 shrink-0 border-r border-neutral-200 dark:border-[#3d3f44] flex flex-col bg-neutral-50 dark:bg-[#25272b]">
        <div className="px-3 py-2.5 flex items-center justify-between border-b border-neutral-200 dark:border-[#3d3f44]">
          <span className="text-[10px] font-mono font-bold uppercase tracking-wider text-neutral-500 dark:text-neutral-400 flex items-center gap-1.5">
            <Bot className="h-3.5 w-3.5 text-indigo-500" /> Claude Chat
          </span>
          <button
            type="button"
            onClick={() => setAddOpen(true)}
            title="New connection"
            className="p-1 rounded bg-indigo-600 hover:bg-indigo-700 text-white cursor-pointer transition-colors"
          >
            <Plus className="h-3.5 w-3.5" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-1.5 space-y-0.5">
          {conns.map((c) => (
            <button
              key={c.id}
              type="button"
              onClick={() => { setActiveId(c.id); setThreads((p) => (p[c.id] ? p : { ...p, [c.id]: [] })); }}
              className={`w-full text-left px-2.5 py-2 rounded-lg flex items-center gap-2 cursor-pointer transition-colors ${
                activeId === c.id
                  ? "bg-indigo-600 dark:bg-indigo-500 text-white"
                  : "hover:bg-neutral-100 dark:hover:bg-neutral-800 text-neutral-700 dark:text-neutral-300"
              }`}
            >
              {c.kind === "local"
                ? <HardDrive className={`h-4 w-4 shrink-0 ${activeId === c.id ? "text-white" : "text-emerald-500"}`} />
                : <Wifi className={`h-4 w-4 shrink-0 ${activeId === c.id ? "text-white" : "text-violet-500"}`} />}
              <div className="min-w-0 flex-1">
                <div className="text-[11px] font-mono font-semibold truncate">{c.label}</div>
                {c.addr && <div className={`text-[9px] font-mono truncate ${activeId === c.id ? "text-indigo-100" : "text-neutral-400"}`}>{c.addr}</div>}
              </div>
              {c.kind === "remote" && <Shield className={`h-3 w-3 shrink-0 ${activeId === c.id ? "text-indigo-100" : "text-neutral-400"}`} />}
            </button>
          ))}
        </div>

        {/* Listen toggle + PIN */}
        <div className="p-2 border-t border-neutral-200 dark:border-[#3d3f44] space-y-1.5">
          <button
            type="button"
            onClick={() => void toggleListen()}
            className={`w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded text-[10px] font-mono font-bold cursor-pointer transition-colors ${
              listening
                ? "bg-emerald-100 dark:bg-emerald-900/40 text-emerald-700 dark:text-emerald-300 border border-emerald-300 dark:border-emerald-700"
                : "text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 border border-neutral-200 dark:border-neutral-700"
            }`}
          >
            <Radio className={`h-3 w-3 ${listening ? "animate-pulse" : ""}`} /> {listening ? "Listening for peers" : "Accept connections"}
          </button>
          {invitePin && (
            <div className="text-center bg-violet-50 dark:bg-violet-950/30 border border-violet-200 dark:border-violet-800 rounded p-1.5">
              <div className="text-[8px] font-mono uppercase text-violet-500 flex items-center justify-center gap-1"><KeyRound className="h-2.5 w-2.5" /> Pairing PIN</div>
              <div className="text-lg font-mono font-bold tracking-widest text-violet-700 dark:text-violet-300">{invitePin}</div>
            </div>
          )}
        </div>
      </aside>

      {/* ── Chat thread ── */}
      <div className="flex-1 flex flex-col overflow-hidden">
        <div className="px-4 py-2.5 border-b border-neutral-200 dark:border-[#3d3f44] flex items-center gap-2 bg-neutral-50 dark:bg-[#25272b]">
          {active.kind === "local" ? <HardDrive className="h-4 w-4 text-emerald-500" /> : <Wifi className="h-4 w-4 text-violet-500" />}
          <span className="text-sm font-mono font-bold text-neutral-800 dark:text-neutral-100">{active.label}</span>
          {active.addr && <span className="text-[10px] font-mono text-neutral-400">{active.addr}</span>}
          <span className="ml-auto flex items-center gap-1 text-[10px] font-mono text-neutral-400">
            <Circle className="h-2 w-2 fill-emerald-500 text-emerald-500" />
            {active.kind === "local" ? "no auth (same machine)" : "mTLS · paired"}
          </span>
        </div>

        <div ref={scrollRef} className="flex-1 overflow-y-auto px-4 py-4 space-y-3">
          {messages.length === 0 && (
            <div className="h-full flex flex-col items-center justify-center text-neutral-400 dark:text-neutral-600 gap-2">
              <Bot className="h-8 w-8 opacity-30" />
              <p className="text-xs font-mono">Send a message to {active.kind === "local" ? "your local Claude" : "the remote Claude"}.</p>
            </div>
          )}
          {messages.map((m) => (
            <div key={m.id} className={`flex gap-2 ${m.from === "me" ? "flex-row-reverse" : "flex-row"}`}>
              <div className={`shrink-0 h-6 w-6 rounded-full flex items-center justify-center mt-0.5 ${
                m.from === "me" ? "bg-indigo-600 text-white" : "bg-violet-500 text-white"
              }`}>
                {m.from === "me" ? <User className="h-3.5 w-3.5" /> : <Bot className="h-3.5 w-3.5" />}
              </div>
              <div className={`max-w-[70%] rounded-2xl px-3.5 py-2 text-[12px] leading-relaxed whitespace-pre-wrap break-words ${
                m.from === "me"
                  ? "bg-indigo-600 text-white rounded-tr-sm"
                  : "bg-neutral-100 dark:bg-[#2d2f34] text-neutral-800 dark:text-neutral-200 rounded-tl-sm"
              }`}>
                {m.text}
              </div>
            </div>
          ))}
        </div>

        <div className="p-3 border-t border-neutral-200 dark:border-[#3d3f44] flex gap-2">
          <input
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void send(); } }}
            placeholder={`Message ${active.label}…`}
            className="flex-1 px-3 py-2 text-[12px] font-mono rounded-lg border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-indigo-400"
          />
          <button
            type="button"
            onClick={() => void send()}
            disabled={!draft.trim()}
            className="px-3.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 disabled:opacity-40 text-white cursor-pointer disabled:cursor-not-allowed transition-colors"
          >
            <Send className="h-4 w-4" />
          </button>
        </div>
      </div>

      {addOpen && (
        <AddConnectionModal
          onClose={() => setAddOpen(false)}
          onLocal={async () => {
            await invoke("bridge_local_listen", { enable: true }).catch(() => {});
            setActiveId("local");
            setAddOpen(false);
          }}
          onRemote={async (ip, port, pin, label) => {
            const addr = `${ip}:${port}`;
            const res = await invoke<{ sas: string; peer_spki: string }>("bridge_pair_connect", { addr, pin, label });
            // Auto-confirm SAS in this MVP flow; a stricter flow would show it for comparison.
            await invoke("bridge_pair_confirm_sas", { peer: res.peer_spki, sasOk: true }).catch(() => {});
            await refreshPeers();
            setActiveId(res.peer_spki);
            setAddOpen(false);
          }}
        />
      )}
    </div>
  );
}

// ─── Add-connection modal: Local vs Remote (IP + port + PIN) ─────────────────
function AddConnectionModal({
  onClose, onLocal, onRemote,
}: {
  onClose: () => void;
  onLocal: () => Promise<void>;
  onRemote: (ip: string, port: string, pin: string, label: string) => Promise<void>;
}) {
  const [mode, setMode] = useState<ConnKind>("remote");
  const [ip, setIp] = useState("");
  const [port, setPort] = useState("");
  const [pin, setPin] = useState("");
  const [label, setLabel] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const go = async () => {
    setBusy(true); setErr(null);
    try {
      if (mode === "local") await onLocal();
      else {
        if (!ip.trim() || !port.trim() || !pin.trim()) { setErr("IP, port ve PIN gerekli."); setBusy(false); return; }
        await onRemote(ip.trim(), port.trim(), pin.trim(), label.trim() || `${ip.trim()}:${port.trim()}`);
      }
    } catch (e) { setErr(String(e)); }
    finally { setBusy(false); }
  };

  const seg = "flex-1 flex items-center justify-center gap-1.5 px-3 py-2 text-[11px] font-mono font-bold rounded-lg cursor-pointer transition-colors";
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm p-6" onClick={onClose}>
      <div className="w-[420px] max-w-full bg-white dark:bg-[#25272b] rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-200 dark:border-neutral-700">
          <span className="text-sm font-display font-bold text-neutral-800 dark:text-neutral-200 flex items-center gap-2">
            <Plus className="h-4 w-4 text-indigo-500" /> New Connection
          </span>
          <button type="button" onClick={onClose} className="text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 cursor-pointer"><X className="h-4 w-4" /></button>
        </div>

        <div className="p-4 space-y-3">
          <div className="flex gap-2">
            <button type="button" onClick={() => setMode("local")}
              className={`${seg} ${mode === "local" ? "bg-indigo-600 text-white" : "border border-neutral-200 dark:border-neutral-700 text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"}`}>
              <HardDrive className="h-3.5 w-3.5" /> Local
            </button>
            <button type="button" onClick={() => setMode("remote")}
              className={`${seg} ${mode === "remote" ? "bg-indigo-600 text-white" : "border border-neutral-200 dark:border-neutral-700 text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"}`}>
              <Wifi className="h-3.5 w-3.5" /> Remote
            </button>
          </div>

          {mode === "local" ? (
            <p className="text-[11px] font-mono text-neutral-500 dark:text-neutral-400 bg-neutral-50 dark:bg-neutral-950 rounded p-3">
              Same-machine bridge over an owner-only socket. No IP, port, or PIN — no password is ever asked on localhost.
            </p>
          ) : (
            <div className="space-y-2">
              <div className="flex gap-2">
                <div className="flex-1">
                  <label className="text-[9px] font-mono uppercase text-neutral-500 dark:text-neutral-400">IP address</label>
                  <input value={ip} onChange={(e) => setIp(e.target.value)} placeholder="192.168.1.42"
                    className="w-full mt-0.5 px-2.5 py-1.5 text-[12px] font-mono rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-violet-400" />
                </div>
                <div className="w-24">
                  <label className="text-[9px] font-mono uppercase text-neutral-500 dark:text-neutral-400">Port</label>
                  <input value={port} onChange={(e) => setPort(e.target.value)} placeholder="7420"
                    className="w-full mt-0.5 px-2.5 py-1.5 text-[12px] font-mono rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-violet-400" />
                </div>
              </div>
              <div>
                <label className="text-[9px] font-mono uppercase text-neutral-500 dark:text-neutral-400 flex items-center gap-1"><KeyRound className="h-2.5 w-2.5" /> Pairing PIN (from the peer)</label>
                <input value={pin} onChange={(e) => setPin(e.target.value)} placeholder="8-digit PIN"
                  className="w-full mt-0.5 px-2.5 py-1.5 text-[12px] font-mono tracking-widest rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-violet-400" />
              </div>
              <div>
                <label className="text-[9px] font-mono uppercase text-neutral-500 dark:text-neutral-400">Label (optional)</label>
                <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="lab-mac"
                  className="w-full mt-0.5 px-2.5 py-1.5 text-[12px] font-mono rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-violet-400" />
              </div>
              <p className="text-[9px] font-mono text-neutral-400 flex items-center gap-1">
                <Shield className="h-2.5 w-2.5" /> First pairing runs SPAKE2 + mTLS; the PIN is single-use.
              </p>
            </div>
          )}

          {err && <p className="text-[10px] font-mono text-rose-500 break-words">{err}</p>}

          <button type="button" onClick={() => void go()} disabled={busy}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 disabled:opacity-40 text-white text-xs font-mono font-bold cursor-pointer disabled:cursor-not-allowed transition-colors">
            {busy ? <><RefreshCw className="h-3.5 w-3.5 animate-spin" /> Connecting…</> : <>Connect</>}
          </button>
        </div>
      </div>
    </div>
  );
}
