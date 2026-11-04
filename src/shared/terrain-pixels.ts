import { createNoise2D } from "simplex-noise";
import { hash3, latitudeOf, smooth } from "./climate";
import { mulberry32 } from "./demography";
import { lakeAt, makeWaters, makeWetness, type Waters } from "./rivers";
import { makeTerrain, WORLD_SIZE } from "./world";

type Rgb = [number, number, number];

/** One square of detail for close zoom: what a web map calls a tile. */
export const TILE_UNITS = 125;
export const TILE_PX = 640;

/** Colours by climate. Blending between them, instead of painting biomes, leaves no hard edges. */
const CLIMATE_TEMPS = [-15, -4, 6, 16, 26];
const CLIMATE_COLOURS: Rgb[][] = [
  // dry ───────────────────────────────────────────────────► wet
  [[226, 232, 238], [228, 234, 240], [230, 236, 242], [232, 238, 244], [234, 240, 246]], // polar ice
  [[166, 158, 132], [146, 146, 116], [122, 132, 100], [98, 120, 94], [84, 110, 90]], // tundra
  [[184, 166, 120], [152, 152, 92], [84, 118, 68], [42, 86, 60], [32, 76, 58]], // steppe to pine forest
  [[212, 182, 124], [176, 164, 94], [110, 142, 70], [48, 106, 56], [30, 90, 56]], // cool desert to forest
  [[226, 194, 134], [196, 172, 94], [132, 148, 62], [50, 114, 52], [20, 88, 46]], // hot desert to jungle
];

const SAND: Rgb = [214, 198, 152];
const ROCK: Rgb = [112, 106, 98];
const SCREE: Rgb = [152, 148, 144];
const SNOW: Rgb = [240, 244, 250];
const LAKE: Rgb = [30, 88, 122];
const LAKE_ICE: Rgb = [196, 216, 228];
const RIVER: Rgb = [38, 98, 130];
const BANK: Rgb = [62, 110, 56];

const WATER: [number, Rgb][] = [
  [-0.5, [8, 22, 46]],
  [-0.2, [12, 42, 78]],
  [-0.05, [22, 80, 114]],
  [-0.008, [52, 126, 138]],
  [0, [70, 142, 146]],
];

const blend = (a: Rgb, b: Rgb, t: number): Rgb => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];

function waterColour(e: number): Rgb {
  if (e <= WATER[0][0]) return WATER[0][1];
  for (let i = 1; i < WATER.length; i++) {
    if (e <= WATER[i][0]) return blend(WATER[i - 1][1], WATER[i][1], (e - WATER[i - 1][0]) / (WATER[i][0] - WATER[i - 1][0]));
  }
  return WATER[WATER.length - 1][1];
}

function climateColour(temp: number, wet: number): Rgb {
  let row = 0;
  while (row < CLIMATE_TEMPS.length - 2 && temp > CLIMATE_TEMPS[row + 1]) row++;
  const rowT = Math.max(0, Math.min(1, (temp - CLIMATE_TEMPS[row]) / (CLIMATE_TEMPS[row + 1] - CLIMATE_TEMPS[row])));
  const position = Math.max(0, Math.min(3.999, wet * 4));
  const col = Math.floor(position);
  const colT = position - col;
  return blend(blend(CLIMATE_COLOURS[row][col], CLIMATE_COLOURS[row][col + 1], colT), blend(CLIMATE_COLOURS[row + 1][col], CLIMATE_COLOURS[row + 1][col + 1], colT), rowT);
}

/** Average temperature with the same maths as `climateAt`, with no noise lookups: it runs per pixel. */
function meanTemp(lat: number, e: number) {
  return 27.5 - 0.0072 * lat * lat - 30 * Math.max(0, e - 0.1) ** 1.3;
}

function makeSampler(seed: number) {
  const { elevation } = makeTerrain(seed);
  const detail = createNoise2D(mulberry32((seed ^ 0xd37a11) >>> 0));
  const wetAt = makeWetness(seed);
  return { elevation, detail, wetAt, waters: makeWaters(seed, elevation, wetAt) };
}
type Sampler = ReturnType<typeof makeSampler>;

