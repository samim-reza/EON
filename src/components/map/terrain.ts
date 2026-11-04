import { terrainPixels, TIDE_PX, TILE_PX, TILE_UNITS } from "@/shared/terrain-pixels";
import { WORLD_SIZE } from "@/shared/world";
import type { TerrainRequest } from "./terrain.worker";

export type TerrainMap = { base: HTMLCanvasElement; snow: HTMLCanvasElement; autumn: HTMLCanvasElement };
type Pixels = ReturnType<typeof terrainPixels>;
type Reply = { kind: "map"; map: Pixels } | { kind: "tile"; x: number; y: number; data: Uint8ClampedArray<ArrayBuffer>; tide: Uint8Array };

function toCanvas(data: Uint8ClampedArray, size: number) {
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  canvas.getContext("2d")!.putImageData(new ImageData(data as Uint8ClampedArray<ArrayBuffer>, size, size), 0, 0);
  return canvas;
}

// --- One worker for the tab ---------------------------------------------------------------------

let worker: Worker | null | undefined;
const waitingMaps: ((map: Pixels) => void)[] = [];
let tileInFlight = false;

function send(request: TerrainRequest) {
  worker?.postMessage(request);
}

function getWorker(): Worker | null {
  if (worker !== undefined) return worker;
  try {
    worker = new Worker(new URL("./terrain.worker.ts", import.meta.url));
    worker.onmessage = (event: MessageEvent<Reply>) => {
      const reply = event.data;
      if (reply.kind === "map") waitingMaps.shift()?.(reply.map);
      else {
        tileInFlight = false;
        storeTile(reply.x, reply.y, reply.data, reply.tide);
        pumpTiles();
      }
    };
    worker.onerror = () => {
      worker = null; // the map falls back to the main thread; close zoom stays soft
      for (const resolve of waitingMaps.splice(0)) resolve(terrainPixels(activeSeed, activeRes));
    };
  } catch {
    worker = null;
  }
  return worker;
}

let activeSeed = 0;
let activeRes = 1;

function generate(seed: number, res: number): Promise<Pixels> {
  activeSeed = seed;
  activeRes = res;
  return new Promise((resolve) => {
    const w = getWorker();
    if (!w) return resolve(terrainPixels(seed, res));
    waitingMaps.push(resolve);
    send({ kind: "map", seed, res });
  });
}

const maps = new Map<string, Promise<TerrainMap>>();

/** The map for a seed never changes, so it is built once per tab and reused across pages. */
export function loadTerrain(seed: number, res: number): Promise<TerrainMap> {
  const key = `${seed}:${res}`;
  const hit = maps.get(key);
  if (hit) return hit;
  const pending = generate(seed, res).then((map) => ({
    base: toCanvas(map.data, map.size),
    snow: toCanvas(map.snow, map.layerSize),
    autumn: toCanvas(map.autumn, map.layerSize),
  }));
  maps.set(key, pending);
  return pending;
}

// --- Detail tiles ---------------------------------------------------------------------------

/** The strip of shore a tide can reach: its cells, their heights, and the land's own colours there. */
type TideBand = { cells: Uint32Array; heights: Uint8Array; ground: Uint8Array; image: ImageData; left: number; top: number; width: number; height: number; level: number };

export type Tile = { canvas: HTMLCanvasElement; born: number; tide: TideBand | null };

function makeTideBand(tide: Uint8Array, image: ImageData): TideBand | null {
  let count = 0;
  for (const height of tide) if (height) count++;
  if (!count) return null;
  const cells = new Uint32Array(count);
  const heights = new Uint8Array(count);
  const ground = new Uint8Array(count * 3);
  let n = 0;
  let left = TIDE_PX;
  let right = 0;
  let top = TIDE_PX;
  let bottom = 0;
  for (let i = 0; i < tide.length; i++) {
    if (!tide[i]) continue;
    const x = i % TIDE_PX;
    const y = Math.floor(i / TIDE_PX);
    left = Math.min(left, x);
    right = Math.max(right, x);
    top = Math.min(top, y);
    bottom = Math.max(bottom, y);
    ground.set(image.data.subarray(i * 4, i * 4 + 3), n * 3);
    cells[n] = i;
    heights[n++] = tide[i];
  }
  return { cells, heights, ground, image, left, top, width: right - left + 1, height: bottom - top + 1, level: -1 };
}

const MEAN_SEA = 128; // the height value of the shoreline the map was drawn with
const TIDE_STEP = 4; // how far the sea must move before a tile is redrawn

