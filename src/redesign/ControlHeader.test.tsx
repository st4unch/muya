import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ControlHeader } from "./ControlHeader";
import { previewHeader } from "./previewFixture";

describe("ControlHeader", () => {
  it("clicking the theme button calls onThemeCycle", () => {
    const onThemeCycle = vi.fn();
    render(
      <ControlHeader
        header={previewHeader}
        themePreference="dark"
        onThemeCycle={onThemeCycle}
        onNotificationsClick={vi.fn()}
        onWorkspaceClick={vi.fn()}
        onOpenPalette={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByLabelText("Theme: dark"));
    expect(onThemeCycle).toHaveBeenCalledTimes(1);
  });

  it("shows the notification dot when hasNotifications is true", () => {
    render(
      <ControlHeader
        header={{ ...previewHeader, hasNotifications: true }}
        themePreference="system"
        onThemeCycle={vi.fn()}
        onNotificationsClick={vi.fn()}
        onWorkspaceClick={vi.fn()}
        onOpenPalette={vi.fn()}
      />,
    );
    expect(screen.getByLabelText("Theme: system")).toBeInTheDocument();
    expect(screen.getByLabelText("Notifications")).toBeInTheDocument();
  });

  it("opens the palette from the search button", () => {
    const onOpenPalette = vi.fn();
    render(
      <ControlHeader
        header={previewHeader}
        themePreference="light"
        onThemeCycle={vi.fn()}
        onNotificationsClick={vi.fn()}
        onWorkspaceClick={vi.fn()}
        onOpenPalette={onOpenPalette}
      />,
    );
    fireEvent.click(screen.getByText("Search agents, files or commands…"));
    expect(onOpenPalette).toHaveBeenCalled();
  });
});
