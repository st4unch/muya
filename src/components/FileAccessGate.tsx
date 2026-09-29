import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { FolderLock, ExternalLink, AlertTriangle, Check } from "lucide-react";

// Why this component exists.
//
// Muya reads the user's project folders, and those almost always live in
// ~/Documents, ~/Desktop or ~/Downloads — the three folders macOS gates behind
// a privacy prompt. Two things went wrong for people installing it fresh:
//
// 1. The prompt appeared on its own, with no explanation of what Muya wanted or
//    why. An unexplained prompt gets dismissed, and until it is ANSWERED macOS
//    keeps asking. Now nothing touches those folders until the user presses a
//    button that says what it is for.
// 2. If the app was run straight out of the downloaded zip, macOS translocated
//    it — see `app_location.rs`. Every grant was recorded against a random path
//    that never existed again. Muya now clears the quarantine flag from the
//    ORIGINAL bundle at startup, so one relaunch runs it in place wherever the
//    user keeps it — /Applications is not required. This used to be a blocking
//    "move it to Applications" wall; it is now a notice with a Restart button,
//    because the session itself works (the MCP helper no longer lives inside the
//    translocated copy). Only when the original can't be fixed (a read-only disk
//    image) do we fall back to asking the user to copy the app somewhere.

interface FolderAccess {
  name: string;
  path: string;
  granted: boolean;
}

interface FileAccessStatus {
  translocated: boolean;
  exe_path: string;
  folders: FolderAccess[];
  /** Translocated only: where the user actually has the app. */
  original_path?: string | null;
  /** Translocated only: relaunching the original runs it in place. */
  relaunch_fixes_it?: boolean;
}

const DISMISS_KEY = "muya.fileAccessGate.dismissed";

function readDismissed(): boolean {
  try {
    return localStorage.getItem(DISMISS_KEY) === "1";
  } catch {
    return false;
  }
}

