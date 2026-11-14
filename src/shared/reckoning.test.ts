import { describe, expect, it } from "vitest";
import { reckoningLine, recordLine } from "./reckoning";

describe("the reckoning", () => {
  it("says how someone left the world, and nothing about what comes after", () => {
    expect(reckoningLine("light")).toContain("light heart");
    expect(reckoningLine("heavy")).toContain("heavy record");
    expect(reckoningLine("child")).toContain("Nothing is held against a child");
    for (const r of ["light", "even", "heavy", "child"]) expect(reckoningLine(r)).not.toMatch(/heaven|hell|paradise|fire|garden/i);
  });
  it("says nothing for the living, or for a record it does not know", () => {
    expect(reckoningLine(null)).toBeNull();
    expect(reckoningLine("damned")).toBeNull();
  });
  it("puts a living person's own record into words", () => {
    expect(recordLine({ good: 3, ill: 0, mended: 0 })).toBe("3 good deeds · nothing to answer for");
    expect(recordLine({ good: 1, ill: 2, mended: 1 })).toBe("1 good deed · 2 ill deeds to answer for · 1 laid down by asking forgiveness");
    expect(recordLine(undefined)).toBeNull();
  });
});