/**
 * Writes one tile's shoreline for a sea level, straight into the tile. Above the mean, water spreads
 * over the beach. Below it, wet sand appears where the map shows sea. Only the strip the tide reaches
 * is touched, and only when the sea has really moved, so frames never pay for it.
 * Returns whether the tile changed, so the caller can spread the work over several frames.
 */
export function setTide(tile: Tile, level: number) {
  const tide = tile.tide;
  if (!tide || Math.abs(tide.level - level) < TIDE_STEP) return false;
  tide.level = level;
  const data = tide.image.data;
  for (let i = 0; i < tide.cells.length; i++) {
    const j = tide.cells[i] * 4;
    const depth = level - tide.heights[i]; // above zero, this cell is under water
    let r = 0;
    let g = 0;
    let b = 0;
    let cover = 0;
    if (Math.abs(depth) < 6) {
      r = 226; // a soft line of foam where the water meets the shore
      g = 240;
      b = 240;
      cover = 0.5 * (1 - Math.abs(depth) / 6);
    } else if (depth > 0 && tide.heights[i] >= MEAN_SEA) {
      r = 62; // sea over the beach
      g = 132;
      b = 144;
      cover = Math.min(1, (depth - 6) / 6);
    } else if (depth <= 0 && tide.heights[i] < MEAN_SEA) {
      r = 158; // wet sand left by the falling sea
      g = 142;
      b = 108;
      cover = Math.min(0.94, (-depth - 6) / 6);
    }
    const land = i * 3;
    data[j] = tide.ground[land] + (r - tide.ground[land]) * cover;
    data[j + 1] = tide.ground[land + 1] + (g - tide.ground[land + 1]) * cover;
    data[j + 2] = tide.ground[land + 2] + (b - tide.ground[land + 2]) * cover;
  }
  tile.canvas.getContext("2d")!.putImageData(tide.image, 0, 0, tide.left, tide.top, tide.width, tide.height);
  return true;
}

const MAX_TILES = 24; // about 40 MB: least recently used tiles leave first
const tiles = new Map<string, Tile>();
let wanted: { x: number; y: number }[] = [];
let tileSeed = 0;

function storeTile(x: number, y: number, data: Uint8ClampedArray<ArrayBuffer>, tide: Uint8Array) {
  const canvas = toCanvas(data, TILE_PX);
  tiles.set(`${x}:${y}`, { canvas, born: performance.now(), tide: makeTideBand(tide, new ImageData(data, TILE_PX, TILE_PX)) });
  while (tiles.size > MAX_TILES) tiles.delete(tiles.keys().next().value!);
}

function pumpTiles() {
  if (tileInFlight || !worker) return;
  const next = wanted.find(({ x, y }) => !tiles.has(`${x}:${y}`));
  if (!next) return;
  tileInFlight = true;
  send({ kind: "tile", seed: tileSeed, x: next.x, y: next.y });
}

/**
 * The tiles covering a view, as far as they exist. Only the current view is ever queued, one tile at
 * a time, so flying across the map never leaves a backlog of squares nobody is looking at any more.
 */
export function tilesFor(seed: number, x0: number, y0: number, x1: number, y1: number) {
  if (getWorker() === null) return [];
  tileSeed = seed;
  const last = Math.floor(WORLD_SIZE / TILE_UNITS) - 1;
  const left = Math.max(0, Math.floor(x0 / TILE_UNITS));
  const right = Math.min(last, Math.floor(x1 / TILE_UNITS));
  const top = Math.max(0, Math.floor(y0 / TILE_UNITS));
  const bottom = Math.min(last, Math.floor(y1 / TILE_UNITS));
  const found: { x: number; y: number; tile: Tile }[] = [];
  wanted = [];
  for (let y = top; y <= bottom; y++) {
    for (let x = left; x <= right; x++) {
      const key = `${x}:${y}`;
      const tile = tiles.get(key);
      if (tile) {
        tiles.delete(key); // re-inserting keeps the map in least-recently-used order
        tiles.set(key, tile);
        found.push({ x, y, tile });
      } else wanted.push({ x, y });
    }
  }
  const middleX = (x0 + x1) / 2 / TILE_UNITS - 0.5;
  const middleY = (y0 + y1) / 2 / TILE_UNITS - 0.5;
  wanted.sort((a, b) => Math.hypot(a.x - middleX, a.y - middleY) - Math.hypot(b.x - middleX, b.y - middleY));
  pumpTiles();
  return found;
}