function surface(s: Sampler, wx: number, wy: number, e: number): Rgb {
  if (e <= 0) {
    // The sea deepens towards the edge of the map, so it meets the open ocean with no visible seam.
    const edge = Math.min(wx, wy, WORLD_SIZE - wx, WORLD_SIZE - wy);
    return edge < 80 ? blend(WATER[0][1], waterColour(e), Math.max(0, edge) / 80) : waterColour(e);
  }
  const lat = latitudeOf(wy);
  const temp = meanTemp(lat, e) + 3 * s.detail(wx / 41, wy / 41);
  const wet = s.wetAt(wx, wy) + 0.07 * s.detail(wx / 23 + 9, wy / 23);
  let c = climateColour(temp, wet);
  const lake = lakeAt(s.waters, wx, wy) + 0.0012 * s.detail(wx / 3.1, wy / 3.1);
  if (lake > 0.0014) return blend(c, temp < -2 ? LAKE_ICE : LAKE, smooth(0.0014, 0.0034, lake));
  if (e < 0.018 && temp > 2) c = blend(c, SAND, smooth(0.018, 0.005, e));
  if (e > 0.42) c = blend(c, blend(ROCK, SCREE, smooth(0.56, 0.72, e)), smooth(0.42, 0.56, e));
  return blend(c, SNOW, smooth(-1, -6, temp));
}

/** Writes shaded terrain into `data`. `grid` holds elevation with `pad` extra cells on every side. */
function paint(s: Sampler, data: Uint8ClampedArray, grid: Float32Array, size: number, pad: number, step: number, x0: number, y0: number, res: number, strength: number) {
  const full = size + pad * 2;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const e = grid[(y + pad) * full + x + pad];
      const [r, g, b] = surface(s, x0 + x * res, y0 + y * res, e);
      const light = grid[(y + pad - step) * full + x + pad - step];
      // light comes from the north-west
      const shade = e > 0 ? 1 + Math.max(-0.3, Math.min(0.3, (e - light) * strength)) : 1;
      const i = (y * size + x) * 4;
      data[i] = r * shade;
      data[i + 1] = g * shade;
      data[i + 2] = b * shade;
      data[i + 3] = 255;
    }
  }
}

/**
 * The whole map, computed from the seed alone. `res` is world units per pixel. Elevation is sampled
 * once per pixel into a grid and hill-shading reads the neighbours from it, which is half the noise
 * evaluations of sampling a second point for every pixel.
 *
 * `snow` and `autumn` are transparent layers drawn over the map as the year turns: crossfading two
 * images costs far less per frame than recolouring the land.
 */
export function terrainPixels(seed: number, res: number) {
  const s = samplerFor(seed);
  const size = Math.round(WORLD_SIZE / res);
  const step = Math.max(1, Math.round(2 / res));
  const full = size + step * 2;
  const grid = new Float32Array(full * full);
  for (let y = 0; y < full; y++) {
    for (let x = 0; x < full; x++) {
      const wx = (x - step) * res;
      const wy = (y - step) * res;
      const e = s.elevation(wx, wy);
      // Fine texture for the eye only: settlement sites are chosen from `elevation` alone.
      grid[y * full + x] = e > 0.01 ? e + 0.022 * s.detail(wx / 16, wy / 16) + 0.012 * s.detail(wx / 6, wy / 6) : e;
    }
  }
  const data = new Uint8ClampedArray(size * size * 4);
  paint(s, data, grid, size, step, step, 0, 0, res, 7);
  strokeWaters(s.waters, data, grid, step, size, 0, 0, 1 / res, "bank");
  strokeWaters(s.waters, data, grid, step, size, 0, 0, 1 / res, "water");

  const layerSize = Math.round(WORLD_SIZE / 2);
  const snow = new Uint8ClampedArray(layerSize * layerSize * 4);
  const autumn = new Uint8ClampedArray(layerSize * layerSize * 4);
  for (let y = 0; y < layerSize; y++) {
    for (let x = 0; x < layerSize; x++) {
      const wx = x * 2;
      const wy = y * 2;
      const gx = Math.min(full - 1, Math.round(wx / res) + step);
      const gy = Math.min(full - 1, Math.round(wy / res) + step);
      const e = grid[gy * full + gx];
      const lat = latitudeOf(wy);
      const wet = s.wetAt(wx, wy);
      const temp = meanTemp(lat, e);
      const winter = temp - (1 + 0.26 * Math.abs(lat) + 2 * (1 - wet));
      const i = (y * layerSize + x) * 4;
      const edge = Math.min(wx, wy, WORLD_SIZE - wx, WORLD_SIZE - wy); // sea ice thins out before the edge of the map
      const whiteness = e > 0 ? smooth(6, -4, winter + 2 * s.detail(wx / 19, wy / 19)) : smooth(-5, -13, winter) * smooth(0, 90, edge); // the sea freezes much later than land
      snow[i] = 236;
      snow[i + 1] = 241;
      snow[i + 2] = 249;
      snow[i + 3] = 235 * whiteness;
      if (e > 0 && e < 0.5) {
        const leaves = smooth(2, 6, temp) * smooth(19, 15, temp) * smooth(0.32, 0.45, wet) * smooth(0.95, 0.75, wet);
        const hue = (s.detail(wx / 14, wy / 14) + 1) / 2;
        autumn[i] = 176 + 30 * hue;
        autumn[i + 1] = 110 - 44 * hue;
        autumn[i + 2] = 38;
        autumn[i + 3] = 170 * leaves;
      }
    }
  }
  return { size, data, layerSize, snow, autumn };
}

