import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import VaultConfigPanel from "./VaultConfigPanel";

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

const invokeMock = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

describe("VaultConfigPanel", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "vault_get_status") {
        return Promise.resolve({ configuredPath: null, resolvedPath: null, serverInstalled: true });
      }
      if (cmd === "vault_detect_candidates") {
        return Promise.resolve(["/Users/x/Documents/my-vault"]);
      }
      return Promise.resolve(undefined);
    });
  });

  it("does not fetch status until opened (closed by default)", () => {
    render(<VaultConfigPanel />);
    expect(invokeMock).not.toHaveBeenCalled();
  });

  it("fetches status + candidates when the gear icon is clicked", async () => {
    const user = userEvent.setup();
    render(<VaultConfigPanel />);
    await user.click(screen.getByTitle("Vault kaynağını ayarla"));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("vault_get_status");
      expect(invokeMock).toHaveBeenCalledWith("vault_detect_candidates");
    });
    expect(await screen.findByText("/Users/x/Documents/my-vault")).toBeInTheDocument();
  });

  it("clicking a detected candidate sets the path and restarts the MCP subprocess", async () => {
    const user = userEvent.setup();
    const onChanged = vi.fn();
    render(<VaultConfigPanel onChanged={onChanged} />);
    await user.click(screen.getByTitle("Vault kaynağını ayarla"));
    const candidate = await screen.findByText("/Users/x/Documents/my-vault");
    await user.click(candidate);

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("vault_set_path", { path: "/Users/x/Documents/my-vault" });
      expect(invokeMock).toHaveBeenCalledWith("vault_restart");
    });
    await waitFor(() => expect(onChanged).toHaveBeenCalled());
  });

  it("shows an install warning when the MCP server isn't installed", async () => {
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "vault_get_status") {
        return Promise.resolve({ configuredPath: null, resolvedPath: null, serverInstalled: false });
      }
      return Promise.resolve([]);
    });
    const user = userEvent.setup();
    render(<VaultConfigPanel />);
    await user.click(screen.getByTitle("Vault kaynağını ayarla"));
    expect(await screen.findByText(/not installed/i)).toBeInTheDocument();
  });

  it("shows an error message when vault_set_path rejects", async () => {
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "vault_get_status") {
        return Promise.resolve({ configuredPath: null, resolvedPath: null, serverInstalled: true });
      }
      if (cmd === "vault_detect_candidates") return Promise.resolve([]);
      if (cmd === "vault_set_path") return Promise.reject(new Error("not an Obsidian vault"));
      return Promise.resolve(undefined);
    });
    const user = userEvent.setup();
    render(<VaultConfigPanel />);
    await user.click(screen.getByTitle("Vault kaynağını ayarla"));
    await user.type(screen.getByPlaceholderText("/path/to/vault"), "/tmp/not-a-vault");
    await user.click(screen.getByRole("button", { name: "Set" }));
    expect(await screen.findByText(/not an Obsidian vault/i)).toBeInTheDocument();
  });
});
