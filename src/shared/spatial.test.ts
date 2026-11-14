import { describe, expect, it } from "vitest";
import { spatialIndex } from "./spatial";
import { hash01 } from "./world";

const places = Array.from({ length: 500 }, (_, i) => ({ id: i, x: hash01(i, 1) * 1000, y: hash01(i, 2) * 1000 }));
const index = spatialIndex(places);
const ids = (run: (visit: (p: { id: number }) => void) => void) => {
  const out: number[] = [];
  run((p) => out.push(p.id));
  return out.sort((a, b) => a - b);
};

describe("spatialIndex", () => {
  it("finds exactly what a full scan finds inside a rectangle", () => {
    const want = places.filter((p) => p.x >= 200 && p.x <= 420 && p.y >= 610 && p.y <= 700).map((p) => p.id);
    expect(ids((v) => index.within(200, 610, 420, 700, v))).toEqual(want);
    expect(want.length).toBeGreaterThan(0);
  });
  it("finds exactly what a full scan finds near a point", () => {
    const want = places.filter((p) => Math.hypot(p.x - 500, p.y - 500) <= 90).map((p) => p.id);
    expect(ids((v) => index.near(500, 500, 90, v))).toEqual(want);
    expect(want.length).toBeGreaterThan(0);
  });
  it("copes with a view far larger than the world, and with nothing at all", () => {
    expect(ids((v) => index.within(-1e9, -1e9, 1e9, 1e9, v))).toHaveLength(500);
    expect(ids((v) => spatialIndex<{ id: number; x: number; y: number }>([]).near(0, 0, 1e9, v))).toEqual([]);
  });
  it("looks at a handful of cells, not the whole world", () => {
    let visited = 0;
    index.near(500, 500, 30, () => visited++);
    expect(visited).toBeLessThan(10);
    expect(index.size).toBe(500);
  });
});
