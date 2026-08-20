import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { mockInvoke, resetMockBackend } from "../dev/mockBackend";
import SshPage from "./SshPage";

// Route the component's invoke() to the same in-memory backend the browser
// dev-shim uses, so these tests exercise the real UI flows against faithful
// command behaviour (dedup, lock states).
vi.mock("@tauri-apps/api/core", () => ({
  invoke: (cmd: string, payload?: Record<string, unknown>) => mockInvoke(cmd, payload ?? {}),
}));
// listen() reaches into window.__TAURI_INTERNALS__ directly (not through the
// invoke() mock above), which jsdom doesn't have — StoreTab's "muya://vault-locked"
// subscription would otherwise throw an unhandled rejection on every render.
vi.mock("@tauri-apps/api/event", () => ({
  listen: () => Promise.resolve(() => {}),
}));

beforeEach(() => {
  resetMockBackend();
  localStorage.clear(); // group collapse state persists there — start each case expanded
});

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

describe("SshPage — agent-added badge", () => {
  it("shows an 'agent-added' badge for servers registered by an agent", async () => {
    // Seed a server flagged agentAdded (as the broker's ssh_add_server would).
    await mockInvoke("ssh_upsert_server", {
      server: {
        id: "",
        label: "agent-box",
        host: "10.0.0.9",
        port: 22,
        username: "deploy",
        connectionType: "direct",
        credentialSource: { kind: "prompt" },
        agentAccess: true,
        agentAdded: true,
        tags: [],
      },
    });
    render(<SshPage />);
    // The badge renders next to the agent-added server.
    expect(await screen.findByText("agent-added")).toBeTruthy();
    expect(await screen.findByText(/deploy@10\.0\.0\.9:22/)).toBeTruthy();
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
    // The token option exists in the secretKind select (the form's Group input
    // is a datalist combobox too, so target the select by its label).
    await user.selectOptions(screen.getByLabelText("Secret kind"), "token");
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
    await user.selectOptions(screen.getByLabelText("Secret kind"), "api_key");
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

describe("SshPage — group cards + in-place editing", () => {
  const unlock = async (user: ReturnType<typeof userEvent.setup>) => {
    await user.click(screen.getByText("Password Store"));
    await user.type(screen.getByPlaceholderText("Master password"), "hunter2");
    await user.click(screen.getByText("Create"));
    await screen.findByText(/Unlocked ·/);
  };

  it("enables Touch ID unlock, then unlocks with it after locking", async () => {
    const user = userEvent.setup();
    render(<SshPage />);
    await unlock(user);

    // Not offered until explicitly enabled.
    expect(screen.queryByText("Unlock with Touch ID")).toBeNull();
    await user.click(screen.getByText("Enable Touch ID"));
    await screen.findByText("Disable Touch ID");

    await user.click(screen.getByText("Lock"));
    await screen.findByText("Store locked");

    // The Touch ID button appears once locked, and unlocks without the password field.
    await user.click(screen.getByText("Unlock with Touch ID"));
    expect(await screen.findByText(/Unlocked ·/)).toBeTruthy();
  });

  it("files a credential under its group and collapses the card", async () => {
    const user = userEvent.setup();
    render(<SshPage />);
    await unlock(user);

    await user.click(screen.getByText("Add credential"));
    await user.type(screen.getByPlaceholderText("Label"), "prod-db");
    await user.type(screen.getByPlaceholderText("Username"), "oracle");
    await user.type(screen.getByPlaceholderText("Password"), "s3cret");
    await user.type(screen.getByPlaceholderText(/^Group/), "prod");
    await user.click(screen.getByText("Save"));

    // One card per group, with the item count in the header.
    const header = await screen.findByRole("button", { name: /prod\s*\(1\)/ });
    expect(screen.getByText("prod-db")).toBeTruthy();

    // Collapsing hides the group's items and persists the choice.
    await user.click(header);
    await waitFor(() => expect(screen.queryByText("prod-db")).toBeNull());
    expect(JSON.parse(localStorage.getItem("muya.vault.collapsed") ?? "[]")).toEqual(["prod"]);

    await user.click(header);
    expect(await screen.findByText("prod-db")).toBeTruthy();
  });

  it("search filters credentials across groups and stays expanded during a search", async () => {
    const user = userEvent.setup();
    render(<SshPage />);
    await unlock(user);

    const add = async (label: string, group: string) => {
      await user.click(screen.getByText("Add credential"));
      await user.type(screen.getByPlaceholderText("Label"), label);
      await user.type(screen.getByPlaceholderText("Password"), "s3cret");
      await user.type(screen.getByPlaceholderText(/^Group/), group);
      await user.click(screen.getByText("Save"));
      await screen.findByText(label);
    };
    await add("prod-db", "prod");
    await add("staging-db", "staging");

    // Collapse "staging" — a later search must reveal it anyway (a search result
    // is never hidden by a stale collapse choice).
    await user.click(screen.getByRole("button", { name: /staging\s*\(1\)/ }));
    await waitFor(() => expect(screen.queryByText("staging-db")).toBeNull());

    await user.type(screen.getByPlaceholderText(/Search credentials/), "staging");
    expect(await screen.findByText("staging-db")).toBeTruthy();
    expect(screen.queryByText("prod-db")).toBeNull();

    await user.clear(screen.getByPlaceholderText(/Search credentials/));
    await user.type(screen.getByPlaceholderText(/Search credentials/), "nothing-matches-this");
    expect(await screen.findByText(/No credentials match/)).toBeTruthy();
  });

  it("opens the generic import-credential form with a secret-kind selector", async () => {
    const user = userEvent.setup();
    render(<SshPage />);
    await unlock(user);

    await user.click(screen.getByText("Import credential"));
    expect(screen.getByText(/Import a credential from file/)).toBeTruthy();
    expect(screen.getByLabelText("Import kind")).toBeTruthy();

    await user.click(screen.getByText("Cancel"));
    expect(screen.queryByText(/Import a credential from file/)).toBeNull();
  });

  it("opens the credential edit form in place, inside its own group card", async () => {
    const user = userEvent.setup();
    render(<SshPage />);
    await unlock(user);

    await user.click(screen.getByText("Add credential"));
    await user.type(screen.getByPlaceholderText("Label"), "prod-db");
    await user.type(screen.getByPlaceholderText("Username"), "oracle");
    await user.type(screen.getByPlaceholderText("Password"), "s3cret");
    await user.type(screen.getByPlaceholderText(/^Group/), "prod");
    await user.click(screen.getByText("Save"));
    await screen.findByText("prod-db");

    await user.click(screen.getByTitle("Edit credential"));

    // The form replaces the row inside the "prod" card — not appended at the
    // bottom of the page, which is what used to lose the operator's place.
    const card = (await screen.findByRole("button", { name: /prod\s*\(1\)/ })).parentElement!;
    expect(within(card).getByText("Edit credential")).toBeTruthy();
    expect(within(card).getByDisplayValue("prod-db")).toBeTruthy();
  });

  it("opens the server edit form in place, inside its own group card", async () => {
    await mockInvoke("ssh_upsert_server", {
      server: {
        id: "",
        label: "db-1",
        host: "10.0.0.5",
        port: 22,
        username: "oracle",
        connectionType: "direct",
        credentialSource: { kind: "prompt" },
        group: "prod",
        tags: [],
      },
    });
    const user = userEvent.setup();
    render(<SshPage />);

    const card = (await screen.findByRole("button", { name: /prod\s*\(1\)/ })).parentElement!;
    await user.click(within(card).getByTitle("Edit server"));

    expect(within(card).getByText("Edit server")).toBeTruthy();
    expect(within(card).getByDisplayValue("prod")).toBeTruthy();
  });
});
