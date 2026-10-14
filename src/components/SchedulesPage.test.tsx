import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const invoke = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => invoke(...a) }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn(async () => () => {}) }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn(async () => "/Users/someone/project") }));

import SchedulesPage from "./SchedulesPage";
import type { JobView, Run } from "../lib/schedules";

const base: JobView = {
  id: "s1", name: "Nightly report", prompt: "write the report", folder: "/w/proj", schedule: { kind: "daily", time: "09:00" },
  enabled: true, timeoutMin: 30, bypass: true, chrome: true, created: 1, updated: 1, nextRun: Date.now() + 3_600_000, running: false, queued: false,
  runs: 3, ok: 2, failed: 1, last: { started: Date.now() - 120_000, ended: Date.now() - 60_000, status: "failed" },
};
const runs: Run[] = [
  { jobId: "s1", started: 3000, ended: 9000, status: "failed", exitCode: 1, costUsd: null, trigger: "schedule", output: "boom: MCP server failed" },
  { jobId: "s1", started: 1000, ended: 2000, status: "success", exitCode: 0, costUsd: 0.04, trigger: "manual", output: "all done" },
];

let jobs: JobView[];
let service: { state: string; running: boolean; version: string | null };
beforeEach(() => {
  jobs = [base];
  service = { state: "off", running: false, version: null };
  invoke.mockReset();
  invoke.mockImplementation(async (cmd: string, args?: Record<string, unknown>) => {
    switch (cmd) {
      case "schedules_list": return { jobs, active: service.state !== "on", runner: service.state === "on" ? "service" : "here" };
      case "bg_service_status": return service;
      case "bg_service_set":
        service = args!.enabled ? { state: "approval", running: false, version: null } : { state: "off", running: false, version: null };
        return service;
      case "bg_service_open_settings": return null;
      case "schedule_runs": return runs;
      case "schedule_set_enabled": jobs = jobs.map((j) => ({ ...j, enabled: args!.enabled as boolean })); return null;
      case "schedule_delete": jobs = []; return null;
      case "schedule_run_now": return null;
      case "schedule_save": {
        const job = args!.job as JobView;
        if (!job.prompt) throw "The prompt is empty.";
        jobs = [...jobs, { ...base, ...job, id: "s2", runs: 0, ok: 0, failed: 0, last: null }];
        return job;
      }
    }
  });
});

