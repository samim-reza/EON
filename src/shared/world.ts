/**
 * Procedural world geometry, deterministic from the world seed. Shared by the browser
 * (terrain rendering, agent positions) and the server (Genesis site selection).
 * World space is 1000 × 1000 units.
 */
import { createNoise2D } from "simplex-noise";
import { mulberry32 } from "./demography";
import type { BuildingTuple } from "./types";

export const WORLD_SIZE = 1000;
export const REGION_COUNT = 7;

export type Terrain = { elevation: (x: number, y: number) => number; regionCenters: [number, number][] };

export function makeTerrain(seed: number): Terrain {
  const rand = mulberry32(seed >>> 0);
  const n1 = createNoise2D(rand);
  const n2 = createNoise2D(rand);
  const regionCenters: [number, number][] = Array.from({ length: REGION_COUNT }, () => [150 + rand() * 700, 150 + rand() * 700]);
  const elevation = (x: number, y: number) => {
    const nx = x / WORLD_SIZE - 0.5;
    const ny = y / WORLD_SIZE - 0.5;
    const d = Math.sqrt(nx * nx + ny * ny) * 2; // 0 center → ~1.4 corners
    let e = 0;
    let amp = 1;
    let freq = 2.2;
    for (let o = 0; o < 5; o++) {
      e += amp * n1(nx * freq, ny * freq);
      amp *= 0.5;
      freq *= 2;
    }
    e = (e / 1.9) * 0.9 + 0.12 * n2(nx * 9, ny * 9);
    return e + 0.25 - d * d * 0.7; // continent falloff toward the edges (~30% land, ~7% of it mountains)
  };
  return { elevation, regionCenters };
}

export function regionOf(t: Terrain, x: number, y: number): number {
  let best = 0;
  let bd = Infinity;
  t.regionCenters.forEach(([cx, cy], i) => {
    const d = (cx - x) ** 2 + (cy - y) ** 2;
    if (d < bd) {
      bd = d;
      best = i;
    }
  });
  return best;
}

/**
 * Candidate settlement sites on land, at least `minGap` apart. The first site is the
 * land point nearest the world centre (Genesis village). Returns [id, x, y, region, elevation].
 */
export function computeSites(seed: number, count = 300, minGap = 38): [number, number, number, number, number][] {
  const t = makeTerrain(seed);
  const rand = mulberry32((seed ^ 0x5eed) >>> 0);
  const cand: [number, number][] = [];
  for (let i = 0; i < 6000 && cand.length < count * 3; i++) {
    const x = 40 + rand() * (WORLD_SIZE - 80);
    const y = 40 + rand() * (WORLD_SIZE - 80);
    const e = t.elevation(x, y);
    if (e > 0.06 && e < 0.55) cand.push([x, y]);
  }
  cand.sort((a, b) => (a[0] - 500) ** 2 + (a[1] - 500) ** 2 - ((b[0] - 500) ** 2 + (b[1] - 500) ** 2));
  const chosen: [number, number][] = [];
  for (const c of cand) {
    if (chosen.every(([x, y]) => (x - c[0]) ** 2 + (y - c[1]) ** 2 >= minGap * minGap)) chosen.push(c);
    if (chosen.length >= count) break;
  }
  return chosen.map(([x, y], i) => {
    const sx = Math.round(x * 10) / 10;
    const sy = Math.round(y * 10) / 10;
    return [i + 1, sx, sy, regionOf(t, x, y), Math.round(t.elevation(sx, sy) * 1e4) / 1e4];
  });
}

/** Small deterministic hash → [0,1). */
export function hash01(a: number, b = 0): number {
  let h = Math.imul(a ^ 0x9e3779b9, 0x85ebca6b) ^ Math.imul(b + 0x632be5ab, 0xc2b2ae35);
  h ^= h >>> 13;
  h = Math.imul(h, 0x27d4eb2f);
  h ^= h >>> 15;
  return (h >>> 0) / 4294967296;
}

/** Buildings are placed around a village by the database, which can't see the coast. Keep them on land. */
export function settleOnLand(buildings: BuildingTuple[], settlements: { id: number; x: number; y: number }[], terrain: Terrain): BuildingTuple[] {
  const centres = new Map(settlements.map((s) => [s.id, s]));
  return buildings.map((b) => {
    const [id, settlement, kind, x, y] = b;
    const centre = centres.get(settlement);
    if (!centre) return b;
    let k = 1;
    while (k > 0 && terrain.elevation(centre.x + (x - centre.x) * k, centre.y + (y - centre.y) * k) < 0.02) k -= 0.1;
    return [id, settlement, kind, centre.x + (x - centre.x) * Math.max(0, k), centre.y + (y - centre.y) * Math.max(0, k)];
  });
}

export type BuildingIndex = {
  byId: Map<number, { x: number; y: number; kind: string; settlement: number }>;
  civic: Map<string, { x: number; y: number }>; // key `${settlement}:${kind}`
};

export function indexBuildings(buildings: BuildingTuple[]): BuildingIndex {
  const byId = new Map<number, { x: number; y: number; kind: string; settlement: number }>();
  const civic = new Map<string, { x: number; y: number }>();
  for (const [id, settlement, kind, x, y] of buildings) {
    byId.set(id, { x, y, kind, settlement });
    if (kind !== "home") civic.set(`${settlement}:${kind}`, { x, y });
  }
  return { byId, civic };
}
