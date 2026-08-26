import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import ViewerErrorBoundary from "./ViewerErrorBoundary";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(() => Promise.resolve()) }));

function Boom(): React.ReactNode {
  throw new Error("chunk load failed");
}

describe("ViewerErrorBoundary: one bad viewer must not blank the whole app", () => {
  beforeEach(() => {
    // React logs the caught error; keep the test output readable.
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  it("renders children normally when nothing throws", () => {
    render(<ViewerErrorBoundary label="a.txt"><p>content</p></ViewerErrorBoundary>);
    expect(screen.getByText("content")).toBeTruthy();
  });

  it("shows a message instead of unmounting when a viewer throws", () => {
    render(<ViewerErrorBoundary label="data.csv"><Boom /></ViewerErrorBoundary>);
    expect(screen.getByText(/couldn't be displayed/i)).toBeTruthy();
    // The real failure must stay visible to the operator, not be swallowed.
    expect(screen.getByText(/chunk load failed/)).toBeTruthy();
  });

  it("reports the crash to the persistent log", async () => {
    const { invoke } = await import("@tauri-apps/api/core");
    render(<ViewerErrorBoundary label="data.csv"><Boom /></ViewerErrorBoundary>);
    expect(invoke).toHaveBeenCalledWith(
      "frontend_log",
      expect.objectContaining({ level: "error" }),
    );
  });
});
