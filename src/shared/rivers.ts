/**
 * Rivers and lakes, worked out from the terrain the way water finds them. Rain falls on every cell
 * and runs downhill to the sea; where a lot of it gathers there is a river, and where a basin has to
 * fill before it can spill over there is a lake. Like the land, this is derived from the seed.
 */
import { hash3, wetnessAt } from "./climate";
import { computeSites, makeTerrain, WORLD_SIZE } from "./world";

export const RIVER_CELL = 2; // world units per drainage cell
const N = WORLD_SIZE / RIVER_CELL;
const RIVER_FLOW = 90; // runoff needed before a stream is worth drawing
const LAKE_DEPTH = 0.0035; // shallower puddles in the terrain stay dry land

/** Wetness read from a coarse grid: it costs 16 hashes a sample but changes slowly. */
export function makeWetness(seed: number) {
  const cell = 8;
  const n = Math.ceil(WORLD_SIZE / cell) + 2;
  const grid = new Float32Array(n * n);
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) grid[y * n + x] = wetnessAt(seed, x * cell, y * cell);
  return (x: number, y: number) => {
    const gx = Math.max(0, Math.min(n - 1.001, x / cell));
    const gy = Math.max(0, Math.min(n - 1.001, y / cell));
    const x0 = Math.floor(gx);
    const y0 = Math.floor(gy);
    const fx = gx - x0;
    const fy = gy - y0;
    const top = grid[y0 * n + x0] * (1 - fx) + grid[y0 * n + x0 + 1] * fx;
    const bottom = grid[(y0 + 1) * n + x0] * (1 - fx) + grid[(y0 + 1) * n + x0 + 1] * fx;
    return top * (1 - fy) + bottom * fy;
  };
}

/** A binary heap over typed arrays: the lowest cell on the shore comes out first. */
class Lowest {
  private keys = new Float32Array(N * N);
  private cells = new Int32Array(N * N);
  size = 0;

  push(key: number, cell: number) {
    let i = this.size++;
    while (i > 0) {
      const parent = (i - 1) >> 1;
      if (this.keys[parent] <= key) break;
      this.keys[i] = this.keys[parent];
      this.cells[i] = this.cells[parent];
      i = parent;
    }
    this.keys[i] = key;
    this.cells[i] = cell;
  }

  /** Removes the lowest cell. Read `topKey` first if you need its height. */
  pop() {
    const top = this.cells[0];
    this.topKey = this.keys[0];
    const key = this.keys[--this.size];
    const cell = this.cells[this.size];
    let i = 0;
    for (;;) {
      let child = 2 * i + 1;
      if (child >= this.size) break;
      if (child + 1 < this.size && this.keys[child + 1] < this.keys[child]) child++;
      if (this.keys[child] >= key) break;
      this.keys[i] = this.keys[child];
      this.cells[i] = this.cells[child];
      i = child;
    }
    this.keys[i] = key;
    this.cells[i] = cell;
    return top;
  }

  topKey = 0;
}

export type Waters = {
  /** Runoff gathered in each cell. */
  flow: Float32Array;
  /** Depth of lake water over the ground in each cell. */
  lake: Float32Array;
  /** Where each cell drains to, or -1 for the sea. */
  next: Int32Array;
  /** Curved river pieces, 7 numbers each: start, control point, end, width in world units. */
  segments: Float32Array;
  segmentCount: number;
};

/**
 * Priority flood: the sea rises inland from the coast, always spilling into the lowest unvisited
 * cell. The order water reaches each cell is the reverse of the way it drains, so every drop finds
 * the sea, with no search. It takes O(n log n), and any basin it has to fill becomes a lake.
 */
