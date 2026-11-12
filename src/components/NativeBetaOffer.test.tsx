import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor, act } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => invoke(...a) }));
const handlers: Record<string, (e: { payload: unknown }) => void> = {};
vi.mock("@tauri-apps/api/event", () => ({
  listen: async (name: string, cb: (e: { payload: unknown }) => void) => {
    handlers[name] = cb;
    return () => {};
  },
}));

import NativeBetaOffer from "./NativeBetaOffer";
import SettingsModal from "./SettingsModal";
import { checkNativeBetaAfterUpdate, resetNativeBetaSession } from "../lib/nativeBeta";

let preflight = { ptyLive: 0, agentRunning: 0, translocated: false };
beforeEach(() => {
  invoke.mockReset();
  preflight = { ptyLive: 0, agentRunning: 0, translocated: false };
  invoke.mockImplementation(async (cmd: string) => {
    if (cmd === "switchover_preflight") return preflight;
    if (cmd === "debug_log_get") return { enabled: false, path: "~/.claude/muya-debug.log" };
    return undefined;
  });
});

const answers = () => invoke.mock.calls.filter((c) => c[0] === "switchover_answer").map((c) => (c[1] as { answer: string }).answer);

describe("NativeBetaOffer", () => {
  it("shows the offer with version and notes; Not now / Don't ask record the answer", async () => {
    const onClose = vi.fn();
    const { unmount } = render(<NativeBetaOffer version="0.1.0-beta.2" notes="Faster terminals" onClose={onClose} />);
    expect(screen.getByText(/Muya Native 0.1.0-beta.2/)).toBeInTheDocument();
    expect(screen.getByText("Faster terminals")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Not now" }));
    expect(answers()).toEqual(["notNow"]);
    expect(onClose).toHaveBeenCalled();
    unmount();
    invoke.mockClear();
    render(<NativeBetaOffer version="1" notes="" onClose={onClose} />);
    fireEvent.click(screen.getByRole("button", { name: "Don't ask again" }));
    expect(answers()).toEqual(["dontAsk"]);
  });

  it("Try it with nothing running answers tryIt then starts and shows progress", async () => {
    render(<NativeBetaOffer version="1" notes="" onClose={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: "Try it" }));
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("switchover_start"));
    expect(answers()).toEqual(["tryIt"]);
    act(() => handlers["switchover://progress"]({ payload: { phase: "downloading", done: 5 * 1048576, total: 20 * 1048576 } }));
    expect(screen.getByText("5.0 of 20.0 MB")).toBeInTheDocument();
    expect(screen.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "25");
  });

  it("warns when sessions are running and only starts on Switch now", async () => {
    preflight = { ptyLive: 2, agentRunning: 1, translocated: false };
    render(<NativeBetaOffer version="1" notes="" onClose={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: "Try it" }));
    await screen.findByText(/3 sessions are running/);
    expect(invoke).not.toHaveBeenCalledWith("switchover_start");
    fireEvent.click(screen.getByRole("button", { name: "Switch now" }));
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("switchover_start"));
  });

  it("asks to move Muya to Applications when translocated", async () => {
    preflight = { ptyLive: 0, agentRunning: 0, translocated: true };
    render(<NativeBetaOffer version="1" notes="" onClose={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: "Try it" }));
    await screen.findByText(/Move Muya to your Applications folder/);
    expect(invoke).not.toHaveBeenCalledWith("switchover_start");
  });

  it("shows an error step from the error event and Close dismisses", async () => {
    const onClose = vi.fn();
    render(<NativeBetaOffer version="1" notes="" onClose={onClose} />);
    fireEvent.click(screen.getByRole("button", { name: "Try it" }));
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("switchover_start"));
    act(() => handlers["switchover://error"]({ payload: "checksum mismatch" }));
    expect(screen.getByRole("alert")).toHaveTextContent("checksum mismatch");
    fireEvent.click(screen.getAllByRole("button", { name: "Close" })[1]);
    expect(onClose).toHaveBeenCalled();
  });
});

describe("checkNativeBetaAfterUpdate", () => {
  beforeEach(() => resetNativeBetaSession());
  it("returns the offer once per session", async () => {
    invoke.mockResolvedValue({ status: "show", version: "2", notes: "n" });
    expect(await checkNativeBetaAfterUpdate()).toEqual({ version: "2", notes: "n" });
    expect(invoke).toHaveBeenCalledWith("switchover_check", { trigger: "afterUpdate" });
    expect(await checkNativeBetaAfterUpdate()).toBeNull();
  });
  it("swallows errors and hidden/installed", async () => {
    invoke.mockRejectedValueOnce("boom");
    expect(await checkNativeBetaAfterUpdate()).toBeNull();
    invoke.mockResolvedValueOnce({ status: "hidden" });
    expect(await checkNativeBetaAfterUpdate()).toBeNull();
    invoke.mockResolvedValueOnce({ status: "show", version: "3" });
    expect(await checkNativeBetaAfterUpdate()).not.toBeNull();
  });
});

describe("Settings > Beta", () => {
  const click = () => fireEvent.click(screen.getByRole("button", { name: "Try the Native beta…" }));
  it("opens the offer when a beta is available", async () => {
    invoke.mockImplementation(async (cmd: string) => (cmd === "switchover_check" ? { status: "show", version: "9", notes: "" } : cmd === "debug_log_get" ? { enabled: false, path: "p" } : undefined));
    render(<SettingsModal open onClose={() => {}} />);
    expect(screen.getByText("Muya Native beta")).toBeInTheDocument();
    click();
    await screen.findByText("Try the Muya Native beta?");
    expect(invoke).toHaveBeenCalledWith("switchover_check", { trigger: "settings" });
  });
  it("shows installed / none / error inline", async () => {
    let r: unknown = { status: "installed" };
    invoke.mockImplementation(async (cmd: string) => {
      if (cmd === "switchover_check") { if (r instanceof Error) throw r.message; return r; }
      if (cmd === "debug_log_get") return { enabled: false, path: "p" };
    });
    render(<SettingsModal open onClose={() => {}} />);
    click();
    await screen.findByText("Native beta is installed");
    r = { status: "hidden" };
    click();
    await screen.findByText("No beta available right now");
    r = new Error("Could not check for the Native beta: offline");
    click();
    await screen.findByText(/offline/);
  });
});