/** Paints the river network: first a green margin, then later the water itself, so trees sit between. */
function strokeWaters(w: Waters, data: Uint8ClampedArray, grid: Float32Array, pad: number, size: number, x0: number, y0: number, perUnit: number, pass: "bank" | "water") {
  const x1 = x0 + size / perUnit;
  const y1 = y0 + size / perUnit;
  const margin = 5;
  const colour = pass === "bank" ? BANK : RIVER;
  for (let i = 0; i < w.segmentCount; i++) {
    const s = i * 7;
    const ax = w.segments[s];
    const ay = w.segments[s + 1];
    const cx = w.segments[s + 2];
    const cy = w.segments[s + 3];
    const bx = w.segments[s + 4];
    const by = w.segments[s + 5];
    if (Math.max(ax, bx, cx) < x0 - margin || Math.min(ax, bx, cx) > x1 + margin || Math.max(ay, by, cy) < y0 - margin || Math.min(ay, by, cy) > y1 + margin) continue;
    const width = w.segments[s + 6];
    const radius = Math.max(0.62, (pass === "bank" ? width * 0.5 + 1.5 : width * 0.5) * perUnit);
    const steps = Math.max(2, Math.ceil(((Math.hypot(cx - ax, cy - ay) + Math.hypot(bx - cx, by - cy)) * perUnit) / Math.max(1, radius)));
    for (let k = 0; k <= steps; k++) {
      const t = k / steps;
      const u = 1 - t;
      const px = (u * u * ax + 2 * u * t * cx + t * t * bx - x0) * perUnit;
      const py = (u * u * ay + 2 * u * t * cy + t * t * by - y0) * perUnit;
      const left = Math.max(0, Math.floor(px - radius - 1));
      const right = Math.min(size - 1, Math.ceil(px + radius + 1));
      const top = Math.max(0, Math.floor(py - radius - 1));
      const bottom = Math.min(size - 1, Math.ceil(py + radius + 1));
      for (let y = top; y <= bottom; y++) {
        for (let x = left; x <= right; x++) {
          const d = Math.hypot(x - px, y - py);
          const cover = pass === "bank" ? 0.12 * (1 - d / radius) : Math.min(1, radius + 0.5 - d);
          if (cover <= 0 || grid[(y + pad) * (size + pad * 2) + x + pad] <= 0) continue; // a river ends where the sea begins
          const j = (y * size + x) * 4;
          data[j] += (colour[0] - data[j]) * cover;
          data[j + 1] += (colour[1] - data[j + 1]) * cover;
          data[j + 2] += (colour[2] - data[j + 2]) * cover;
        }
      }
    }
  }
}

const samplers = new Map<number, Sampler>();

function samplerFor(seed: number) {
  let s = samplers.get(seed);
  if (!s) {
    s = makeSampler(seed);
    samplers.clear();
    samplers.set(seed, s);
  }
  return s;
}

/** The tide mask matches the tile, but only the band between low and high water is ever touched. */
export const TIDE_PX = TILE_PX;
/** How far sea level moves, in elevation units, at the height of a spring tide. */
export const TIDE_RANGE = 0.014;

/** Places a shaded disc in the tile: a tree crown, a bush or a boulder. */
function stamp(data: Uint8ClampedArray, cx: number, cy: number, radius: number, colour: Rgb) {
  const top = Math.max(0, Math.floor(cy - radius - 2));
  const bottom = Math.min(TILE_PX - 1, Math.ceil(cy + radius + 2));
  const left = Math.max(0, Math.floor(cx - radius - 2));
  const right = Math.min(TILE_PX - 1, Math.ceil(cx + radius + 2));
  for (let y = top; y <= bottom; y++) {
    for (let x = left; x <= right; x++) {
      const i = (y * TILE_PX + x) * 4;
      const dx = x - cx;
      const dy = y - cy;
      // cast shadow, to the south-east
      if ((dx - 1.3) ** 2 + (dy - 1.3) ** 2 <= radius * radius) {
        data[i] *= 0.72;
        data[i + 1] *= 0.72;
        data[i + 2] *= 0.74;
      }
      if (dx * dx + dy * dy <= radius * radius) {
        const lit = 1 + (-dx - dy) / (radius * 3.4);
        data[i] = colour[0] * lit;
        data[i + 1] = colour[1] * lit;
        data[i + 2] = colour[2] * lit;
      }
    }
  }
}

