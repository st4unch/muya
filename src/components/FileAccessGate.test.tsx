import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
import { invoke } from "@tauri-apps/api/core";
import FileAccessGate from "./FileAccessGate";

const invokeMock = invoke as unknown as ReturnType<typeof vi.fn>;

const folders = (granted: boolean) =>
  ["Documents", "Desktop", "Downloads"].map((name) => ({
    name,
    path: `/Users/someone/${name}`,
    granted,
  }));

beforeEach(() => {
  invokeMock.mockReset();
  localStorage.clear();
});

describe("FileAccessGate", () => {
  const translocated = {
    translocated: true,
    exe_path: "/private/var/folders/x/AppTranslocation/UUID/d/Muya.app/Contents/MacOS/muya",
    folders: [],
    original_path: "/Users/someone/Downloads/Muya.app",
  };

  // A translocated session works — it must never be walled off behind a modal
  // again, and /Applications must not be a requirement.
  it("does not block a translocated session and offers a restart when that fixes it", async () => {
    invokeMock.mockResolvedValue({ ...translocated, relaunch_fixes_it: true });

    render(<FileAccessGate />);

    expect(await screen.findByText(/Restart Muya once/i)).toBeTruthy();
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(document.querySelector(".fixed.inset-0")).toBeNull();
    expect(screen.queryByText(/Move Muya to your Applications folder/i)).toBeNull();
    expect(screen.getByText("/Users/someone/Downloads/Muya.app")).toBeTruthy();

    await userEvent.click(screen.getByRole("button", { name: /Restart now/i }));
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith("relaunch_in_place"));
  });

  it("asks to copy the app elsewhere only when the original can't be fixed", async () => {
    invokeMock.mockResolvedValue({ ...translocated, original_path: null, relaunch_fixes_it: false });

    render(<FileAccessGate />);

    expect(await screen.findByText(/running from a temporary copy/i)).toBeTruthy();
    expect(screen.queryByRole("button", { name: /Restart now/i })).toBeNull();
    expect(document.querySelector(".fixed.inset-0")).toBeNull();
  });

  it("shows why a restart failed instead of looking dead", async () => {
    invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "relaunch_in_place") throw "the original app is still quarantined";
      return { ...translocated, relaunch_fixes_it: true };
    });

    render(<FileAccessGate />);
    await userEvent.click(await screen.findByRole("button", { name: /Restart now/i }));

    expect(await screen.findByText(/still quarantined/)).toBeTruthy();
  });

  it("never touches a protected folder on startup", async () => {
    invokeMock.mockResolvedValue({ translocated: false, exe_path: "/Applications/Muya.app", folders: folders(false) });

    render(<FileAccessGate />);

    // The startup call must pass probe:false. Probing is what raises macOS's
    // prompt, and a prompt nobody asked for is the original bug.
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith("file_access_status", { probe: false }));
    expect(invokeMock).not.toHaveBeenCalledWith("file_access_status", { probe: true });
  });

  it("only asks macOS for permission after the user presses Grant", async () => {
    invokeMock.mockResolvedValue({ translocated: false, exe_path: "/Applications/Muya.app", folders: folders(false) });

    render(<FileAccessGate />);
    const btn = await screen.findByRole("button", { name: /Grant access/i });
    await userEvent.click(btn);

    await waitFor(() =>
      expect(invokeMock).toHaveBeenCalledWith("file_access_status", { probe: true }),
    );
  });

  it("confirms out loud when the grant worked, instead of just vanishing", async () => {
    // A button that silently removes itself reads as a button that did nothing —
    // which is exactly how the first version was reported.
    invokeMock
      .mockResolvedValueOnce({ translocated: false, exe_path: "/Applications/Muya.app", folders: folders(false) })
      .mockResolvedValueOnce({ translocated: false, exe_path: "/Applications/Muya.app", folders: folders(true) });

    render(<FileAccessGate />);
    await userEvent.click(await screen.findByRole("button", { name: /Grant access/i }));

    expect(await screen.findByText(/Muya can read your folders/i)).toBeTruthy();
  });

  it("explains that macOS will not re-ask when the folders stay blocked", async () => {
    // macOS remembers a Files-and-Folders answer and never prompts again, so
    // pressing Grant produces no dialog at all. Saying nothing makes the button
    // look dead; System Settings is the only remaining route.
    invokeMock.mockResolvedValue({
      translocated: false,
      exe_path: "/Applications/Muya.app",
      folders: folders(false),
    });

    render(<FileAccessGate />);
    await userEvent.click(await screen.findByRole("button", { name: /Grant access/i }));

    expect(await screen.findByText(/macOS will not ask again/i)).toBeTruthy();
    await userEvent.click(screen.getByRole("button", { name: /Open Settings/i }));
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith("open_privacy_settings"));
  });

  it("stays out of the way once every folder is granted", async () => {
    invokeMock.mockResolvedValue({ translocated: false, exe_path: "/Applications/Muya.app", folders: folders(true) });

    const { container } = render(<FileAccessGate />);
    await waitFor(() => expect(invokeMock).toHaveBeenCalled());
    await waitFor(() => expect(container.textContent).toBe(""));
  });
});
