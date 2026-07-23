import { useState, useEffect, useRef, useCallback, type MouseEvent } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  Plus, X, Wifi, HardDrive, Send, Radio, Shield, Bot, User,
  Circle, RefreshCw, KeyRound, Check, Network, AlertTriangle, Loader2,
} from "lucide-react";

const BRIDGE_PORT = 7420;

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
  const [pinCopied, setPinCopied] = useState(false);
  // Auto-respond: when ON, an inbound QUESTION is answered by running the local
  // Claude headlessly (bridge_run_claude) and the answer is sent back — this is
  // what makes two Claudes converse. Opt-in (off by default) for safety.
  const [autoRespond, setAutoRespond] = useState(false);
  const autoRespondRef = useRef(false);
  useEffect(() => { autoRespondRef.current = autoRespond; }, [autoRespond]);
  // LAN address shown while accepting remote connections (so the dialer knows where to dial).
  const [listenAddr, setListenAddr] = useState<string | null>(null);
  // Peer pending an "end session" confirmation (in-app modal, not native confirm).
  const [pendingRevoke, setPendingRevoke] = useState<Conn | null>(null);
  // User-editable listen interface: IP (prefilled with the detected LAN IP) +
  // port (default 7420). Lets the operator pick the right interface/port when
  // the auto-detected default doesn't work (multi-NIC, port in use, firewall).
  const [listenIp, setListenIp] = useState("");
  const [listenPort, setListenPort] = useState(String(BRIDGE_PORT));
  // Result of bridge_check_port pre-flight validation (null = not checked yet).
  const [portCheck, setPortCheck] = useState<{ ok: boolean; listening: boolean; detail: string } | null>(null);
  const [checkingPort, setCheckingPort] = useState(false);
  const [listenCfgOpen, setListenCfgOpen] = useState(false);
  // SAS-compare prompt — the human confirms the 6-digit code matches on both ends.
  const [sasPrompt, setSasPrompt] = useState<{ sas: string; peerSpki: string; label: string; side: "dialer" | "invitee" } | null>(null);
  const listenAddrRef = useRef<string | null>(null);
  useEffect(() => { listenAddrRef.current = listenAddr; }, [listenAddr]);

  // Prefill the listen IP with the machine's detected LAN address once.
  // Guard against a missing/empty result so listenIp stays a string.
  useEffect(() => {
    invoke<string>("local_ip").then((ip) => { if (ip) setListenIp((cur) => cur || ip); }).catch(() => {});
  }, []);

  const copyPin = useCallback((e?: MouseEvent) => {
    e?.preventDefault();
    if (!invitePin) return;
    void navigator.clipboard.writeText(invitePin).then(() => {
      setPinCopied(true);
      setTimeout(() => setPinCopied(false), 1400);
    });
  }, [invitePin]);
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

  // End a paired session: revoke (unpin) the peer's SPKI so no further remote
  // traffic is possible without re-pairing. This is the counterpart to pairing
  // (Add → Remove). Gated by an in-app confirm modal (NOT window.confirm, which
  // in a Tauri webview opens a blocking native dialog) because it's not silently
  // reversible — the peer must run SPAKE2 + SAS again to reconnect.
  const doRevoke = useCallback(async (c: Conn) => {
    setPendingRevoke(null);
    try {
      await invoke("bridge_revoke_peer", { spkiHash: c.id });
    } catch (e) {
      setThreads((p) => ({ ...p, [c.id]: [...(p[c.id] ?? []), { id: `err-${Date.now()}`, from: "peer", text: `Failed to end session: ${e}`, ts: Date.now() }] }));
      return;
    }
    // Drop its thread and fall back to Local if it was the active connection.
    setThreads((p) => { const n = { ...p }; delete n[c.id]; return n; });
    setActiveId((cur) => (cur === c.id ? "local" : cur));
    await refreshPeers();
  }, [refreshPeers]);

  // Reply to a peer over the same transport the request arrived on.
  const replyTo = useCallback(async (peerKey: string, payload: unknown) => {
    if (peerKey === "local") {
      await invoke("bridge_send", { peer: "local", kind: "question", payload });
    } else {
      await invoke("bridge_remote_send", { peer: peerKey, kind: "question", payload });
    }
  }, []);

  // Poll the broker queue for inbound messages, display them, and — when
  // auto-respond is on — answer inbound QUESTIONS via the local Claude.
  useEffect(() => {
    const t = setInterval(async () => {
      let inbound: InboundRequest[] = [];
      try {
        inbound = await invoke<InboundRequest[]>("bridge_poll_inbound");
      } catch { return; }
      if (!inbound.length) return;

      for (const r of inbound) {
        const key = r.peer && r.peer !== "local" ? r.peer : "local";
        // An answer we sent back is wrapped as { answer }; a question is a plain
        // string. This split prevents an infinite answer↔answer loop.
        const isAnswer = r.payload && typeof r.payload === "object" && "answer" in (r.payload as object);
        const text = isAnswer
          ? String((r.payload as { answer: unknown }).answer)
          : typeof r.payload === "string" ? r.payload : JSON.stringify(r.payload);

        setThreads((prev) => {
          const arr = prev[key] ? [...prev[key]] : [];
          arr.push({ id: r.req_id, from: "peer", text, ts: Date.now() });
          return { ...prev, [key]: arr };
        });

        // Auto-respond to a genuine inbound question.
        if (!isAnswer && autoRespondRef.current && r.kind === "question") {
          void (async () => {
            try {
              const answer = await invoke<string>("bridge_run_claude", { question: text });
              await replyTo(key, { answer });
              setThreads((prev) => {
                const arr = prev[key] ? [...prev[key]] : [];
                arr.push({ id: `resp-${r.req_id}`, from: "me", text: answer, ts: Date.now() });
                return { ...prev, [key]: arr };
              });
            } catch (e) {
              setThreads((prev) => {
                const arr = prev[key] ? [...prev[key]] : [];
                arr.push({ id: `resperr-${r.req_id}`, from: "me", text: `⚠️ auto-respond failed: ${e}`, ts: Date.now() });
                return { ...prev, [key]: arr };
              });
            }
          })();
        }
      }
    }, 1500);
    return () => clearInterval(t);
  }, [replyTo]);

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
      if (active.kind === "remote") {
        await invoke("bridge_remote_send", { peer: active.id, kind: "question", payload: text });
      } else {
        await invoke("bridge_send", { peer: "local", kind: "question", payload: text });
      }
    } catch (e) {
      setThreads((prev) => {
        const arr = prev[activeId] ? [...prev[activeId]] : [];
        arr.push({ id: `err-${Date.now()}`, from: "peer", text: `⚠️ send failed: ${e}`, ts: Date.now() });
        return { ...prev, [activeId]: arr };
      });
    }
  };

  // Toggle accepting incoming connections (remote listener + show pairing PIN).
  // Invitee side: when a dialer completes the PAKE handshake, the backend emits
  // the SAS + the dialer's SPKI. Show it for the human to compare & confirm.
  useEffect(() => {
    const un = listen<{ sas: string; peerSpki: string; peerAddr?: string }>("bridge://sas-compare", (e) => {
      setSasPrompt({ sas: e.payload.sas, peerSpki: e.payload.peerSpki, label: e.payload.peerAddr ?? "peer", side: "invitee" });
    });
    return () => { void un.then((f) => f()); };
  }, []);

  // Human confirmed the SAS matches → pin the peer. On the invitee side, also
  // start the data listener (same port) now that pairing succeeded.
  const confirmSas = async (ok: boolean) => {
    const p = sasPrompt;
    setSasPrompt(null);
    if (!p) return;
    try {
      await invoke("bridge_pair_confirm_sas", { peerSpki: p.peerSpki, sasOk: ok, label: p.label });
      if (ok) {
        await refreshPeers();
        if (p.side === "invitee" && listenAddrRef.current) {
          // Pairing listener was single-use; now serve the mTLS data channel on the same addr.
          await invoke("bridge_remote_listen", { enable: true, iface: listenAddrRef.current }).catch(() => {});
        }
      }
    } catch (e) {
      alert(`SAS confirm failed: ${e}`);
    }
  };

  const listenTarget = () => `${listenIp.trim()}:${listenPort.trim()}`;

  // Pre-flight: validate the IP:port BEFORE binding the (single-use) pairing
  // listener, so we never consume its one accept just to test reachability.
  const checkPort = async (): Promise<boolean> => {
    setCheckingPort(true);
    try {
      const r = await invoke<{ ok: boolean; listening: boolean; detail: string }>(
        "bridge_check_port", { addr: listenTarget() });
      setPortCheck(r);
      return r.ok;
    } catch (e) {
      setPortCheck({ ok: false, listening: false, detail: `Validation error: ${e}` });
      return false;
    } finally {
      setCheckingPort(false);
    }
  };

  const toggleListen = async () => {
    if (!listening) {
      // Pre-flight only — proves the port is currently bindable. NOT a success
      // claim; the authoritative result comes from actually starting below.
      const ok = await checkPort();
      if (!ok) { setListenCfgOpen(true); return; }

      const addr = listenTarget();
      // Do the REAL work. Any failure here (local socket bind/chmod, TCP bind)
      // is surfaced inline as the honest status — we NEVER leave a green
      // "success" standing when the operation didn't actually complete (L10).
      try {
        await invoke("bridge_local_listen", { enable: true });
        await invoke("bridge_pair_start_listener", { pairingIface: addr });
      } catch (e) {
        await invoke("bridge_local_listen", { enable: false }).catch(() => {});
        setPortCheck({ ok: false, listening: false, detail: `Failed to start listener: ${e}` });
        setListenCfgOpen(true);
        setInvitePin(null);
        setListenAddr(null);
        setListening(false);
        return;
      }
      // Only now that both binds actually succeeded do we assert "listening".
      setListenAddr(addr);
      await checkPort(); // re-probe → confirms "Listening (ours)" from ground truth
      const res = await invoke<{ pin: string }>("bridge_pair_invite").catch(() => null);
      if (res?.pin) setInvitePin(res.pin);
      setListening(true);
    } else {
      // Tear DOWN everything we brought up — mirror of the start path. The
      // pairing listener holds the TCP port; bridge_pair_stop_listener aborts
      // its accept task so the port is actually released (not just visually
      // toggled off). L10: stopping must really stop, verified by a freed port.
      try {
        await invoke("bridge_pair_stop_listener");
        await invoke("bridge_local_listen", { enable: false });
        await invoke("bridge_remote_listen", { enable: false, iface: listenAddr ?? "" }).catch(() => {});
      } catch { /* best-effort teardown */ }
      setInvitePin(null);
      setListenAddr(null);
      setPortCheck(null);
      setListening(false);
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
            <div
              key={c.id}
              role="button"
              tabIndex={0}
              onClick={() => { setActiveId(c.id); setThreads((p) => (p[c.id] ? p : { ...p, [c.id]: [] })); }}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { setActiveId(c.id); setThreads((p) => (p[c.id] ? p : { ...p, [c.id]: [] })); } }}
              className={`group w-full text-left px-2.5 py-2 rounded-lg flex items-center gap-2 cursor-pointer transition-colors ${
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
              {/* End session / unpair — shown on hover for remote peers only. */}
              {c.kind === "remote" && (
                <button
                  type="button"
                  title="End session (unpair this peer)"
                  aria-label={`End session with ${c.label}`}
                  onClick={(e) => { e.stopPropagation(); setPendingRevoke(c); }}
                  className={`shrink-0 p-0.5 rounded opacity-0 group-hover:opacity-100 transition-opacity cursor-pointer ${
                    activeId === c.id ? "text-indigo-100 hover:text-white hover:bg-white/20" : "text-neutral-400 hover:text-rose-600 hover:bg-rose-50 dark:hover:bg-rose-950/30"
                  }`}
                >
                  <X className="h-3 w-3" />
                </button>
              )}
            </div>
          ))}
        </div>

        {/* Listen config + toggle + PIN */}
        <div className="p-2 border-t border-neutral-200 dark:border-[#3d3f44] space-y-1.5">
          {/* Listen interface editor — shown while not yet listening so the
              operator picks the IP/port before binding. Hidden once bound. */}
          {!listening && (
            <div className="rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-800/40 p-1.5 space-y-1">
              <div className="text-[8px] font-mono uppercase text-neutral-500 flex items-center gap-1">
                <Network className="h-2.5 w-2.5" /> Listen address
              </div>
              <div className="flex items-center gap-1">
                <input
                  value={listenIp}
                  onChange={(e) => { setListenIp(e.target.value); setPortCheck(null); }}
                  placeholder="192.168.1.42"
                  aria-label="Listen IP"
                  className="min-w-0 flex-1 px-1.5 py-1 rounded border border-neutral-300 dark:border-neutral-600 bg-white dark:bg-neutral-900 text-[10px] font-mono text-neutral-800 dark:text-neutral-200"
                />
                <span className="text-neutral-400 text-[10px] font-mono">:</span>
                <input
                  value={listenPort}
                  onChange={(e) => { setListenPort(e.target.value.replace(/[^0-9]/g, "")); setPortCheck(null); }}
                  placeholder="7420"
                  aria-label="Listen port"
                  className="w-12 px-1.5 py-1 rounded border border-neutral-300 dark:border-neutral-600 bg-white dark:bg-neutral-900 text-[10px] font-mono text-neutral-800 dark:text-neutral-200"
                />
                <button
                  type="button"
                  onClick={() => void checkPort()}
                  disabled={checkingPort || !listenIp.trim() || !listenPort.trim()}
                  title="Test port (validate without connecting)"
                  className="shrink-0 px-1.5 py-1 rounded border border-neutral-300 dark:border-neutral-600 text-neutral-600 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-700 disabled:opacity-40 cursor-pointer transition-colors"
                >
                  {checkingPort ? <Loader2 className="h-3 w-3 animate-spin" /> : <RefreshCw className="h-3 w-3" />}
                </button>
              </div>
              {portCheck && (
                <div className={`flex items-start gap-1 text-[9px] font-mono leading-tight ${
                  portCheck.ok ? "text-emerald-600 dark:text-emerald-400" : "text-red-600 dark:text-red-400"
                }`}>
                  {portCheck.ok
                    ? <Check className="h-2.5 w-2.5 mt-px shrink-0" />
                    : <AlertTriangle className="h-2.5 w-2.5 mt-px shrink-0" />}
                  <span>{portCheck.detail}</span>
                </div>
              )}
            </div>
          )}
          <button
            type="button"
            onClick={() => void toggleListen()}
            disabled={!listening && (checkingPort || !listenIp.trim() || !listenPort.trim())}
            className={`w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded text-[10px] font-mono font-bold cursor-pointer transition-colors disabled:opacity-40 ${
              listening
                ? "bg-emerald-100 dark:bg-emerald-900/40 text-emerald-700 dark:text-emerald-300 border border-emerald-300 dark:border-emerald-700"
                : "text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 border border-neutral-200 dark:border-neutral-700"
            }`}
          >
            <Radio className={`h-3 w-3 ${listening ? "animate-pulse" : ""}`} /> {listening ? "Listening for peers" : "Accept connections"}
          </button>
          <button
            type="button"
            onClick={() => setAutoRespond((v) => !v)}
            title="Auto-answer inbound questions with the local Claude (two Claudes converse)"
            className={`w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded text-[10px] font-mono font-bold cursor-pointer transition-colors ${
              autoRespond
                ? "bg-indigo-100 dark:bg-indigo-900/40 text-indigo-700 dark:text-indigo-300 border border-indigo-300 dark:border-indigo-700"
                : "text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 border border-neutral-200 dark:border-neutral-700"
            }`}
          >
            <Bot className={`h-3 w-3 ${autoRespond ? "text-indigo-500" : ""}`} /> {autoRespond ? "Auto-respond: ON" : "Auto-respond: off"}
          </button>
          {listenAddr && (
            <div className="text-center bg-emerald-50 dark:bg-emerald-950/30 border border-emerald-200 dark:border-emerald-800 rounded p-1.5">
              <div className="text-[8px] font-mono uppercase text-emerald-600 dark:text-emerald-400 flex items-center justify-center gap-1"><Network className="h-2.5 w-2.5" /> Connect to this address</div>
              <div className="text-[11px] font-mono font-bold text-emerald-700 dark:text-emerald-300">{listenAddr}</div>
              <div className="text-[8px] font-mono text-emerald-600/80 dark:text-emerald-400/80 flex items-center justify-center gap-1 mt-0.5">
                <Circle className="h-1.5 w-1.5 fill-current" /> Port open — a peer on the same network can connect
              </div>
            </div>
          )}
          {invitePin && (
            <button
              type="button"
              onClick={copyPin}
              onContextMenu={copyPin}
              title="Click to copy (or right-click)"
              className="w-full text-center bg-violet-50 dark:bg-violet-950/30 border border-violet-200 dark:border-violet-800 rounded p-1.5 cursor-pointer hover:bg-violet-100 dark:hover:bg-violet-900/40 transition-colors"
            >
              <div className="text-[8px] font-mono uppercase text-violet-500 flex items-center justify-center gap-1">
                {pinCopied ? <><Check className="h-2.5 w-2.5" /> Copied</> : <><KeyRound className="h-2.5 w-2.5" /> Pairing PIN</>}
              </div>
              <div className="text-lg font-mono font-bold tracking-widest text-violet-700 dark:text-violet-300">{invitePin}</div>
            </button>
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
            const lbl = label || addr;
            const res = await invoke<{ sas: string; peer_spki: string }>("bridge_pair_connect", { addr, pin, label: lbl });
            // Show the SAS for the human to COMPARE with the invitee's — do NOT
            // auto-confirm (auto-confirm defeats the MITM protection, PRD R3).
            setSasPrompt({ sas: res.sas, peerSpki: res.peer_spki, label: lbl, side: "dialer" });
            setAddOpen(false);
          }}
        />
      )}

      {sasPrompt && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm p-6">
          <div role="dialog" aria-label="Security Verification" className="w-[400px] max-w-full bg-white dark:bg-[#25272b] rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700 p-5 text-center space-y-3">
            <div className="flex items-center justify-center gap-2 text-sm font-display font-bold text-neutral-800 dark:text-neutral-200">
              <Shield className="h-4 w-4 text-violet-500" /> Security Verification (SAS)
            </div>
            <p className="text-[11px] font-mono text-neutral-500 dark:text-neutral-400">
              Is this code <b>the same</b> as the one shown on the {sasPrompt.side === "dialer" ? "other side (inviter)" : "connecting side"}? Confirm if identical — reject if different (possible MITM).
            </p>
            <div className="text-3xl font-mono font-bold tracking-[0.3em] text-violet-700 dark:text-violet-300 py-2 bg-violet-50 dark:bg-violet-950/30 rounded-lg">
              {sasPrompt.sas}
            </div>
            <div className="flex gap-2">
              <button type="button" onClick={() => void confirmSas(false)}
                className="flex-1 px-3 py-2 rounded-lg text-xs font-mono font-bold border border-rose-300 dark:border-rose-700 text-rose-600 dark:text-rose-400 hover:bg-rose-50 dark:hover:bg-rose-950/30 cursor-pointer transition-colors">
                Different — Reject
              </button>
              <button type="button" onClick={() => void confirmSas(true)}
                className="flex-1 px-3 py-2 rounded-lg text-xs font-mono font-bold bg-emerald-600 hover:bg-emerald-700 text-white cursor-pointer transition-colors flex items-center justify-center gap-1">
                <Check className="h-3.5 w-3.5" /> Same — Confirm
              </button>
            </div>
          </div>
        </div>
      )}

      {pendingRevoke && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm p-6" onClick={() => setPendingRevoke(null)}>
          <div role="dialog" aria-label="End session" className="w-[400px] max-w-full bg-white dark:bg-[#25272b] rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700 p-5 text-center space-y-3" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-center gap-2 text-sm font-display font-bold text-neutral-800 dark:text-neutral-200">
              <Wifi className="h-4 w-4 text-rose-500" /> End session
            </div>
            <p className="text-[11px] font-mono text-neutral-500 dark:text-neutral-400">
              End the session with <b>{pendingRevoke.label}</b> and unpair it? The peer must pair again (new PIN + SAS) to reconnect.
            </p>
            <div className="flex gap-2">
              <button type="button" onClick={() => setPendingRevoke(null)}
                className="flex-1 px-3 py-2 rounded-lg text-xs font-mono font-bold border border-neutral-300 dark:border-neutral-600 text-neutral-600 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer transition-colors">
                Cancel
              </button>
              <button type="button" onClick={() => void doRevoke(pendingRevoke)}
                className="flex-1 px-3 py-2 rounded-lg text-xs font-mono font-bold bg-rose-600 hover:bg-rose-700 text-white cursor-pointer transition-colors flex items-center justify-center gap-1">
                <X className="h-3.5 w-3.5" /> End session
              </button>
            </div>
          </div>
        </div>
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
      <div role="dialog" aria-label="New Connection" className="w-[420px] max-w-full bg-white dark:bg-[#25272b] rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700" onClick={(e) => e.stopPropagation()}>
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
