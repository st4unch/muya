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
  it("blocks with move-to-Applications instructions when translocated", async () => {
    invokeMock.mockResolvedValue({
      translocated: true,
      exe_path: "/private/var/folders/x/AppTranslocation/UUID/d/Muya.app/Contents/MacOS/muya",
      folders: [],
    });

    render(<FileAccessGate />);

    // The one instruction that actually fixes it must be on screen — this is
    // the state where no in-app button can help.
    expect(await screen.findByText(/Move Muya to your Applications folder/i)).toBeTruthy();
    expect(screen.getByText(/AppTranslocation/)).toBeTruthy();
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

  it("stays out of the way once every folder is granted", async () => {
    invokeMock.mockResolvedValue({ translocated: false, exe_path: "/Applications/Muya.app", folders: folders(true) });

    const { container } = render(<FileAccessGate />);
    await waitFor(() => expect(invokeMock).toHaveBeenCalled());
    await waitFor(() => expect(container.textContent).toBe(""));
  });
});
