// Created by Claude — Classification: INTERNAL
//
// Remote Claude bridge for agents (PRD bridge-mcp): the `bridge_*` muya-mcp tools.
// Two Claude sessions on two Macs pair over the existing mTLS + SPAKE2 bridge
// (bridge_remote.rs) and message each other. One side listens ("server"), the other
// dials ("client"). Only the client can dial, so the server's messages wait in an
// outbox that the client polls every few seconds over the same pinned mTLS channel.
//
// Inbound messages are typed into a local Claude session (operator decision), so they
// are: size- and rate-limited per peer, stripped of control/escape sequences and
// flattened to one line here, and tagged as remote + untrusted by the app.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex as StdMutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::bridge::{EnvelopeType, Kind};
use crate::bridge_remote::{self, PinnedPeer, RemoteBridgeState};

/// Largest message accepted (bytes of UTF-8).
pub const MAX_MSG_BYTES: usize = 4096;
/// Messages accepted per peer per `RATE_WINDOW`.
pub const RATE_MAX: usize = 10;
pub const RATE_WINDOW: Duration = Duration::from_secs(60);
/// Messages kept for a peer that has not polled yet.
pub const OUTBOX_CAP: usize = 20;
/// Inbound messages kept while no local session is bound to receive them.
pub const HELD_CAP: usize = 50;
/// Default data-listener port; the pairing window opens on the next port.
pub const DEFAULT_PORT: u16 = 47800;
const POLL_EVERY: Duration = Duration::from_secs(2);
const POLL_MAX_BACKOFF: Duration = Duration::from_secs(30);

#[derive(Default)]
pub struct ChatState {
    /// Peer SPKI → messages waiting for that peer to poll.
    outbox: StdMutex<HashMap<String, VecDeque<Value>>>,
    /// Peer SPKI → arrival times inside the rate window.
    rate: StdMutex<HashMap<String, VecDeque<Instant>>>,
    /// Peer SPKI → the local session that talks to it (last one to use a bridge tool for it).
    bindings: StdMutex<HashMap<String, String>>,
    /// The session that last opened a listener / invite / connection — receives
    /// messages from peers that have no binding yet.
    default_session: StdMutex<Option<String>>,
    /// Inbound messages with nowhere to go yet: (peer SPKI, message).
    held: StdMutex<VecDeque<(String, Value)>>,
    /// Peer SPKI → poll loop (client side).
    pollers: StdMutex<HashMap<String, tauri::async_runtime::JoinHandle<()>>>,
}

impl ChatState {
    pub fn drain_outbox(&self, peer: &str) -> Vec<Value> {
        self.outbox
            .lock()
            .unwrap()
            .remove(peer)
            .map(Vec::from)
            .unwrap_or_default()
    }

    fn push_outbox(&self, peer: &str, msg: Value) -> Result<usize, String> {
        let mut map = self.outbox.lock().unwrap();
        let q = map.entry(peer.to_string()).or_default();
        if q.len() >= OUTBOX_CAP {
            return Err(format!(
                "{OUTBOX_CAP} messages are already waiting for this peer — it has not picked them up \
                 (is its Muya running?)"
            ));
        }
        q.push_back(msg);
        Ok(q.len())
    }

    pub fn forget_peer(&self, peer: &str) {
        self.outbox.lock().unwrap().remove(peer);
        self.rate.lock().unwrap().remove(peer);
        self.bindings.lock().unwrap().remove(peer);
        self.held.lock().unwrap().retain(|(p, _)| p != peer);
        if let Some(h) = self.pollers.lock().unwrap().remove(peer) {
            h.abort();
        }
    }

    fn bind(&self, peer: &str, session: &str) {
        if !session.is_empty() {
            self.bindings
                .lock()
                .unwrap()
                .insert(peer.to_string(), session.to_string());
        }
    }

    fn set_default(&self, session: &str) {
        if !session.is_empty() {
            *self.default_session.lock().unwrap() = Some(session.to_string());
        }
    }