export function makeWaters(seed: number, elevation: (x: number, y: number) => number, wetAt: (x: number, y: number) => number): Waters {
  const size = N * N;
  const height = new Float32Array(size);
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) height[y * N + x] = elevation((x + 0.5) * RIVER_CELL, (y + 0.5) * RIVER_CELL);

  const filled = new Float32Array(size);
  const next = new Int32Array(size).fill(-1);
  const seen = new Uint8Array(size);
  const order = new Int32Array(size);
  const shore = new Lowest();
  const around = [-N - 1, -N, -N + 1, -1, 1, N - 1, N, N + 1];
  const neighbours = (c: number, visit: (n: number) => void) => {
    const x = c % N;
    for (let k = 0; k < 8; k++) {
      const dx = k === 0 || k === 3 || k === 5 ? -1 : k === 2 || k === 4 || k === 7 ? 1 : 0;
      const n = c + around[k];
      if (n >= 0 && n < size && x + dx >= 0 && x + dx < N) visit(n);
    }
  };
  for (let c = 0; c < size; c++) {
    if (height[c] > 0) continue;
    seen[c] = 1;
    filled[c] = height[c];
  }
  for (let c = 0; c < size; c++) {
    const edge = c < N || c >= size - N || c % N === 0 || c % N === N - 1;
    if (seen[c] ? false : edge) {
      seen[c] = 1;
      filled[c] = height[c];
      shore.push(height[c], c);
    }
  }
  for (let c = 0; c < size; c++) {
    if (height[c] > 0) continue;
    let coastal = false;
    neighbours(c, (n) => {
      if (height[n] > 0) coastal = true;
    });
    if (coastal) shore.push(height[c], c);
  }
  let count = 0;
  while (shore.size) {
    const c = shore.pop();
    const level = shore.topKey;
    if (height[c] > 0) order[count++] = c;
    neighbours(c, (n) => {
      if (seen[n]) return;
      seen[n] = 1;
      filled[n] = Math.max(height[n], level + 1e-5);
      next[n] = c;
      shore.push(filled[n], n);
    });
  }

  const flow = new Float32Array(size);
  const upstream = new Int32Array(size).fill(-1);
  for (let i = count - 1; i >= 0; i--) {
    const c = order[i];
    const wet = wetAt(((c % N) + 0.5) * RIVER_CELL, (Math.floor(c / N) + 0.5) * RIVER_CELL);
    flow[c] += 0.05 + wet * wet * 1.6; // deserts add almost nothing, but a river can still cross them
    const to = next[c];
    if (to >= 0) {
      flow[to] += flow[c];
      if (upstream[to] < 0 || flow[c] > flow[upstream[to]]) upstream[to] = c;
    }
  }

  const lake = new Float32Array(size);
  for (let c = 0; c < size; c++) {
    const depth = filled[c] - height[c];
    if (height[c] > 0 && depth > LAKE_DEPTH) lake[c] = depth;
  }

  const px = (c: number) => ((c % N) + 0.5 + (hash3(seed ^ 0x6c1e0b, c, 0, 0) - 0.5) * 0.8) * RIVER_CELL;
  const py = (c: number) => (Math.floor(c / N) + 0.5 + (hash3(seed ^ 0x6c1e0b, c, 1, 0) - 0.5) * 0.8) * RIVER_CELL;
  const segments = new Float32Array(size > 0 ? 7 * 60000 : 0);
  let segmentCount = 0;
  for (let i = 0; i < count && segmentCount < 60000; i++) {
    const c = order[i];
    if (flow[c] < RIVER_FLOW || lake[c] > 0) continue;
    const to = next[c];
    if (to < 0) continue;
    const up = upstream[c] >= 0 && flow[upstream[c]] >= RIVER_FLOW ? upstream[c] : -1;
    const cx = px(c);
    const cy = py(c);
    const s = segmentCount++ * 7;
    segments[s] = up >= 0 ? (px(up) + cx) / 2 : cx;
    segments[s + 1] = up >= 0 ? (py(up) + cy) / 2 : cy;
    segments[s + 2] = cx;
    segments[s + 3] = cy;
    const seaward = next[to] < 0 && height[to] <= 0;
    segments[s + 4] = seaward ? px(to) : (cx + px(to)) / 2;
    segments[s + 5] = seaward ? py(to) : (cy + py(to)) / 2;
    segments[s + 6] = Math.min(2.6, 0.2 + 0.024 * Math.sqrt(flow[c]));
  }
  return { flow, lake, next, segments, segmentCount };
}

/** Depth of lake water at a point. */
export function lakeAt(w: Waters, x: number, y: number) {
  const gx = Math.max(0, Math.min(N - 1.001, x / RIVER_CELL - 0.5));
  const gy = Math.max(0, Math.min(N - 1.001, y / RIVER_CELL - 0.5));
  const x0 = Math.floor(gx);
  const y0 = Math.floor(gy);
  const fx = gx - x0;
  const fy = gy - y0;
  const c = y0 * N + x0;
  return (w.lake[c] * (1 - fx) + w.lake[c + 1] * fx) * (1 - fy) + (w.lake[c + N] * (1 - fx) + w.lake[c + N + 1] * fx) * fy;
}

/** How much river there is near a point: 0 for none, 1 beside the greatest rivers. */
export function riverNear(w: Waters, x: number, y: number, reach = 14) {
  const cells = Math.ceil(reach / RIVER_CELL);
  const cx = Math.floor(x / RIVER_CELL);
  const cy = Math.floor(y / RIVER_CELL);
  let most = 0;
  for (let j = -cells; j <= cells; j++) {
    for (let i = -cells; i <= cells; i++) {
      if (i * i + j * j > cells * cells) continue;
      const gx = cx + i;
      const gy = cy + j;
      if (gx >= 0 && gy >= 0 && gx < N && gy < N) most = Math.max(most, w.flow[gy * N + gx]);
    }
  }
  return most < RIVER_FLOW ? 0 : Math.min(1, 0.3 + (0.7 * Math.log(most / RIVER_FLOW)) / Math.log(200));
}

/** Within reach of open water, as far as a day's walk goes. */
export function isCoastal(elevation: (x: number, y: number) => number, x: number, y: number) {
  for (const radius of [10, 20, 30]) {
    for (let k = 0; k < 12; k++) {
      const angle = (k / 12) * Math.PI * 2;
      if (elevation(x + Math.cos(angle) * radius, y + Math.sin(angle) * radius) <= 0) return true;
    }
  }
  return false;
}

/** Settlement sites with everything the simulation needs to know about their land and water. */
export function sitesWithWater(seed: number): [number, number, number, number, number, number, boolean][] {
  const { elevation } = makeTerrain(seed);
  const waters = makeWaters(seed, elevation, makeWetness(seed));
  return computeSites(seed).map(([id, x, y, region, elev]) => [id, x, y, region, elev, Math.round(riverNear(waters, x, y) * 1000) / 1000, isCoastal(elevation, x, y)]);
}
