import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

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

  it("+ opens New Connection; Remote shows IP/Port/PIN, Local hides them", async () => {
    const user = userEvent.setup();
    render(<ChatView />);
    await user.click(screen.getByTitle("New connection"));
    expect(screen.getByText("New Connection")).toBeInTheDocument();
    // Remote is default
    expect(screen.getByPlaceholderText("192.168.1.42")).toBeInTheDocument();
    expect(screen.getByPlaceholderText("7420")).toBeInTheDocument();
    expect(screen.getByPlaceholderText("8-digit PIN")).toBeInTheDocument();
    // switch to Local → fields gone (exact name targets the modal toggle,
    // not the rail's "Local (this machine)" connection button)
    await user.click(screen.getByRole("button", { name: "Local" }));
    expect(screen.queryByPlaceholderText("192.168.1.42")).not.toBeInTheDocument();
    expect(screen.getByText(/No IP, port, or PIN/i)).toBeInTheDocument();
  });

  it("Remote connect composes addr ip:port and confirms SAS", async () => {
    const user = userEvent.setup();
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "bridge_list_peers") return Promise.resolve(PEERS);
      if (cmd === "bridge_poll_inbound") return Promise.resolve([]);
      if (cmd === "bridge_pair_connect") return Promise.resolve({ sas: "123456", peer_spki: "newpeer" });
      return Promise.resolve(undefined);
    });
    render(<ChatView />);
    await user.click(screen.getByTitle("New connection"));
    await user.type(screen.getByPlaceholderText("192.168.1.42"), "10.0.0.9");
    await user.type(screen.getByPlaceholderText("7420"), "7420");
    await user.type(screen.getByPlaceholderText("8-digit PIN"), "11223344");
    await user.click(screen.getByRole("button", { name: /^Connect$/i }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("bridge_pair_connect", {
        addr: "10.0.0.9:7420", pin: "11223344", label: "10.0.0.9:7420",
      });
      expect(invokeMock).toHaveBeenCalledWith("bridge_pair_confirm_sas", { peer: "newpeer", sasOk: true });
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
});