    fn rate_ok(&self, peer: &str, now: Instant) -> bool {
        rate_ok(
            self.rate
                .lock()
                .unwrap()
                .entry(peer.to_string())
                .or_default(),
            now,
        )
    }
}

/// Sliding-window limiter: true (and records `now`) when under `RATE_MAX` in `RATE_WINDOW`.
pub fn rate_ok(times: &mut VecDeque<Instant>, now: Instant) -> bool {
    while times
        .front()
        .is_some_and(|t| now.duration_since(*t) >= RATE_WINDOW)
    {
        times.pop_front();
    }
    if times.len() >= RATE_MAX {
        return false;
    }
    times.push_back(now);
    true
}

/// Make remote text safe to type into a terminal: drop ESC sequences (CSI, OSC and
/// two-byte), other C0/C1 controls and DEL; newlines become " ⏎ " so one message is
/// exactly one prompt line; tabs become spaces.
pub fn sanitize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.next() {
                // CSI: parameters/intermediates until a final byte @..~
                Some('[') => {
                    for n in chars.by_ref() {
                        if ('@'..='~').contains(&n) {
                            break;
                        }
                    }
                }
                // OSC / DCS / PM / APC: until BEL or ST (ESC \)
                Some(']' | 'P' | '^' | '_') => {
                    while let Some(n) = chars.next() {
                        if n == '\u{7}' {
                            break;
                        }
                        if n == '\u{1b}' {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                    }
                }
                _ => {}
            },
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push_str(" ⏎ ");
            }
            '\n' => out.push_str(" ⏎ "),
            '\t' => out.push(' '),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out.trim().to_string()
}

/// Reject empty or oversized message text.
pub fn check_text(text: &str) -> Result<(), String> {
    if text.trim().is_empty() {
        return Err("message text is empty".to_string());
    }
    if text.len() > MAX_MSG_BYTES {
        return Err(format!(
            "message is {} bytes — the limit is {MAX_MSG_BYTES}; split it or summarise",
            text.len()
        ));
    }
    Ok(())
}

/// Resolve the agent's peer reference: exact SPKI, SPKI prefix (≥6), exact label
/// (case-insensitive), then a unique label substring. Never guesses on a tie.
pub fn find_peer(peers: &[PinnedPeer], q: &str) -> Result<PinnedPeer, String> {
    let q = q.trim();
    if q.is_empty() {
        return Err("`peer` is required (a label or id from bridge_peers)".to_string());
    }
    let ql = q.to_lowercase();
    let pick = |m: Vec<&PinnedPeer>| -> Option<Result<PinnedPeer, String>> {
        match m.len() {
            0 => None,
            1 => Some(Ok(m[0].clone())),
            _ => Some(Err(format!(
                "'{q}' matches {} peers ({}) — pass one exact label or id",
                m.len(),
                m.iter()
                    .map(|p| p.label.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ))),
        }
    };
    if let Some(p) = peers.iter().find(|p| p.spki_hash == ql) {
        return Ok(p.clone());
    }
    if q.len() >= 6 {
        if let Some(r) = pick(
            peers
                .iter()
                .filter(|p| p.spki_hash.starts_with(&ql))
                .collect(),
        ) {
            return r;
        }
    }
    if let Some(r) = pick(
        peers
            .iter()
            .filter(|p| p.label.to_lowercase() == ql)
            .collect(),
    ) {
        return r;
    }
    if let Some(r) = pick(
        peers
            .iter()
            .filter(|p| p.label.to_lowercase().contains(&ql))
            .collect(),
    ) {
        return r;
    }
    Err(format!("no paired peer matches '{q}' — see bridge_peers"))
}

fn short(spki: &str) -> &str {
    &spki[..spki.len().min(8)]
}

async fn peers_of(state: &RemoteBridgeState) -> Result<Vec<PinnedPeer>, String> {
    let (_id, registry) = state.ensure_initialized().await?;
    let reg = registry.lock().await;
    let mut v: Vec<PinnedPeer> = reg.peers.values().cloned().collect();
    v.sort_by_key(|p| p.paired_at);
    Ok(v)
}

/// Ids and names of the Claude sessions running right now.
async fn running() -> Vec<(String, String)> {
    tokio::task::spawn_blocking(|| {
        crate::broker::running_sessions()
            .map(|s| s.into_iter().map(|s| (s.id, s.name)).collect())
            .unwrap_or_default()
    })
    .await
    .unwrap_or_default()
}

/// One inbound remote message (already mTLS-authenticated as `peer`). Returns
/// "delivered" or "held" (no local session to receive it yet), or an error the
/// sender sees (too big / too many).
pub async fn on_inbound(
    app: &AppHandle,
    peer: &str,
    payload: &Value,
) -> Result<&'static str, String> {
    let text = payload.get("text").and_then(Value::as_str).unwrap_or("");
    check_text(text)?;
    let state = app.state::<RemoteBridgeState>();
    if !state.chat.rate_ok(peer, Instant::now()) {
        return Err(format!(
            "rate limit: at most {RATE_MAX} messages per minute — wait and send fewer, longer messages"
        ));
    }
    let msg = json!({
        "text": text,
        "target_session": payload.get("target_session").cloned().unwrap_or(Value::Null),
        "from": payload.get("from").cloned().unwrap_or(Value::Null),
    });
    Ok(if deliver(app, &state, peer, &msg).await {
        "delivered"
    } else {
        let mut held = state.chat.held.lock().unwrap();
        if held.len() >= HELD_CAP {
            held.pop_front();
        }
        held.push_back((peer.to_string(), msg));
        let _ = app.emit("bridge://held", held.len());
        "held"
    })
}

