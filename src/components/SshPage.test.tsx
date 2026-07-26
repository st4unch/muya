import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { mockInvoke, resetMockBackend } from "../dev/mockBackend";
import SshPage from "./SshPage";

// Route the component's invoke() to the same in-memory backend the browser
// dev-shim uses, so these tests exercise the real UI flows against faithful
// command behaviour (dedup, lock states).
vi.mock("@tauri-apps/api/core", () => ({
  invoke: (cmd: string, payload?: Record<string, unknown>) => mockInvoke(cmd, payload ?? {}),
}));

beforeEach(() => resetMockBackend());

describe("SshPage — Servers", () => {
  it("starts empty and adds a server", async () => {
    const user = userEvent.setup();
    render(<SshPage />);
    await screen.findByText(/No servers yet/);

    await user.click(screen.getByText("Add server"));
    await user.type(screen.getByLabelText("Username"), "oracle");
    await user.type(screen.getByLabelText("Host / address"), "10.0.0.5");
    await user.click(screen.getByText("Save"));

    expect(await screen.findByText(/oracle@10\.0\.0\.5:22/)).toBeTruthy();
  });

  it("rejects a duplicate (host,port,user) and surfaces the error", async () => {
    const user = userEvent.setup();
    render(<SshPage />);
    await screen.findByText(/No servers yet/);

    const addOnce = async () => {
      await user.click(screen.getByText("Add server"));
      await user.type(screen.getByLabelText("Username"), "oracle");
      await user.type(screen.getByLabelText("Host / address"), "10.0.0.5");
      await user.click(screen.getByText("Save"));
    };
    await addOnce();
    await screen.findByText(/oracle@10\.0\.0\.5:22/);
    await addOnce();

    expect(await screen.findByText(/duplicate/i)).toBeTruthy();
  });
});

describe("SshPage — credential reuse", () => {
  it("a stored credential can be picked in the CyberArk form", async () => {
    const user = userEvent.setup();
    render(<SshPage />);

    // create store + add a credential
    await user.click(screen.getByText("Password Store"));
    await user.type(screen.getByPlaceholderText("Master password"), "hunter2");
    await user.click(screen.getByText("Create"));
    await screen.findByText(/Unlocked ·/);
    await user.click(screen.getByText("Add credential"));
    await user.type(screen.getByPlaceholderText("Label"), "prod-db");
    await user.type(screen.getByPlaceholderText("Username"), "oracle");
    await user.type(screen.getByPlaceholderText("Password"), "s3cret");
    await user.click(screen.getByText("Save"));
    await screen.findByText(/prod-db/);

    // CyberArk tab → picker lists the stored credential (reuse)
    await user.click(screen.getByText("CyberArk"));
    expect(await screen.findByText(/From store: prod-db/)).toBeTruthy();
  });
});

describe("SshPage — credential description + token kind (AC16)", () => {
  it("adds a token credential with a description and shows it", async () => {
    const user = userEvent.setup();
    render(<SshPage />);

    await user.click(screen.getByText("Password Store"));
    await user.type(screen.getByPlaceholderText("Master password"), "hunter2");
    await user.click(screen.getByText("Create"));
    await screen.findByText(/Unlocked ·/);

    await user.click(screen.getByText("Add credential"));
    await user.type(screen.getByPlaceholderText("Label"), "prod-aws");
    await user.type(screen.getByPlaceholderText("Username"), "deploy");
    // The token option exists in the secretKind select.
    await user.selectOptions(screen.getByRole("combobox"), "token");
    await user.type(screen.getByPlaceholderText(/Token \/ API key/), "ghp_secret");
    await user.type(
      screen.getByPlaceholderText(/Description/),
      "prod deploy token",
    );
    await user.click(screen.getByText("Save"));

    // The credential renders with its description + token kind label.
    expect(await screen.findByText(/prod deploy token/)).toBeTruthy();
    expect(await screen.findByText(/deploy · token/)).toBeTruthy();
  });
});

describe("SshPage — API key kind (AC19)", () => {
  it("adds an api_key credential and shows the 'API key' label", async () => {
    const user = userEvent.setup();
    render(<SshPage />);

    await user.click(screen.getByText("Password Store"));
    await user.type(screen.getByPlaceholderText("Master password"), "hunter2");
    await user.click(screen.getByText("Create"));
    await screen.findByText(/Unlocked ·/);

    await user.click(screen.getByText("Add credential"));
    await user.type(screen.getByPlaceholderText("Label"), "openai");
    await user.type(screen.getByPlaceholderText("Username"), "svc");
    // The API key option exists in the secretKind select.
    await user.selectOptions(screen.getByRole("combobox"), "api_key");
    await user.type(screen.getByPlaceholderText(/API key value/), "sk-test-123");
    await user.click(screen.getByText("Save"));

    // The credential renders with the "API key" kind label.
    expect(await screen.findByText(/svc · API key/)).toBeTruthy();
  });
});

describe("SshPage — Password Store", () => {
  it("creates the store, locks it, rejects a wrong master, then unlocks", async () => {
    const user = userEvent.setup();
    render(<SshPage />);

    await user.click(screen.getByText("Password Store"));
    await screen.findByText(/Create password store/);

    // Create
    await user.type(screen.getByPlaceholderText("Master password"), "hunter2");
    await user.click(screen.getByText("Create"));
    await screen.findByText(/Unlocked ·/);

    // Lock
    await user.click(screen.getByText(/Lock/));
    await screen.findByText(/Store locked/);

    // Wrong master → error surfaces, still locked
    await user.type(screen.getByPlaceholderText("Master password"), "nope");
    await user.click(screen.getByText(/^Unlock$/));
    await waitFor(() => expect(screen.getByText(/decryption failed/i)).toBeTruthy());

    // Right master → unlocked
    const input = screen.getByPlaceholderText("Master password");
    await user.clear(input);
    await user.type(input, "hunter2");
    await user.click(screen.getByText(/^Unlock$/));
    expect(await screen.findByText(/Unlocked ·/)).toBeTruthy();
  });
});
