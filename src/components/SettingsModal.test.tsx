import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => invoke(...a) }));

import SettingsModal from "./SettingsModal";

beforeEach(() => {
  invoke.mockReset();
  invoke.mockImplementation(async (cmd: string) => (cmd === "debug_log_get" ? { enabled: false, path: "~/.claude/muya-debug.log" } : undefined));
});

describe("SettingsModal", () => {
  it("theme segment applies immediately", async () => {
    const onTheme = vi.fn();
    render(<SettingsModal open onClose={() => {}} themePreference="light" onThemePreferenceChange={onTheme} />);
    expect(screen.getByRole("radio", { name: "Light" })).toHaveAttribute("aria-checked", "true");
    fireEvent.click(screen.getByRole("radio", { name: "Dark" }));
    expect(onTheme).toHaveBeenCalledWith("dark");
  });

  it("Save is disabled until something changes, then saves the switch and path", async () => {
    render(<SettingsModal open onClose={() => {}} />);
    const save = screen.getByRole("button", { name: "Save" });
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("debug_log_get"));
    expect(save).toBeDisabled();
    fireEvent.click(screen.getByRole("switch", { name: /Log CyberArk/ }));
    expect(screen.getByRole("switch", { name: /Log CyberArk/ })).toHaveAttribute("aria-checked", "true");
    expect(save).toBeEnabled();
    fireEvent.click(save);
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("debug_log_set", { enabled: true, path: "~/.claude/muya-debug.log" }));
    await screen.findByText("Saved");
    expect(save).toBeDisabled();
  });

  it("Escape closes", () => {
    const onClose = vi.fn();
    render(<SettingsModal open onClose={onClose} />);
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalled();
  });
});
