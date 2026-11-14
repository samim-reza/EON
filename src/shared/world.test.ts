import { describe, expect, it } from "vitest";
import { LAND_LEVEL, landLookup, makeTerrain } from "./world";

describe("landLookup", () => {
  const terrain = makeTerrain(1257650109);
  it("agrees with the terrain about what is land", () => {
    const isLand = landLookup(terrain.elevation);
    let land = 0;
    for (let x = 0; x <= 1000; x += 37) {
      for (let y = 0; y <= 1000; y += 41) {
        expect(isLand(x, y)).toBe(terrain.elevation(x, y) >= LAND_LEVEL);
        if (isLand(x, y)) land++;
      }
    }
    expect(land).toBeGreaterThan(50); // the sample really crossed both land and sea
  });
  it("works each point out once, however often it is asked", () => {
    let asked = 0;
    const isLand = landLookup((x, y) => {
      asked++;
      return terrain.elevation(x, y);
    });
    for (let i = 0; i < 1000; i++) isLand(500.2, 499.9);
    expect(asked).toBe(1);
  });
  it("still answers beyond the edge of the map", () => {
    const isLand = landLookup(terrain.elevation);
    expect(isLand(-50, 5000)).toBe(false);
  });
});
