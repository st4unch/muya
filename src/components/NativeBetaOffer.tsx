// Created by Claude — Classification: INTERNAL
//
// "Try the Muya Native beta?" — offer, running-sessions warning, progress and error
// steps. Built from modalKit so it looks like every other Muya dialog. The swap itself
// runs in Rust (switchover_start); on success the app quits by itself.

import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { ModalShell, ghostBtn, helperStyle, primaryBtn, rowsBox, rowStyle } from "./modalKit";

type Step = "offer" | "warn" | "translocated" | "progress" | "error";
type Preflight = { ptyLive: number; agentRunning: number; translocated: boolean };
type Progress = { phase: "starting" | "downloading"; done: number; total: number | null };

const mb = (n: number) => (n / 1048576).toFixed(1);

export default function NativeBetaOffer({ version, notes, onClose }: { version: string; notes: string; onClose: () => void }) {
  const [step, setStep] = useState<Step>("offer");
  const [sessions, setSessions] = useState(0);
  const [progress, setProgress] = useState<Progress>({ phase: "starting", done: 0, total: null });
  const [error, setError] = useState("");

  useEffect(() => {
    const subs = [
      listen<Progress>("switchover://progress", (e) => setProgress(e.payload)),
      listen<string>("switchover://error", (e) => {
        setError(String(e.payload));
        setStep("error");
      }),
    ];
    return () => {
      for (const s of subs) void s.then((f) => f()).catch(() => {});
    };
  }, []);

  const answer = (a: "tryIt" | "notNow" | "dontAsk") => invoke("switchover_answer", { version, answer: a }).catch(() => {});

  const close = (a?: "notNow") => {
    if (step === "progress") return; // the swap is running; don't hide it
    if (a) void answer(a);
    onClose();
  };

  const start = async () => {
    setStep("progress");
    setProgress({ phase: "starting", done: 0, total: null });
    try {
      await invoke("switchover_start");
    } catch (e) {
      setError(String(e));
      setStep("error");
    }
  };

  const tryIt = async () => {
    await answer("tryIt");
    let pf: Preflight = { ptyLive: 0, agentRunning: 0, translocated: false };
    try {
      pf = await invoke<Preflight>("switchover_preflight");
    } catch {
      /* preflight unavailable: treat as nothing running */
    }
    if (pf.translocated) return setStep("translocated");
    // Only terminals living inside this app die when it quits; agents running elsewhere on the Mac are untouched.
    const n = pf.ptyLive;
    if (n > 0) {
      setSessions(n);
      return setStep("warn");
    }
    await start();
  };

  const pct = progress.total ? Math.min(100, Math.round((progress.done / progress.total) * 100)) : null;

  let body;
  let footer;
  if (step === "offer") {
    body = (
      <>
        <div style={{ fontSize: 13, lineHeight: 1.5 }}>
          Muya Native {version} is a new, native Mac version of Muya. It <b>replaces this app</b>. Your workspaces, settings, schedules and servers come with you, and the old app goes to the Trash.
        </div>
        {notes && (
          <div style={rowsBox}>
            <div style={{ ...rowStyle, flexDirection: "column", gap: 4 }}>
              <span style={{ fontSize: 13, fontWeight: 600 }}>What's new in {version}</span>
              <span style={{ ...helperStyle, whiteSpace: "pre-wrap", overflowWrap: "anywhere", maxHeight: 160, overflowY: "auto" }}>{notes}</span>
            </div>
          </div>
        )}
      </>
    );
    footer = (
      <>
        <button type="button" className="st-btn" style={ghostBtn} onClick={() => { void answer("dontAsk"); onClose(); }}>
          Don't ask again
        </button>
        <div style={{ display: "flex", gap: 8 }}>
          <button type="button" className="st-btn" style={ghostBtn} onClick={() => close("notNow")}>
            Not now
          </button>
          <button type="button" className="st-primary" style={primaryBtn} data-autofocus onClick={() => void tryIt()}>
            Try it
          </button>
        </div>
      </>
    );
  } else if (step === "warn") {
    body = (
      <div style={{ fontSize: 13, lineHeight: 1.5 }}>
        {sessions} {sessions === 1 ? "session is" : "sessions are"} running; {sessions === 1 ? "it" : "they"} will be closed when Muya switches. Claude sessions can be resumed in Muya Native.
      </div>
    );
    footer = (
      <>
        <span />
        <div style={{ display: "flex", gap: 8 }}>
          <button type="button" className="st-btn" style={ghostBtn} onClick={() => close("notNow")}>
            Not now
          </button>
          <button type="button" className="st-primary" style={primaryBtn} data-autofocus onClick={() => void start()}>
            Switch now
          </button>
        </div>
      </>
    );
  } else if (step === "translocated") {
    body = (
      <div style={{ fontSize: 13, lineHeight: 1.5 }}>
        Move Muya to your Applications folder first, then open it from there and try again. Muya can't switch while it runs from a download location.
      </div>
    );
    footer = (
      <>
        <span />
        <button type="button" className="st-btn" style={ghostBtn} data-autofocus onClick={onClose}>
          Close
        </button>
      </>
    );
  } else if (step === "progress") {
    body = (
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <div style={{ fontSize: 13 }}>{progress.phase === "starting" ? "Getting ready…" : "Downloading Muya Native…"}</div>
        <div
          role="progressbar"
          aria-label="Download progress"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={pct ?? undefined}
          style={{ height: 6, borderRadius: 3, background: "var(--bg-segment)", overflow: "hidden" }}
        >
          <div style={{ width: pct === null ? "30%" : `${pct}%`, height: "100%", background: "var(--accent)", transition: "width 160ms" }} />
        </div>
        <div style={helperStyle}>
          {progress.phase === "downloading" ? (progress.total ? `${mb(progress.done)} of ${mb(progress.total)} MB` : `${mb(progress.done)} MB`) : " "}
        </div>
        <div style={helperStyle}>Muya will close and Muya Native will open when it's ready.</div>
      </div>
    );
    footer = undefined;
  } else {
    body = (
      <>
        <div role="alert" style={{ fontSize: 13, lineHeight: 1.5, color: "var(--danger-text)", overflowWrap: "anywhere" }}>
          {error || "Something went wrong."}
        </div>
        <div style={helperStyle}>Nothing was changed. This Muya is still installed and working.</div>
      </>
    );
    footer = (
      <>
        <span />
        <button type="button" className="st-btn" style={ghostBtn} data-autofocus onClick={onClose}>
          Close
        </button>
      </>
    );
  }

  return (
    <ModalShell title="Try the Muya Native beta?" onClose={() => (step === "offer" || step === "warn" ? close("notNow") : close())} width={460} footer={footer}>
      {body}
    </ModalShell>
  );
}
