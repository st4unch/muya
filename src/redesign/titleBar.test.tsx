import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";

const invoke = vi.fn(async () => undefined);
const startDragging = vi.fn(async () => undefined);
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => invoke(...(a as [])) }));
vi.mock("@tauri-apps/api/window", () => ({ getCurrentWindow: () => ({ startDragging }) }));

import { ControlHeader } from "./ControlHeader";
import { previewHeader } from "./previewFixture";

beforeEach(() => {
  invoke.mockClear();
  startDragging.mockClear();
});

function setup() {
  const onOpenPalette = vi.fn();
  render(
    <ControlHeader
      header={previewHeader}
      themePreference="dark"
      onThemeCycle={() => {}}
      onNotificationsClick={() => {}}
      onWorkspaceClick={() => {}}
      onOpenPalette={onOpenPalette}
    />,
  );
  return { header: screen.getByRole("banner"), onOpenPalette };
}

describe("title bar", () => {
  it("double-click on the bar background or its text zooms the window, single press drags", () => {
    const { header } = setup();
    fireEvent.mouseDown(header, { button: 0, detail: 1 });
    expect(startDragging).toHaveBeenCalledTimes(1);
    fireEvent.mouseDown(header, { button: 0, detail: 2 });
    expect(invoke).toHaveBeenCalledWith("title_bar_double_click");
    // Plain text in the bar (the CPU readout) counts as bar, not as selectable text.
    fireEvent.mouseDown(screen.getByText("CPU", { exact: false }), { button: 0, detail: 2 });
    expect(invoke).toHaveBeenCalledTimes(2);
  });

  it("controls keep their own clicks: the search pill opens the palette, no zoom/drag", () => {
    const { onOpenPalette } = setup();
    const search = screen.getByRole("button", { name: /Search agents/ });
    fireEvent.mouseDown(search, { button: 0, detail: 2 });
    fireEvent.click(search);
    expect(invoke).not.toHaveBeenCalled();
    expect(startDragging).not.toHaveBeenCalled();
    expect(onOpenPalette).toHaveBeenCalled();
  });

  it("text in the bar can't be selected", () => {
    const { header } = setup();
    expect(header.style.userSelect).toBe("none");
  });
});
