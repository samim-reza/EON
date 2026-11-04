import { createNoise2D } from "simplex-noise";
import { mulberry32 } from "./demography";
import { makeTerrain, WORLD_SIZE } from "./world";

type Rgb = [number, number, number];

const RAMP: [number, Rgb][] = [
  [-0.6, [8, 16, 34]],
  [-0.2, [12, 30, 58]],
  [-0.02, [22, 52, 86]],
  [0.0, [74, 84, 72]],
  [0.05, [44, 78, 52]],
  [0.22, [34, 68, 44]],
  [0.4, [30, 56, 40]],
  [0.52, [66, 70, 60]],
  [0.65, [96, 98, 100]],
  [0.8, [150, 156, 162]],
];

function terrainColor(e: number): Rgb {
  if (e <= RAMP[0][0]) return RAMP[0][1];
  for (let i = 1; i < RAMP.length; i++) {
    const [e1, c1] = RAMP[i];
    if (e <= e1) {
      const [e0, c0] = RAMP[i - 1];
      const t = (e - e0) / (e1 - e0);
      return [c0[0] + (c1[0] - c0[0]) * t, c0[1] + (c1[1] - c0[1]) * t, c0[2] + (c1[2] - c0[2]) * t];
    }
  }
  return RAMP[RAMP.length - 1][1];
}

/**
 * RGBA pixels of the whole map, computed from the seed alone. `res` is world units per pixel.
 * Elevation is sampled once per pixel into a grid and hill-shading reads the neighbours from it,
 * which is half the noise evaluations of sampling a second point for every pixel.
 */
export function terrainPixels(seed: number, res: number) {
  const size = Math.round(WORLD_SIZE / res);
  const { elevation } = makeTerrain(seed);
  const detail = createNoise2D(mulberry32((seed ^ 0xd37a11) >>> 0));
  const grid = new Float32Array(size * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const wx = x * res;
      const wy = y * res;
      const e = elevation(wx, wy);
      // Fine texture for the eye only: settlement sites are chosen from `elevation` alone.
      grid[y * size + x] = e > 0.01 ? e + 0.022 * detail(wx / 16, wy / 16) + 0.012 * detail(wx / 6, wy / 6) : e;
    }
  }
  const step = Math.max(1, Math.round(2 / res));
  const data = new Uint8ClampedArray(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const e = grid[y * size + x];
      const [r, g, b] = terrainColor(e);
      const light = grid[Math.max(0, y - step) * size + Math.max(0, x - step)];
      // light comes from the north-west
      const shade = e > 0 ? 1 + Math.max(-0.18, Math.min(0.18, (e - light) * 6)) : 1;
      const i = (y * size + x) * 4;
      data[i] = r * shade;
      data[i + 1] = g * shade;
      data[i + 2] = b * shade;
      data[i + 3] = 255;
    }
  }
  return { size, data };
}
