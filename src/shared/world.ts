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
 * land point nearest the world centre (Genesis village). Returns [id, x, y, region].
 */
export function computeSites(seed: number, count = 300, minGap = 38): [number, number, number, number][] {
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
  return chosen.map(([x, y], i) => [i + 1, Math.round(x * 10) / 10, Math.round(y * 10) / 10, regionOf(t, x, y)]);
}

/** Small deterministic hash → [0,1). */
export function hash01(a: number, b = 0): number {
  let h = Math.imul(a ^ 0x9e3779b9, 0x85ebca6b) ^ Math.imul(b + 0x632be5ab, 0xc2b2ae35);
  h ^= h >>> 13;
  h = Math.imul(h, 0x27d4eb2f);
  h ^= h >>> 15;
  return (h >>> 0) / 4294967296;
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

const JOB_BUILDING: Record<string, string> = { farmer: "farm", builder: "workshop", healer: "clinic" };

/**
 * Where an agent is during a given tick phase (0 morning, 1 afternoon, 2 evening, 3 night).
 * No coordinates are stored or sent: everyone derives the same answer.
 */
export function placeFor(
  a: { id: number; job: string; ageYears: number; home: number | null; settlement: number },
  phase: number,
  idx: BuildingIndex,
  fallback: { x: number; y: number },
): { x: number; y: number } {
  const home = (a.home != null && idx.byId.get(a.home)) || null;
  const civic = (kind: string) => idx.civic.get(`${a.settlement}:${kind}`) ?? null;
  let target: { x: number; y: number } | null = null;
  if (phase === 3) target = home;
  else if (phase === 2) {
    const r = hash01(a.id, 77);
    target = r < 0.5 ? home : r < 0.75 ? civic("market") : civic("temple");
  } else if (a.job === "child" && a.ageYears >= 6) target = civic("school");
  else if (JOB_BUILDING[a.job]) target = civic(JOB_BUILDING[a.job]);
  else if (a.job === "elder") target = phase === 0 ? civic("temple") : home;
  else target = home;
  const base = target ?? home ?? fallback;
  const ang = hash01(a.id, phase + 1) * Math.PI * 2;
  const rad = 0.6 + hash01(a.id, 99) * 2.4;
  return { x: base.x + Math.cos(ang) * rad, y: base.y + Math.sin(ang) * rad };
}
