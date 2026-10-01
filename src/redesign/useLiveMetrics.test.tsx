import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, act } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => invoke(...a) }));

import { useLiveMetrics, formatRam, METRICS_POLL_MS } from "./useLiveMetrics";

let renders = 0;
function Probe() {
  renders++;
  const m = useLiveMetrics(true);
  return <span data-testid="m">{`${m.cpu} ${m.ram}`}</span>;
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date(2026, 0, 1, 12, 0, 5)); // polls below never cross a minute (clock text)
  renders = 0;
  invoke.mockReset();
  invoke.mockResolvedValue({ cpu: 3.4, memMb: 120.2 });
});
afterEach(() => vi.useRealTimers());

describe("useLiveMetrics", () => {
  it("shows a dash until the first reading, then the values", async () => {
    render(<Probe />);
    expect(screen.getByTestId("m")).toHaveTextContent("— —");
    await act(async () => {});
    expect(screen.getByTestId("m")).toHaveTextContent("3% 120 MB");
  });

  it("does not re-render when a poll returns the same text", async () => {
    render(<Probe />);
    await act(async () => {});
    const after = renders;
    invoke.mockResolvedValue({ cpu: 3.1, memMb: 119.9 }); // rounds to the same text
    for (let i = 0; i < 8; i++) await act(async () => { vi.advanceTimersByTime(METRICS_POLL_MS); });
    expect(invoke).toHaveBeenCalledTimes(9);
    // React may run the component once more before bailing out; never once per poll.
    expect(renders - after).toBeLessThanOrEqual(1);
  });

  it("formats RAM", () => {
    expect(formatRam(512.4)).toBe("512 MB");
    expect(formatRam(2048)).toBe("2.0 GB");
  });
});