/// Type one message into the session it belongs to. False when no running session
/// can take it (target unknown, no binding, bound session gone).
async fn deliver(app: &AppHandle, state: &RemoteBridgeState, peer: &str, msg: &Value) -> bool {
    let sessions = running().await;
    let alive = |id: &str| sessions.iter().any(|(s, _)| s == id);
    let bound = state.chat.bindings.lock().unwrap().get(peer).cloned();
    let fallback = state.chat.default_session.lock().unwrap().clone();
    // A remote peer may name a target session, but only one that has opted into the
    // bridge (bound to some peer, or the session that opened the listener/invite):
    // it must not be able to type into any session the operator has running.
    let opted_in: Vec<String> = state
        .chat
        .bindings
        .lock()
        .unwrap()
        .values()
        .cloned()
        .chain(fallback.clone())
        .collect();
    let target = msg
        .get("target_session")
        .and_then(Value::as_str)
        .filter(|t| !t.trim().is_empty())
        .and_then(|t| match crate::broker::resolve_target(t, &sessions) {
            crate::broker::TargetMatch::One(i) => Some(sessions[i].0.clone()),
            _ => None,
        })
        .filter(|id| opted_in.contains(id));
    let Some(session) = target
        .or(bound.filter(|s| alive(s)))
        .or(fallback.filter(|s| alive(s)))
    else {
        return false;
    };

    let label = match peers_of(state).await {
        Ok(peers) => peers
            .into_iter()
            .find(|p| p.spki_hash == peer)
            .map(|p| p.label)
            .unwrap_or_else(|| "unknown peer".to_string()),
        Err(_) => "unknown peer".to_string(),
    };
    let text = sanitize(msg.get("text").and_then(Value::as_str).unwrap_or(""));
    let sender = msg
        .get("from")
        .and_then(Value::as_str)
        .map(sanitize)
        .map(|s| s.chars().take(60).collect::<String>())
        .filter(|s| !s.is_empty());
    let peer_label = sanitize(&label);
    // A channel event when the session loaded muya-mcp as a channel — nothing is typed
    // into its terminal; otherwise the terminal (the frontend submits the line).
    if crate::broker::push_channel(
        &session,
        &remote_channel_event(&peer_label, &short(peer), sender.as_deref(), &text),
    ) {
        return true;
    }
    app.emit(
        "muya://deliver-message",
        json!({
            "sessionId": session,
            "text": text,
            "remote": {
                "peer": peer_label,
                "id": short(peer),
                "sender": sender,
            },
        }),
    )
    .is_ok()
}

