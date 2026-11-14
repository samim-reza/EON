import { describe, expect, it } from "vitest";
import { BIRD, GRAZER, groveOf, HERD, HUNTER } from "@/shared/nature";
import { createDotBatch, createSmokeBatch, createWildlifeBatch, drawGroves, packGrove, type GroveView } from "./scenery";

/** A stand-in canvas that counts the calls that cost something. */
function canvas() {
  const calls = { fill: 0, stroke: 0, shapes: 0 };
  const shape = () => { calls.shapes++; };
  const ctx = {
    beginPath() {}, moveTo() {}, lineTo() {}, closePath() {}, arc: shape, ellipse: shape,
    fill() { calls.fill++; }, stroke() { calls.stroke++; },
    fillStyle: "", strokeStyle: "", lineWidth: 1, lineCap: "butt", globalAlpha: 1,
  } as unknown as CanvasRenderingContext2D;
  return { ctx, calls };
}

const same = (v: number) => v;
const everywhere = { x0: -1e9, y0: -1e9, x1: 1e9, y1: 1e9 };

describe("drawing in batches", () => {
  it("draws any number of animals in a handful of canvas calls", () => {
    const few = canvas();
    const many = canvas();
    for (const [target, n] of [[few, 10], [many, 5000]] as const) {
      const batch = createWildlifeBatch();
      for (let i = 0; i < n; i++) batch.add([GRAZER, HUNTER, HERD, BIRD][i % 4], i, i, i);
      expect(batch.total).toBe(n);
      batch.draw(target.ctx, 3);
    }
    expect(many.calls.fill + many.calls.stroke).toBe(few.calls.fill + few.calls.stroke);
    expect(many.calls.fill + many.calls.stroke).toBeLessThanOrEqual(8);
    expect(many.calls.shapes).toBeGreaterThan(5000); // and every animal is still there
  });

  it("forgets the last frame's animals when reset", () => {
    const { ctx, calls } = canvas();
    const batch = createWildlifeBatch();
    batch.add(GRAZER, 1, 1, 0);
    batch.reset();
    batch.draw(ctx, 3);
    expect(batch.total).toBe(0);
    expect(calls.fill + calls.stroke).toBe(0);
  });

  it("draws every wood on screen in a fixed number of calls", () => {
    const view = (id: number, biome: string): GroveView => ({
      grove: packGrove(groveOf({ id, x: 500 + id, y: 500 }, 0.6, biome, () => true)), autumn: 0.5, bare: 0.2, charred: id % 2 === 0,
    });
    const one = canvas();
    const hundred = canvas();
    drawGroves(one.ctx, [view(1, "forest")], 1, same, same, 6, everywhere);
    const views = Array.from({ length: 100 }, (_, i) => view(i + 1, ["forest", "taiga", "desert", "grassland"][i % 4]));
    drawGroves(hundred.ctx, views, views.length, same, same, 6, everywhere);
    expect(hundred.calls.fill + hundred.calls.stroke).toBeLessThanOrEqual(16);
    expect(hundred.calls.shapes).toBeGreaterThan(one.calls.shapes * 20);
  });

  it("skips woods that are off screen", () => {
    const { ctx, calls } = canvas();
    const grove = packGrove(groveOf({ id: 1, x: 500, y: 500 }, 0.8, "forest", () => true));
    drawGroves(ctx, [{ grove, autumn: 0, bare: 0, charred: false }], 1, same, same, 6, { x0: 0, y0: 0, x1: 100, y1: 100 });
    expect(calls.shapes).toBe(0);
  });

  it("draws a whole town of people in nine fills at most", () => {
    const { ctx, calls } = canvas();
    const dots = createDotBatch();
    for (let i = 0; i < 2000; i++) dots.add(i, i, 2, i % 3, (i >> 2) % 3, (i % 5) - 1);
    dots.draw(ctx);
    expect(calls.fill).toBeLessThanOrEqual(9);
    expect(calls.stroke).toBeLessThanOrEqual(12);
    expect(calls.shapes).toBe(2000 + 2000 * 4 / 5);
    expect(ctx.globalAlpha).toBe(1);
  });

  it("draws every chimney's smoke in four fills", () => {
    const { ctx, calls } = canvas();
    const smoke = createSmokeBatch();
    for (let i = 0; i < 300; i++) smoke.add(i, i, i * 913);
    smoke.draw(ctx, 3, 12345, 0.7);
    expect(calls.fill).toBe(4);
    expect(calls.shapes).toBe(300 * 4);
  });
});
