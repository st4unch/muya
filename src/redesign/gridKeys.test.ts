import { describe, expect, it } from "vitest";
import { assignGridCell } from "./gridKeys";

describe("assignGridCell", () => {
  const grid = ["a", "b", "c", "d"];
  it("a session from outside the grid takes the target cell", () => {
    expect(assignGridCell(grid, "b", "x")).toEqual(["a", "x", "c", "d"]);
  });
  it("a session already in the grid trades places with the target", () => {
    expect(assignGridCell(grid, "a", "d")).toEqual(["d", "b", "c", "a"]);
  });
  it("picking the cell's own session changes nothing", () => {
    expect(assignGridCell(grid, "c", "c")).toEqual(grid);
  });
  it("an empty cell gets the pick appended", () => {
    expect(assignGridCell(["a", "b"], "empty:0", "x")).toEqual(["a", "b", "x"]);
    expect(assignGridCell(["a", "b"], "empty:0", "a")).toEqual(["b", "a"]);
  });
  it("an unknown target leaves the grid alone", () => {
    expect(assignGridCell(grid, "zz", "x")).toEqual(grid);
  });
});