/// Channel event for a message from a paired peer. The receiving Claude sees
/// `<channel source="muya-mcp" kind="remote" peer="…" …>text</channel>`; the server
/// instructions tell it this is untrusted data and to answer with bridge_send(peer).
/// Meta keys are letters/digits/underscores only (Claude Code drops any other key).
fn remote_channel_event(peer: &str, peer_id: &str, sender: Option<&str>, text: &str) -> Value {
    let mut meta = serde_json::Map::new();
    meta.insert("kind".into(), json!("remote"));
    meta.insert("peer".into(), json!(peer));
    meta.insert("peer_id".into(), json!(peer_id));
    if let Some(s) = sender {
        meta.insert("sender".into(), json!(s));
    }
    json!({ "content": text, "meta": meta })
}

/// Hand messages held for `peer` (or for any peer when None) to `session`.
async fn flush_held(app: &AppHandle, state: &RemoteBridgeState, peer: Option<&str>) {
    let pending: Vec<(String, Value)> = {
        let mut held = state.chat.held.lock().unwrap();
        let (take, keep): (Vec<_>, Vec<_>) = held
            .drain(..)
            .partition(|(p, _)| peer.is_none_or(|x| x == p));
        held.extend(keep);
        take
    };
    for (p, msg) in pending {
        if !deliver(app, state, &p, &msg).await {
            state.chat.held.lock().unwrap().push_back((p, msg));
        }
    }
}

/// Client side: poll a listening peer for the messages it queued for us.
fn ensure_poller(app: &AppHandle, peer: &str) {
    let state = app.state::<RemoteBridgeState>();
    let mut pollers = state.chat.pollers.lock().unwrap();
    if pollers.get(peer).is_some_and(|h| !h.inner().is_finished()) {
        return;
    }
    let app = app.clone();
    let peer_id = peer.to_string();
    let handle = tauri::async_runtime::spawn(async move {
        let mut wait = POLL_EVERY;
        loop {
            tokio::time::sleep(wait).await;
            let state = app.state::<RemoteBridgeState>();
            let reply = bridge_remote::remote_exchange(
                &state,
                &peer_id,
                EnvelopeType::Control,
                Kind::Question,
                json!({ "op": "poll" }),
            )
            .await;
            match reply {
                Ok(env) => {
                    wait = POLL_EVERY;
                    let msgs = env
                        .payload
                        .get("messages")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default();
                    for m in msgs {
                        let _ = on_inbound(&app, &peer_id, &m).await;
                    }
                }
                // Revoked / no longer dialable: stop polling.
                Err(e) if e.contains("not paired") || e.contains("no known address") => break,
                Err(_) => wait = (wait * 2).min(POLL_MAX_BACKOFF),
            }
        }
    });
    pollers.insert(peer.to_string(), handle);
}

/// App start: resume polling every peer we dialed (its queued messages reach us
/// without the agent having to touch a bridge tool first).
pub fn start_pollers(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let state = app.state::<RemoteBridgeState>();
        if let Ok(peers) = peers_of(&state).await {
            for p in peers.iter().filter(|p| p.last_addr.is_some()) {
                ensure_poller(&app, &p.spki_hash);
            }
        }
    });
}

fn default_addr(port: u16) -> String {
    let ip = crate::fs::local_ip().unwrap_or_else(|_| "127.0.0.1".to_string());
    format!("{ip}:{port}")
}

/// The pairing window opens one port above the data listener.
fn pairing_addr_for(data_addr: &str) -> Result<String, String> {
    let sa: std::net::SocketAddr = data_addr
        .parse()
        .map_err(|_| format!("invalid address {data_addr:?} — use ip:port"))?;
    let port = sa
        .port()
        .checked_add(1)
        .ok_or("port too high — pick one below 65535")?;
    Ok(std::net::SocketAddr::new(sa.ip(), port).to_string())
}

