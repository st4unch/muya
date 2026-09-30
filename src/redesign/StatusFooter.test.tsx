import { render, screen, fireEvent, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(() => Promise.resolve(null)) }));
import { Footer } from "./Footer";
import { previewFooter } from "./previewFixture";
import { useStatusFields, STATUS_FIELDS_KEY } from "./useStatusFields";

const DATA = {
  model: { display_name: "Opus" },
  cost: { total_cost_usd: 0.1234 },
  context_window: { used_percentage: 42 },
};

function Harness({ data }: { data: Record<string, unknown> | null }) {
  const s = useStatusFields();
  return <Footer {...previewFooter} status={{ fields: s.fields, data, onToggle: s.toggle, onRemove: s.remove }} />;
}

beforeEach(() => localStorage.clear());
afterEach(() => localStorage.clear());

describe("footer status fields", () => {
  it("adds and removes via the picker and persists the order", () => {
    render(<Harness data={DATA} />);
    fireEvent.click(screen.getByLabelText("Add status field"));
    fireEvent.click(screen.getByRole("menuitemcheckbox", { name: /^Cost/ }));
    fireEvent.click(screen.getByRole("menuitemcheckbox", { name: /^Model\s*Opus$/ }));
    expect(JSON.parse(localStorage.getItem(STATUS_FIELDS_KEY)!)).toEqual(["cost.total_cost_usd", "model.display_name"]);
    const footer = screen.getByRole("contentinfo");
    expect(footer.querySelector('[data-status-field="cost.total_cost_usd"]')!.textContent).toContain("$0.12");
    // uncheck removes
    fireEvent.click(screen.getByRole("menuitemcheckbox", { name: /^✓\s*Cost/ }));
    expect(JSON.parse(localStorage.getItem(STATUS_FIELDS_KEY)!)).toEqual(["model.display_name"]);
  });

  it("filters the picker and previews current values", () => {
    render(<Harness data={DATA} />);
    fireEvent.click(screen.getByLabelText("Add status field"));
    expect(screen.getByRole("menuitemcheckbox", { name: /Context used.*42%/ })).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Filter status fields"), { target: { value: "hit ratio" } });
    const row = screen.getByRole("menuitemcheckbox", { name: /Cache hit ratio/ });
    expect(row.textContent).toContain("—");
    expect(screen.queryByRole("menuitemcheckbox", { name: /Context used/ })).toBeNull();
  });

  it("restores the persisted list, hides absent fields, right-click removes", () => {
    localStorage.setItem(STATUS_FIELDS_KEY, JSON.stringify(["model.display_name", "cost.total_cost_usd", "pr.number", "bogus"]));
    render(<Harness data={DATA} />);
    const footer = screen.getByRole("contentinfo");
    expect(within(footer).getByText("Opus")).toBeTruthy();
    expect(footer.querySelector('[data-status-field="pr.number"]')).toBeNull(); // absent -> hidden
    fireEvent.contextMenu(footer.querySelector('[data-status-field="model.display_name"]')!);
    expect(footer.querySelector('[data-status-field="model.display_name"]')).toBeNull();
    expect(JSON.parse(localStorage.getItem(STATUS_FIELDS_KEY)!)).toEqual(["cost.total_cost_usd", "pr.number"]);
  });

  it("shows nothing and explains why when the session has no data", () => {
    localStorage.setItem(STATUS_FIELDS_KEY, JSON.stringify(["model.display_name"]));
    render(<Harness data={null} />);
    expect(screen.getByRole("contentinfo").querySelector("[data-status-field]")).toBeNull();
    fireEvent.click(screen.getByLabelText("Add status field"));
    expect(screen.getByText(/Status data appears for Claude sessions started from Muya/)).toBeTruthy();
  });

  it("renders unchanged without the status prop", () => {
    render(<Footer {...previewFooter} />);
    expect(screen.queryByLabelText("Add status field")).toBeNull();
  });
});