describe("SchedulesPage", () => {
  it("Run when Muya is closed turns the background service on and asks for approval", async () => {
    render(<SchedulesPage />);
    const sw = await screen.findByRole("switch", { name: "Run when Muya is closed" });
    await waitFor(() => expect(sw).toBeEnabled());
    expect(sw).toHaveAttribute("aria-checked", "false");
    expect(screen.getByText("Off. Schedules run while Muya is open.")).toBeInTheDocument();
    fireEvent.click(sw);
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("bg_service_set", { enabled: true }));
    await screen.findByText(/macOS is waiting for your OK/);
    fireEvent.click(screen.getByRole("button", { name: "Open Login Items" }));
    expect(invoke).toHaveBeenCalledWith("bg_service_open_settings");
    expect(sw).toHaveAttribute("aria-checked", "true");
  });

  it("the switch is disabled where the service can't run", async () => {
    service = { state: "unavailable", running: false, version: null };
    render(<SchedulesPage />);
    await screen.findByText(/Available in the installed Muya app/);
    expect(screen.getByRole("switch", { name: "Run when Muya is closed" })).toBeDisabled();
  });

  it("shows the report and a card per schedule", async () => {
    render(<SchedulesPage />);
    const card = await screen.findByRole("region", { name: "Nightly report" });
    expect(within(card).getByText("Every day at 09:00")).toBeInTheDocument();
    expect(within(card).getByText("/w/proj")).toBeInTheDocument();
    expect(within(card).getByText("Failed")).toBeInTheDocument();
    expect(card.textContent).toMatch(/Runs3 \(2✓ 1✗\)/);
    expect(card.textContent).toMatch(/Next runtoday|Next runtomorrow/);
    const summary = screen.getByLabelText("Summary");
    expect(within(summary).getByText("67%")).toBeInTheDocument();
    expect(within(summary).getByText("2 succeeded · 1 failed")).toBeInTheDocument();
  });

  it("toggle, Run now and Delete call the backend", async () => {
    render(<SchedulesPage />);
    const card = await screen.findByRole("region", { name: "Nightly report" });
    fireEvent.click(within(card).getByRole("switch"));
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("schedule_set_enabled", { id: "s1", enabled: false }));
    fireEvent.click(within(card).getByRole("button", { name: /Run now/ }));
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("schedule_run_now", { id: "s1" }));
    fireEvent.click(within(card).getByRole("button", { name: "Delete Nightly report" }));
    const dlg = screen.getByRole("dialog", { name: "Delete schedule" });
    expect(dlg.textContent).toMatch(/3 saved runs/);
    fireEvent.click(within(dlg).getByRole("button", { name: "Delete" }));
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("schedule_delete", { id: "s1" }));
    expect(await screen.findByText(/No schedules yet/)).toBeInTheDocument();
  });

  it("history lists runs, newest open, and expands another run's output", async () => {
    render(<SchedulesPage />);
    const card = await screen.findByRole("region", { name: "Nightly report" });
    fireEvent.click(within(card).getByRole("button", { name: /History/ }));
    const dlg = await screen.findByRole("dialog", { name: "History · Nightly report" });
    expect(await within(dlg).findByText("boom: MCP server failed")).toBeInTheDocument();
    expect(within(dlg).getByText("Scheduled")).toBeInTheDocument();
    fireEvent.click(within(dlg).getByText("Run now").closest("button")!);
    expect(within(dlg).getByText("all done")).toBeInTheDocument();
    expect(within(dlg).getByText("$0.04")).toBeInTheDocument();
  });

  it("New schedule: weekly days, folder picker, bypass warning, backend errors shown", async () => {
    render(<SchedulesPage />);
    await screen.findByRole("region", { name: "Nightly report" });
    fireEvent.click(screen.getByRole("button", { name: /New schedule/ }));
    const dlg = screen.getByRole("dialog", { name: "New schedule" });
    expect(within(dlg).getByRole("note").textContent).toMatch(/without asking/);
    fireEvent.change(within(dlg).getByLabelText("Name"), { target: { value: "Weekly audit" } });
    fireEvent.click(within(dlg).getByRole("button", { name: "Create" }));
    expect(await within(dlg).findByRole("alert")).toHaveTextContent("The prompt is empty.");

    fireEvent.change(within(dlg).getByLabelText("Prompt"), { target: { value: "audit deps" } });
    fireEvent.click(within(dlg).getByRole("radio", { name: "Weekly" }));
    fireEvent.click(within(dlg).getByRole("button", { name: "Fri" })); // drop Friday
    fireEvent.change(within(dlg).getByLabelText("Time"), { target: { value: "18:30" } });
    await act(async () => fireEvent.click(within(dlg).getByRole("button", { name: /Choose/ })));
    expect(within(dlg).getByLabelText("Folder")).toHaveValue("/Users/someone/project");
    fireEvent.click(within(dlg).getByRole("switch", { name: "Skip permission prompts" }));
    const browser = within(dlg).getByRole("switch", { name: "Browser (Claude in Chrome)" });
    expect(browser).toHaveAttribute("aria-checked", "true");
    fireEvent.click(browser);
    expect(within(dlg).getByRole("note").textContent).toMatch(/fail the run/);
    expect(within(dlg).getByText("Runs: Mon, Tue, Wed, Thu at 18:30")).toBeInTheDocument();
    fireEvent.click(within(dlg).getByRole("button", { name: "Create" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    const saves = invoke.mock.calls.filter(([c]) => c === "schedule_save");
    const saved = saves[saves.length - 1][1].job;
    expect(saved).toMatchObject({
      name: "Weekly audit", prompt: "audit deps", folder: "/Users/someone/project", bypass: false, chrome: false, id: null,
      schedule: { kind: "weekly", days: [0, 1, 2, 3], time: "18:30" },
    });
    expect(await screen.findByRole("region", { name: "Weekly audit" })).toBeInTheDocument();
  });

  it("Edit opens the form filled in", async () => {
    render(<SchedulesPage />);
    const card = await screen.findByRole("region", { name: "Nightly report" });
    fireEvent.click(within(card).getByRole("button", { name: "Edit Nightly report" }));
    const dlg = screen.getByRole("dialog", { name: "Edit schedule" });
    expect(within(dlg).getByLabelText("Prompt")).toHaveValue("write the report");
    expect(within(dlg).getByRole("radio", { name: "Daily" })).toHaveAttribute("aria-checked", "true");
    expect(within(dlg).getByRole("button", { name: "Save" })).toBeInTheDocument();
  });
});