/**
 * One square of close-up terrain with its plants and rocks. Tiles exist only for what someone is
 * looking at, so the world can be sharp at any zoom without building a huge image up front.
 */
export function terrainTile(seed: number, tileX: number, tileY: number) {
  const s = samplerFor(seed);
  const res = TILE_UNITS / TILE_PX;
  const x0 = tileX * TILE_UNITS;
  const y0 = tileY * TILE_UNITS;
  const pad = 3;
  const full = TILE_PX + pad * 2;
  const grid = new Float32Array(full * full);
  for (let y = 0; y < full; y++) {
    for (let x = 0; x < full; x++) {
      const wx = x0 + (x - pad) * res;
      const wy = y0 + (y - pad) * res;
      const e = s.elevation(wx, wy);
      grid[y * full + x] = e > 0.01 ? e + 0.022 * s.detail(wx / 16, wy / 16) + 0.012 * s.detail(wx / 6, wy / 6) + 0.005 * s.detail(wx / 1.9, wy / 1.9) : e;
    }
  }
  const data = new Uint8ClampedArray(TILE_PX * TILE_PX * 4);
  paint(s, data, grid, TILE_PX, pad, pad, x0, y0, res, 13);
  strokeWaters(s.waters, data, grid, pad, TILE_PX, x0, y0, 1 / res, "bank");

  // Plants grow on a jittered grid: even coverage with no visible rows.
  const cell = 1.25;
  const firstX = Math.floor(x0 / cell) - 1;
  const firstY = Math.floor(y0 / cell) - 1;
  const cells = Math.ceil(TILE_UNITS / cell) + 3;
  const pixelsPerUnit = 1 / res;
  for (let j = 0; j < cells; j++) {
    for (let i = 0; i < cells; i++) {
      const cx = firstX + i;
      const cy = firstY + j;
      const chance = hash3(seed ^ 0x3a7c1d, cx, cy, 0);
      if (chance > 0.92) continue;
      const wx = (cx + hash3(seed ^ 0x3a7c1d, cx, cy, 1)) * cell;
      const wy = (cy + hash3(seed ^ 0x3a7c1d, cx, cy, 2)) * cell;
      const px = (wx - x0) * pixelsPerUnit;
      const py = (wy - y0) * pixelsPerUnit;
      const gx = Math.round(px) + pad;
      const gy = Math.round(py) + pad;
      if (gx < 0 || gy < 0 || gx >= full || gy >= full) continue;
      const e = grid[gy * full + gx];
      if (e < 0.018 || e > 0.56 || lakeAt(s.waters, wx, wy) > 0.001) continue;
      const temp = meanTemp(latitudeOf(wy), e);
      const wet = s.wetAt(wx, wy);
      const size = hash3(seed ^ 0x3a7c1d, cx, cy, 3);
      if (temp < -3) continue;
      if (wet > 0.42 && chance < smooth(0.42, 0.66, wet) * smooth(-3, 3, temp) * 0.92) {
        const pine = temp < 7;
        const green: Rgb = pine ? [24 + 12 * size, 58 + 14 * size, 48] : temp > 20 ? [22 + 24 * size, 88 + 26 * size, 40] : [38 + 26 * size, 92 + 24 * size, 46];
        stamp(data, px, py, (pine ? 1.9 : 2.2) + size * (pine ? 0.9 : 1.5), green);
      } else if (wet > 0.28 && chance < 0.1) {
        stamp(data, px, py, 1.5 + size * 1.1, [78 + 30 * size, 104 + 18 * size, 52]); // bushes and acacia
      } else if (wet <= 0.28 && chance < 0.025) {
        stamp(data, px, py, 1.1 + size * 1.2, [128 + 30 * size, 108 + 18 * size, 84]); // desert boulders
      }
    }
  }
  strokeWaters(s.waters, data, grid, pad, TILE_PX, x0, y0, 1 / res, "water");

  // Ground the tide can reach: 0 elsewhere, otherwise height within the band, as 1–255.
  const tide = new Uint8Array(TIDE_PX * TIDE_PX);
  for (let y = 0; y < TIDE_PX; y++) {
    for (let x = 0; x < TIDE_PX; x++) {
      const e = grid[(y + pad) * full + x + pad];
      if (Math.abs(e) < TIDE_RANGE) tide[y * TIDE_PX + x] = 1 + Math.round(((e + TIDE_RANGE) / (2 * TIDE_RANGE)) * 254);
    }
  }
  return { data, tide };
}
