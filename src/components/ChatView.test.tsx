import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));
vi.mock("@tauri-apps/api/event", () => ({
  listen: () => Promise.resolve(() => {}),
}));

const invokeMock = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

import ChatView from "./ChatView";

// Peers come back from Rust in SNAKE_CASE (structs have no rename_all=camelCase).
// The component must read snake_case — this fixture mirrors the real wire shape.
const PEERS = [
  { spki_hash: "aabbcc", label: "lab-mac", last_addr: "192.168.1.42:7420", paired_at: 0 },
  { spki_hash: "ddeeff", label: "build-box", last_addr: "192.168.1.55:7420", paired_at: 0 },
];

function wireDefault() {
  invokeMock.mockImplementation((cmd: string) => {
    if (cmd === "bridge_list_peers") return Promise.resolve(PEERS);
    if (cmd === "bridge_poll_inbound") return Promise.resolve([]);
    return Promise.resolve(undefined);
  });
}

describe("ChatView", () => {
  beforeEach(() => { invokeMock.mockReset(); wireDefault(); });
  afterEach(() => { vi.clearAllTimers(); });

  it("renders the Local connection + rail header + New-connection button", async () => {
    render(<ChatView />);
    expect(screen.getByText("Claude Chat")).toBeInTheDocument();
    expect(screen.getAllByText("Local (this machine)").length).toBeGreaterThan(0);
    expect(screen.getByTitle("New connection")).toBeInTheDocument();
  });

  it("REGRESSION: renders paired peer labels from snake_case bridge_list_peers", async () => {
    render(<ChatView />);
    // If the component read camelCase (p.spkiHash/p.lastAddr), these would be
    // blank/undefined and the labels would be missing.
    expect(await screen.findByText("lab-mac")).toBeInTheDocument();
    expect(await screen.findByText("build-box")).toBeInTheDocument();
    expect(screen.getByText("192.168.1.42:7420")).toBeInTheDocument();
  });

  it("ending a session revokes the peer via bridge_revoke_peer and drops it from the rail", async () => {
    const user = userEvent.setup();
    let revoked = false;
    invokeMock.mockImplementation((cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "bridge_list_peers") {
        return Promise.resolve(revoked ? [PEERS[1]] : PEERS); // lab-mac gone after revoke
      }
      if (cmd === "bridge_poll_inbound") return Promise.resolve([]);
      if (cmd === "bridge_revoke_peer") { revoked = true; void args; return Promise.resolve(undefined); }
      return Promise.resolve(undefined);
    });

    render(<ChatView />);
    expect(await screen.findByText("lab-mac")).toBeInTheDocument();
    // The end-session (X) button is labelled per-peer; clicking it opens the
    // in-app confirm modal (NOT a native window.confirm).
    await user.click(screen.getByRole("button", { name: /End session with lab-mac/i }));
    const dialog = within(await screen.findByRole("dialog", { name: "End session" }));
    // Confirm inside the modal actually revokes.
    await user.click(dialog.getByRole("button", { name: /End session/i }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_revoke_peer", { spkiHash: "aabbcc" });
    });
    // After revoke the rail no longer lists that peer.
    await waitFor(() => expect(screen.queryByText("lab-mac")).not.toBeInTheDocument());
    expect(screen.getByText("build-box")).toBeInTheDocument();
  });

  it("+ opens New Connection; Remote shows IP/Port/PIN, Local hides them", async () => {
    const user = userEvent.setup();
    render(<ChatView />);
    await user.click(screen.getByTitle("New connection"));
    expect(screen.getByText("New Connection")).toBeInTheDocument();
    // Scope to the modal — the listen editor in the rail reuses the same
    // 192.168.1.42 / 7420 placeholders, so unscoped queries would be ambiguous.
    const dialog = within(screen.getByRole("dialog", { name: "New Connection" }));
    // Remote is default
    expect(dialog.getByPlaceholderText("192.168.1.42")).toBeInTheDocument();
    expect(dialog.getByPlaceholderText("7420")).toBeInTheDocument();
    expect(dialog.getByPlaceholderText("8-digit PIN")).toBeInTheDocument();
    // switch to Local → fields gone (exact name targets the modal toggle,
    // not the rail's "Local (this machine)" connection button)
    await user.click(dialog.getByRole("button", { name: "Local" }));
    expect(dialog.queryByPlaceholderText("192.168.1.42")).not.toBeInTheDocument();
    expect(screen.getByText(/No IP, port, or PIN/i)).toBeInTheDocument();
  });

  it("Remote connect composes addr ip:port and shows the SAS to confirm (no auto-confirm)", async () => {
    const user = userEvent.setup();
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "bridge_list_peers") return Promise.resolve(PEERS);
      if (cmd === "bridge_poll_inbound") return Promise.resolve([]);
      if (cmd === "bridge_pair_connect") return Promise.resolve({ sas: "428195", peer_spki: "newpeer" });
      return Promise.resolve(undefined);
    });
    render(<ChatView />);
    await user.click(screen.getByTitle("New connection"));
    const dialog = within(screen.getByRole("dialog", { name: "New Connection" }));
    await user.type(dialog.getByPlaceholderText("192.168.1.42"), "10.0.0.9");
    await user.type(dialog.getByPlaceholderText("7420"), "7420");
    await user.type(dialog.getByPlaceholderText("8-digit PIN"), "11223344");
    await user.click(dialog.getByRole("button", { name: /^Connect$/i }));

    // pair_connect is called with the composed addr; the SAS is shown for the
    // human to compare — NOT auto-confirmed (MITM protection, PRD R3).
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_pair_connect", {
        addr: "10.0.0.9:7420", pin: "11223344", label: "10.0.0.9:7420",
      });
    });
    expect(await screen.findByText("428195")).toBeInTheDocument();
    expect(screen.getByText(/SAS/i)).toBeInTheDocument();
    // Confirming pins the peer.
    await user.click(screen.getByRole("button", { name: /Confirm/i }));
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_pair_confirm_sas", { peerSpki: "newpeer", sasOk: true, label: "10.0.0.9:7420" });
    });
  });

  it("sending a message calls bridge_send with the typed payload", async () => {
    const user = userEvent.setup();
    render(<ChatView />);
    const box = screen.getByPlaceholderText(/^Message/);
    await user.type(box, "merhaba");
    fireEvent.keyDown(box, { key: "Enter" });
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_send", { peer: "local", kind: "question", payload: "merhaba" });
    });
    expect(screen.getByText("merhaba")).toBeInTheDocument();
  });

  it("Esc closes the New Connection modal", async () => {
    const user = userEvent.setup();
    render(<ChatView />);
    await user.click(screen.getByTitle("New connection"));
    expect(screen.getByText("New Connection")).toBeInTheDocument();
    fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => expect(screen.queryByText("New Connection")).not.toBeInTheDocument());
  });

  it("auto-respond: answers an inbound question via bridge_run_claude and sends the answer back", async () => {
    const user = userEvent.setup();
    let served = false;
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "bridge_list_peers") return Promise.resolve([]);
      if (cmd === "bridge_poll_inbound") {
        if (served) return Promise.resolve([]);
        served = true;
        return Promise.resolve([
          { req_id: "q1", peer: "local", capability: "research", kind: "question", payload: "2+2?", approval: "not_required" },
        ]);
      }
      if (cmd === "bridge_run_claude") return Promise.resolve("4");
      return Promise.resolve(undefined);
    });

    render(<ChatView />);
    // Toggle auto-respond ON.
    await user.click(screen.getByRole("button", { name: /Auto-respond/i }));

    // The inbound question is answered by the local Claude and sent back as { answer }.
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_run_claude", { question: "2+2?" });
      expect(invokeMock).toHaveBeenCalledWith("bridge_send", { peer: "local", kind: "question", payload: { answer: "4" } });
    }, { timeout: 4000 });
    expect(await screen.findByText("4")).toBeInTheDocument();
  });

  it("listen: validates the port via bridge_check_port and shows failure without binding", async () => {
    const user = userEvent.setup();
    let startCalled = false;
    invokeMock.mockImplementation((cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "bridge_list_peers") return Promise.resolve([]);
      if (cmd === "bridge_poll_inbound") return Promise.resolve([]);
      if (cmd === "local_ip") return Promise.resolve("192.168.1.42");
      if (cmd === "bridge_check_port") {
        // Reject the port so we can assert the listener is NOT started.
        return Promise.resolve({ ok: false, listening: false, detail: "Port is in use by another app on this machine" });
      }
      if (cmd === "bridge_pair_start_listener") { startCalled = true; void args; return Promise.resolve(undefined); }
      return Promise.resolve(undefined);
    });

    render(<ChatView />);
    // IP is prefilled from local_ip; click Accept → runs the pre-flight check.
    await user.click(screen.getByRole("button", { name: /Accept connections/i }));

    // The failure detail is surfaced and the pairing listener is never bound.
    expect(await screen.findByText(/in use by another app/i)).toBeInTheDocument();
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_check_port", { addr: "192.168.1.42:7420" });
    });
    expect(startCalled).toBe(false);
  });

  it("listen: an editable IP:port composes the addr passed to bridge_check_port", async () => {
    const user = userEvent.setup();
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "bridge_list_peers") return Promise.resolve([]);
      if (cmd === "bridge_poll_inbound") return Promise.resolve([]);
      if (cmd === "local_ip") return Promise.resolve("192.168.1.42");
      if (cmd === "bridge_check_port") return Promise.resolve({ ok: true, listening: false, detail: "Port available" });
      return Promise.resolve(undefined);
    });

    render(<ChatView />);
    // Wait for the IP prefill, then edit the port and click the Test button.
    const portInput = await screen.findByLabelText("Listen port");
    await user.clear(portInput);
    await user.type(portInput, "9000");
    await user.click(screen.getByTitle(/Test port/i));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_check_port", { addr: "192.168.1.42:9000" });
    });
    expect(await screen.findByText("Port available")).toBeInTheDocument();
  });

  it("listen: stopping calls bridge_pair_stop_listener to actually tear down the port (L10)", async () => {
    const user = userEvent.setup();
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "bridge_list_peers") return Promise.resolve([]);
      if (cmd === "bridge_poll_inbound") return Promise.resolve([]);
      if (cmd === "local_ip") return Promise.resolve("192.168.1.42");
      if (cmd === "bridge_check_port") return Promise.resolve({ ok: true, listening: true, detail: "Listening" });
      if (cmd === "bridge_pair_invite") return Promise.resolve({ pin: "12345678" });
      return Promise.resolve(undefined);
    });

    render(<ChatView />);
    // Start listening → button flips to "Listening for peers".
    await user.click(screen.getByRole("button", { name: /Accept connections/i }));
    const stopBtn = await screen.findByRole("button", { name: /Listening for peers/i });

    // Stop → MUST call the real teardown (not just flip UI state). This is the
    // regression guard for the "port stays bound after stop" bug.
    await user.click(stopBtn);
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_pair_stop_listener");
      expect(invokeMock).toHaveBeenCalledWith("bridge_local_listen", { enable: false });
    });
    // UI returns to the idle "Accept connections" affordance.
    expect(await screen.findByRole("button", { name: /Accept connections/i })).toBeInTheDocument();
  });
});