/// And back: the data listener of a peer whose pairing window was at `pairing_addr`.
pub fn data_addr_for(pairing_addr: &str) -> Result<String, String> {
    let sa: std::net::SocketAddr = pairing_addr.parse().map_err(|_| {
        format!("invalid address {pairing_addr:?} — use ip:port from bridge_invite")
    })?;
    let port = sa.port().checked_sub(1).ok_or("invalid pairing port")?;
    Ok(std::net::SocketAddr::new(sa.ip(), port).to_string())
}

/// Turn a transport error into something the agent can act on.
pub fn explain_send_error(label: &str, e: &str) -> String {
    let l = e.to_lowercase();
    if l.contains("handshake") || l.contains("alert") || l.contains("does not match pinned") {
        format!("'{label}' refused the secure connection — it has probably revoked this pairing; pair again ({e})")
    } else if l.contains("refused") || l.contains("timed out") || l.contains("unreachable") {
        format!(
            "could not reach '{label}' — is its Muya running and listening (bridge_listen)? ({e})"
        )
    } else {
        e.to_string()
    }
}

fn ok(text: String, data: Value) -> Value {
    json!({ "ok": true, "text": text, "data": data })
}

fn arg<'a>(args: &'a Value, k: &str) -> Option<&'a str> {
    args.get(k)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// Broker entry point for every `bridge_*` op. `caller` is the calling Claude
/// session id (from the sidecar's CLAUDE_CODE_SESSION_ID).
pub async fn handle(app: &AppHandle, op: &str, args: &Value, caller: &str) -> Value {
    match handle_inner(app, op, args, caller).await {
        Ok(v) => v,
        Err(e) => json!({ "ok": false, "error": e }),
    }
}

