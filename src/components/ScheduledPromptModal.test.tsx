import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import ScheduledPromptModal, { type ScheduledPrompt } from "./ScheduledPromptModal";

const TERMINALS = [
  { key: "t1", name: "claude-control-plane" },
  { key: "t2", name: "Documents" },
];

const PENDING: ScheduledPrompt = {
  id: "s1",
  prompt: "git status",
  terminalKeys: ["t1"],
  scheduledAt: Date.now() + 60_000,
  fired: false,
};

const FIRED: ScheduledPrompt = {
  id: "s2",
  prompt: "echo done",
  terminalKeys: ["t1", "t2"],
  scheduledAt: Date.now() - 1000,
  fired: true,
};

describe("ScheduledPromptModal", () => {
  const onAdd = vi.fn();
  const onCancel = vi.fn();
  const onClose = vi.fn();

  beforeEach(() => vi.clearAllMocks());

  it("renders nothing when closed", () => {
    const { container } = render(
      <ScheduledPromptModal
        open={false}
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("shows terminal checkboxes when open", () => {
    render(
      <ScheduledPromptModal
        open
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );
    expect(screen.getByText("claude-control-plane")).toBeInTheDocument();
    expect(screen.getByText("Documents")).toBeInTheDocument();
  });

  it("Schedule button is disabled until prompt + terminal selected", async () => {
    const user = userEvent.setup();
    render(
      <ScheduledPromptModal
        open
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );

    const btn = screen.getByRole("button", { name: /schedule/i });
    expect(btn).toBeDisabled();

    // type prompt — still no terminal selected, stays disabled
    await user.type(screen.getByPlaceholderText(/claude/i), "run tests");
    expect(btn).toBeDisabled();

    // select first terminal — now enabled
    await user.click(screen.getByText("claude-control-plane"));
    expect(btn).not.toBeDisabled();
  });

  it("calls onAdd with correct data on Schedule click", async () => {
    const user = userEvent.setup();
    render(
      <ScheduledPromptModal
        open
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );

    await user.type(screen.getByPlaceholderText(/claude/i), "run tests");
    await user.click(screen.getByText("claude-control-plane"));
    await user.click(screen.getByRole("button", { name: /schedule/i }));

    expect(onAdd).toHaveBeenCalledTimes(1);
    expect(onAdd).toHaveBeenCalledWith(
      expect.objectContaining({
        prompt: "run tests",
        terminalKeys: ["t1"],
      })
    );
  });

  it("shows pending prompts list", () => {
    render(
      <ScheduledPromptModal
        open
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[PENDING]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );
    expect(screen.getByText("git status")).toBeInTheDocument();
    expect(screen.getByText(/Bekleyen/)).toBeInTheDocument();
  });

  it("calls onCancel when trash button clicked", async () => {
    const user = userEvent.setup();
    render(
      <ScheduledPromptModal
        open
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[PENDING]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );
    // Trash button is the delete icon next to the pending prompt
    const trashBtns = screen.getAllByRole("button").filter(b =>
      b.querySelector("svg") && !b.textContent?.includes("Schedule")
    );
    // Find the cancel button (not the close X or Schedule)
    await user.click(trashBtns[trashBtns.length - 1]);
    expect(onCancel).toHaveBeenCalledWith("s1");
  });

  it("shows recently fired prompts", () => {
    render(
      <ScheduledPromptModal
        open
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[FIRED]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );
    expect(screen.getByText("echo done")).toBeInTheDocument();
    expect(screen.getByText(/Son Gönderilen/)).toBeInTheDocument();
  });

  it("BUG REGRESSION: shows a visible error instead of silently failing when the picked time has already elapsed", async () => {
    // Reproduces the reported bug: user fills the form, the 5-min default
    // deadline passes while typing, and the first Schedule click used to
    // no-op with zero feedback (looked broken; retry after reopening worked
    // only because the effect refreshed the default time).
    const user = userEvent.setup();
    render(
      <ScheduledPromptModal
        open
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );

    await user.type(screen.getByPlaceholderText(/claude/i), "run tests");
    await user.click(screen.getByText("claude-control-plane"));

    // Simulate the deadline having elapsed (e.g. user took >5 min typing).
    // fireEvent.change (not user.type) — jsdom doesn't simulate segmented
    // native time-input typing, so a direct value+change event is used here.
    const timeInput = document.querySelector('input[type="time"]') as HTMLInputElement;
    const pastTime = new Date(Date.now() - 60_000);
    const pad = (n: number) => String(n).padStart(2, "0");
    const pastTimeStr = `${pad(pastTime.getHours())}:${pad(pastTime.getMinutes())}:${pad(pastTime.getSeconds())}`;
    fireEvent.change(timeInput, { target: { value: pastTimeStr } });

    await user.click(screen.getByRole("button", { name: /schedule/i }));

    // Must NOT silently succeed with a past time, and must surface an error.
    expect(onAdd).not.toHaveBeenCalled();
    expect(screen.getByText(/geçmişte kaldı/i)).toBeInTheDocument();
  });

  it("time and date inputs are rendered with defaults", () => {
    render(
      <ScheduledPromptModal
        open
        onClose={onClose}
        terminals={TERMINALS}
        scheduled={[]}
        onAdd={onAdd}
        onCancel={onCancel}
      />
    );
    const timeInput = document.querySelector('input[type="time"]') as HTMLInputElement;
    const dateInput = document.querySelector('input[type="date"]') as HTMLInputElement;
    expect(timeInput).toBeTruthy();
    expect(dateInput).toBeTruthy();
    expect(timeInput.value).toMatch(/^\d{2}:\d{2}:\d{2}$/);
    expect(dateInput.value).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});