export default function FileAccessGate() {
  const [status, setStatus] = useState<FileAccessStatus | null>(null);
  const [checking, setChecking] = useState(false);
  const [probed, setProbed] = useState(false);
  const [dismissed, setDismissed] = useState(readDismissed);

  useEffect(() => {
    // probe:false — this runs at startup, so it must not touch a protected
    // folder. It only reports whether the app is translocated.
    invoke<FileAccessStatus>("file_access_status", { probe: false })
      .then(setStatus)
      .catch(() => setStatus(null));
  }, []);

  const grant = async () => {
    setChecking(true);
    try {
      // probe:true is what raises macOS's prompts — deliberately, now that the
      // user has pressed a button explaining why.
      setStatus(await invoke<FileAccessStatus>("file_access_status", { probe: true }));
      setProbed(true);
    } catch {
      /* leave the previous status in place */
    } finally {
      setChecking(false);
    }
  };

  const openSettings = () => {
    invoke("open_privacy_settings").catch(() => {});
  };

  const dismiss = () => {
    try {
      localStorage.setItem(DISMISS_KEY, "1");
    } catch {
      /* private window — dismissing for this session is enough */
    }
    setDismissed(true);
  };

  if (!status) return null;

  // Translocated: this session works, but permissions won't stick and the app
  // can't update itself until it runs from the real bundle. Say so without
  // blocking anything.
  if (status.translocated) {
    return (
      <TranslocationNotice
        status={status}
        onRelaunch={() => invoke("relaunch_in_place")}
      />
    );
  }

  const denied = status.folders.filter((f) => !f.granted);
  if (dismissed) return null;

  // Everything the probe asked for came back readable. Say so rather than just
  // vanishing: a button that silently removes itself reads as a button that did
  // nothing, which is exactly how the first version was reported.
  if (probed && denied.length === 0) {
    return (
      <div className="fixed bottom-4 right-4 z-50 w-[26rem] rounded-xl border border-emerald-300 dark:border-emerald-700 bg-white dark:bg-neutral-900 shadow-2xl p-4">
        <div className="flex items-center gap-2 mb-1">
          <Check className="w-4 h-4 text-emerald-500" />
          <h3 className="text-sm font-semibold">Muya can read your folders</h3>
        </div>
        <p className="text-xs text-neutral-600 dark:text-neutral-300 mb-3">
          Documents, Desktop and Downloads are all readable. You will not be
          asked again.
        </p>
        <button
          onClick={() => setDismissed(true)}
          className="px-3 py-1.5 text-xs rounded-md bg-neutral-900 text-white dark:bg-white dark:text-neutral-900"
        >
          Done
        </button>
      </div>
    );
  }

  if (denied.length === 0) return null;

  // Probed, and macOS still says no. It did NOT show a dialog and it never
  // will: a Files-and-Folders decision is remembered the first time it is
  // answered, and only System Settings can change it afterwards. Without saying
  // this, pressing Grant looks like pressing a dead button.
  if (probed) {
    return (
      <div className="fixed bottom-4 right-4 z-50 w-[26rem] rounded-xl border border-amber-300 dark:border-amber-700 bg-white dark:bg-neutral-900 shadow-2xl p-4">
        <div className="flex items-center gap-2 mb-1">
          <AlertTriangle className="w-4 h-4 text-amber-500" />
          <h3 className="text-sm font-semibold">macOS will not ask again</h3>
        </div>
        <p className="text-xs text-neutral-600 dark:text-neutral-300 mb-2">
          Access to {denied.map((f) => f.name).join(", ")} was refused earlier,
          and macOS only asks once. It can be changed in System Settings →
          Privacy &amp; Security → Files and Folders, or by turning on Full Disk
          Access for Muya.
        </p>
        <div className="flex items-center gap-2">
          <button
            onClick={openSettings}
            className="px-3 py-1.5 text-xs rounded-md bg-neutral-900 text-white dark:bg-white dark:text-neutral-900 flex items-center gap-1"
          >
            Open Settings <ExternalLink className="w-3 h-3" />
          </button>
          <button
            onClick={grant}
            disabled={checking}
            className="px-3 py-1.5 text-xs rounded-md border border-neutral-300 dark:border-neutral-600 disabled:opacity-50"
          >
            {checking ? "Checking…" : "Check again"}
          </button>
          <button onClick={dismiss} className="ml-auto px-2 py-1.5 text-xs text-neutral-500">
            Not now
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed bottom-4 right-4 z-50 w-[26rem] rounded-xl border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 shadow-2xl p-4">
      <div className="flex items-center gap-2 mb-2">
        <FolderLock className="w-4 h-4 text-neutral-500" />
        <h3 className="text-sm font-semibold">Let Muya read your project folders</h3>
      </div>
      <p className="text-xs text-neutral-600 dark:text-neutral-300 mb-3">
        Your projects usually live in Documents, Desktop or Downloads. macOS
        protects those, so Muya needs your permission once. It never reads them
        until you allow it here.
      </p>
      <div className="flex items-center gap-2">
        <button
          onClick={grant}
          disabled={checking}
          className="px-3 py-1.5 text-xs rounded-md bg-neutral-900 text-white dark:bg-white dark:text-neutral-900 disabled:opacity-50"
        >
          {checking ? "Asking macOS…" : "Grant access"}
        </button>
        <button
          onClick={openSettings}
          className="px-3 py-1.5 text-xs rounded-md border border-neutral-300 dark:border-neutral-600 flex items-center gap-1"
        >
          Open Settings <ExternalLink className="w-3 h-3" />
        </button>
        <button onClick={dismiss} className="ml-auto px-2 py-1.5 text-xs text-neutral-500">
          Not now
        </button>
      </div>
    </div>
  );
}

function TranslocationNotice({
  status,
  onRelaunch,
}: {
  status: FileAccessStatus;
  onRelaunch: () => Promise<unknown>;
}) {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const relaunch = async () => {
    setBusy(true);
    setError(null);
    try {
      await onRelaunch();
    } catch (e) {
      setError(String(e));
      setBusy(false);
    }
  };
  return (
    <div
      role="status"
      className="fixed bottom-4 right-4 z-50 w-[28rem] rounded-xl border border-amber-300 dark:border-amber-700 bg-white dark:bg-neutral-900 shadow-2xl p-4"
    >
      <div className="flex items-center gap-2 mb-1">
        <AlertTriangle className="w-4 h-4 text-amber-500" />
        <h3 className="text-sm font-semibold">
          {status.relaunch_fixes_it ? "Restart Muya once" : "Muya is running from a temporary copy"}
        </h3>
      </div>
      {status.relaunch_fixes_it ? (
        <p className="text-xs text-neutral-600 dark:text-neutral-300 mb-3">
          macOS started this session from a temporary copy of the downloaded app,
          so permissions you grant now won&apos;t be remembered and updates can&apos;t
          install. Muya has already fixed that for next time — restart once and it
          runs from where you keep it. You don&apos;t need to move it.
        </p>
      ) : (
        <p className="text-xs text-neutral-600 dark:text-neutral-300 mb-3">
          macOS started this session from a temporary copy, and Muya couldn&apos;t fix
          the original (for example, it&apos;s inside a disk image). Copy{" "}
          <span className="font-medium">Muya.app</span> to any folder on your Mac
          — Applications is fine — and open it from there.
        </p>
      )}
      {status.original_path && (
        <p className="text-[11px] text-neutral-400 break-all mb-3">{status.original_path}</p>
      )}
      {error && <p className="text-[11px] text-rose-500 mb-2 break-all">{error}</p>}
      {status.relaunch_fixes_it && (
        <button
          onClick={() => void relaunch()}
          disabled={busy}
          className="px-3 py-1.5 text-xs rounded-md bg-neutral-900 text-white dark:bg-white dark:text-neutral-900 disabled:opacity-50"
        >
          {busy ? "Restarting…" : "Restart now"}
        </button>
      )}
    </div>
  );
}