async fn handle_inner(
    app: &AppHandle,
    op: &str,
    args: &Value,
    caller: &str,
) -> Result<Value, String> {
    let state = app.state::<RemoteBridgeState>();
    match op {
        "bridge_listen" => {
            let enable = args.get("enable").and_then(Value::as_bool).unwrap_or(true);
            if !enable {
                bridge_remote::remote_listen_impl(&state, false, "", app).await?;
                return Ok(ok(
                    "Stopped listening for paired peers.".into(),
                    json!({ "listening": null }),
                ));
            }
            let addr = arg(args, "addr")
                .map(str::to_string)
                .unwrap_or_else(|| default_addr(DEFAULT_PORT));
            bridge_remote::remote_listen_impl(&state, true, &addr, app).await?;
            state.chat.set_default(caller);
            flush_held(app, &state, None).await;
            let addr = state.listen_addr.lock().await.clone().unwrap_or(addr);
            Ok(ok(
                format!("Listening for paired peers on {addr} (mTLS, paired peers only). Messages from them are typed into this session."),
                json!({ "listening": addr }),
            ))
        }
        "bridge_invite" => {
            let data_addr = match state.listen_addr.lock().await.clone() {
                Some(a) => a,
                None => arg(args, "addr")
                    .map(str::to_string)
                    .unwrap_or_else(|| default_addr(DEFAULT_PORT)),
            };
            let pairing_addr = pairing_addr_for(&data_addr)?;
            // The data listener must be up so the new peer can send right after pairing.
            bridge_remote::remote_listen_impl(&state, true, &data_addr, app).await?;
            // A fresh window: close any previous one first.
            if let Some(h) = state.pairing_task.lock().await.take() {
                h.abort();
            }
            state.pairing_listener.lock().await.take();
            bridge_remote::pair_start_listener_impl(
                state.inner(),
                pairing_addr.clone(),
                app.clone(),
            )
            .await?;
            let inv = bridge_remote::pair_invite_impl(&state).await?;
            let pin = inv
                .get("pin")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            state.chat.set_default(caller);
            Ok(ok(
                format!(
                    "Pairing window open for 5 minutes, one attempt. Tell the operator to give the other \
                     machine's Claude this address and PIN: address {pairing_addr}, PIN {pin}. It calls \
                     bridge_connect(addr: \"{pairing_addr}\", pin, label). Then call bridge_peers here: it shows \
                     this machine's 6-character code. Ask the operator for the code the OTHER machine shows and \
                     call bridge_confirm(sas: <that code>) — never confirm without the code from the other side."
                ),
                json!({ "address": pairing_addr, "pin": pin, "expires_in_s": 300, "listening": data_addr }),
            ))
        }
        "bridge_connect" => {
            let addr = arg(args, "addr")
                .ok_or("`addr` is required (ip:port from the other side's bridge_invite)")?;
            let pin = arg(args, "pin").ok_or("`pin` is required")?;
            let label = arg(args, "label").unwrap_or("peer").to_string();
            let data_addr = data_addr_for(addr)?;
            let r =
                bridge_remote::pair_connect_impl(&state, addr.to_string(), pin.to_string(), label)
                    .await?;
            // Store the address we will dial for data, not the one-shot pairing window.
            if let Some(p) = state
                .active_pin
                .lock()
                .await
                .as_mut()
                .and_then(|a| a.pending_sas.as_mut())
            {
                p.peer_addr = data_addr;
            }
            state.chat.set_default(caller);
            let sas = r
                .get("sas")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            Ok(ok(
                format!(
                    "Connected. This machine's code is {sas}. Show it to the operator and ask for the code the \
                     OTHER machine shows; call bridge_confirm(sas: <that code>). Different codes mean a wrong \
                     PIN or someone else on the line — then call bridge_confirm(accept: false)."
                ),
                json!({ "sas": sas }),
            ))
        }
        "bridge_confirm" => {
            let accept = args.get("accept").and_then(Value::as_bool).unwrap_or(true);
            let theirs = arg(args, "sas");
            if accept && theirs.is_none() {
                return Err("`sas` is required: the 6-character code the OTHER machine shows (ask the operator)".into());
            }
            let label = arg(args, "label").map(str::to_string);
            let (peer, we_dialed) =
                bridge_remote::pair_confirm_impl(&state, accept, theirs, label).await?;
            state.chat.bind(&peer.spki_hash, caller);
            if we_dialed {
                ensure_poller(app, &peer.spki_hash);
            }
            flush_held(app, &state, Some(&peer.spki_hash)).await;
            Ok(ok(
                format!(
                    "Paired with '{}'. Talk to it with bridge_send(peer: \"{}\", text). Its messages are typed \
                     into this session, tagged as remote.",
                    peer.label, peer.label
                ),
                json!({ "peer": { "label": peer.label, "id": short(&peer.spki_hash) } }),
            ))
        }
        "bridge_peers" => {
            let peers = peers_of(&state).await?;
            for p in peers.iter().filter(|p| p.last_addr.is_some()) {
                ensure_poller(app, &p.spki_hash);
            }
            let bindings = state.chat.bindings.lock().unwrap().clone();
            let sessions = running().await;
            let name_of = |id: &str| {
                sessions
                    .iter()
                    .find(|(s, _)| s == id)
                    .map(|(_, n)| n.clone())
            };
            let list: Vec<Value> = peers
                .iter()
                .map(|p| {
                    json!({
                        "label": p.label,
                        "id": short(&p.spki_hash),
                        "role": if p.last_addr.is_some() { "server (we dial it)" } else { "client (it polls us)" },
                        "address": p.last_addr,
                        "session": bindings.get(&p.spki_hash).and_then(|s| name_of(s)),
                        "waiting_for_it": state.chat.outbox.lock().unwrap().get(&p.spki_hash).map_or(0, |q| q.len()),
                    })
                })
                .collect();
            let pending = state
                .active_pin
                .lock()
                .await
                .as_ref()
                .and_then(|a| a.pending_sas.as_ref())
                .map(|p| json!({ "our_code": p.sas, "peer_address": p.peer_addr }));
            let listening = state.listen_addr.lock().await.clone();
            let held = state.chat.held.lock().unwrap().len();
            let mut text = format!(
                "{} paired peer(s){}.",
                list.len(),
                listening
                    .as_ref()
                    .map(|a| format!(", listening on {a}"))
                    .unwrap_or_default()
            );
            if let Some(p) = &pending {
                text.push_str(&format!(
                    " A pairing is waiting: this machine's code is {}. Ask the operator for the other machine's \
                     code and call bridge_confirm(sas: <that code>).",
                    p["our_code"].as_str().unwrap_or("")
                ));
            }
            if held > 0 {
                text.push_str(&format!(
                    " {held} message(s) held — none of the bound sessions is running."
                ));
            }
            Ok(ok(
                text,
                json!({ "peers": list, "pending": pending, "listening": listening, "held": held }),
            ))
        }
        "bridge_revoke" => {
            let peers = peers_of(&state).await?;
            let p = find_peer(&peers, arg(args, "peer").unwrap_or(""))?;
            bridge_remote::revoke_impl(&state, &p.spki_hash).await?;
            Ok(ok(
                format!(
                    "Revoked '{}': it can no longer connect or receive messages.",
                    p.label
                ),
                json!({ "revoked": p.label }),
            ))
        }
        "bridge_send" => {
            let text = args.get("text").and_then(Value::as_str).unwrap_or("");
            check_text(text)?;
            let peers = peers_of(&state).await?;
            let p = find_peer(&peers, arg(args, "peer").unwrap_or(""))?;
            state.chat.bind(&p.spki_hash, caller);
            flush_held(app, &state, Some(&p.spki_hash)).await;
            let sessions = running().await;
            let from = sessions
                .iter()
                .find(|(id, _)| id == caller)
                .map(|(_, n)| n.clone());
            let payload = json!({
                "text": text,
                "target_session": arg(args, "target_session"),
                "from": from,
            });
            if p.last_addr.is_none() {
                let n = state.chat.push_outbox(&p.spki_hash, payload)?;
                return Ok(ok(
                    format!(
                        "Queued for '{}' ({n} waiting) — it picks messages up within a few seconds while its Muya runs.",
                        p.label
                    ),
                    json!({ "status": "queued", "waiting": n }),
                ));
            }
            ensure_poller(app, &p.spki_hash);
            let env = bridge_remote::remote_exchange(
                &state,
                &p.spki_hash,
                EnvelopeType::Request,
                Kind::Question,
                payload,
            )
            .await
            .map_err(|e| explain_send_error(&p.label, &e))?;
            if env.envelope_type == EnvelopeType::Error {
                return Err(format!(
                    "'{}' refused the message: {}",
                    p.label,
                    env.payload
                        .get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown error")
                ));
            }
            let status = env
                .payload
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("delivered")
                .to_string();
            let text = if status == "held" {
                format!("Sent to '{}', but no session there is bound to receive it yet — it is held until one uses a bridge tool.", p.label)
            } else {
                format!("Delivered to '{}'.", p.label)
            };
            Ok(ok(text, json!({ "status": status })))
        }
        _ => Err(format!("unknown bridge op '{op}'")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_channel_event_tags_the_peer_with_valid_meta_keys() {
        let ev = remote_channel_event("office-mac", "a1b2c3d4", Some("api work"), "build is green");
        assert_eq!(ev["content"], "build is green");
        assert_eq!(ev["meta"]["kind"], "remote");
        assert_eq!(ev["meta"]["peer"], "office-mac");
        assert_eq!(ev["meta"]["peer_id"], "a1b2c3d4");
        assert_eq!(ev["meta"]["sender"], "api work");
        for k in ev["meta"].as_object().unwrap().keys() {
            assert!(
                k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
                "{k}"
            );
        }
        assert!(remote_channel_event("p", "1", None, "x")["meta"]
            .get("sender")
            .is_none());
    }

    fn peer(spki: &str, label: &str) -> PinnedPeer {
        PinnedPeer {
            schema_v: 1,
            spki_hash: spki.into(),
            label: label.into(),
            last_addr: None,
            paired_at: 0,
            capability: "research".into(),
        }
    }

    #[test]
    fn sanitize_strips_escapes_and_flattens_newlines() {
        let s = sanitize("hi\x1b[31mred\x1b[0m\nrm -rf /\r\nok\x07\x1b]0;title\x07end\tx");
        assert_eq!(s, "hired ⏎ rm -rf / ⏎ okend x");
        assert!(!s.contains('\u{1b}') && !s.contains('\n') && !s.contains('\r'));
    }

    #[test]
    fn sanitize_drops_c1_controls_and_lone_escape() {
        assert_eq!(sanitize("a\u{9b}b\u{1b}c\u{7f}d"), "abd");
    }

    #[test]
    fn check_text_limits() {
        assert!(check_text("  ").is_err());
        assert!(check_text(&"x".repeat(MAX_MSG_BYTES)).is_ok());
        assert!(check_text(&"x".repeat(MAX_MSG_BYTES + 1)).is_err());
    }

    #[test]
    fn rate_limit_allows_ten_per_minute() {
        let mut q = VecDeque::new();
        let t0 = Instant::now();
        for _ in 0..RATE_MAX {
            assert!(rate_ok(&mut q, t0));
        }
        assert!(!rate_ok(&mut q, t0 + Duration::from_secs(30)));
        assert!(rate_ok(&mut q, t0 + RATE_WINDOW));
    }

    #[test]
    fn find_peer_by_id_label_and_refuses_ties() {
        let ps = vec![
            peer("abcdef0123", "Office Mac"),
            peer("abcd999999", "Home Mac"),
        ];
        assert_eq!(find_peer(&ps, "abcdef0123").unwrap().label, "Office Mac");
        assert_eq!(find_peer(&ps, "abcdef").unwrap().label, "Office Mac");
        assert_eq!(find_peer(&ps, "home mac").unwrap().label, "Home Mac");
        assert!(find_peer(&ps, "mac").unwrap_err().contains("matches 2"));
        assert!(find_peer(&ps, "nope").is_err());
        assert!(find_peer(&ps, "").is_err());
    }

    #[test]
    fn pairing_and_data_ports_are_adjacent() {
        assert_eq!(
            pairing_addr_for("192.168.1.5:47800").unwrap(),
            "192.168.1.5:47801"
        );
        assert_eq!(
            data_addr_for("192.168.1.5:47801").unwrap(),
            "192.168.1.5:47800"
        );
        assert!(pairing_addr_for("nonsense").is_err());
    }

    #[test]
    fn sas_compare_ignores_case_and_spacing() {
        assert!(bridge_remote::sas_matches("A1B2C3", "a1b 2c3"));
        assert!(!bridge_remote::sas_matches("A1B2C3", "A1B2C4"));
        assert!(!bridge_remote::sas_matches("", ""));
    }

    #[test]
    fn send_errors_are_explained() {
        assert!(explain_send_error(
            "a",
            "read frame len: received fatal alert: HandshakeFailure"
        )
        .contains("revoked"));
        assert!(explain_send_error(
            "a",
            "connect to peer x at y: Connection refused (os error 61)"
        )
        .contains("bridge_listen"));
        assert_eq!(explain_send_error("a", "other"), "other");
    }

    #[test]
    fn outbox_is_capped_and_drains_once() {
        let c = ChatState::default();
        for _ in 0..OUTBOX_CAP {
            c.push_outbox("p", json!({"text": "x"})).unwrap();
        }
        assert!(c.push_outbox("p", json!({"text": "x"})).is_err());
        assert_eq!(c.drain_outbox("p").len(), OUTBOX_CAP);
        assert!(c.drain_outbox("p").is_empty());
    }
}
