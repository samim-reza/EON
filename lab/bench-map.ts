/**
 * How much work the map does per frame for the land and its animals, at a scale the live world has
 * not reached yet. Counts canvas calls on a stand-in context and times the script.
 * Usage: npx tsx lab/bench-map.ts [villages=200] [frames=120]
 *
 * Before batching and caching (86 villages on screen): 5.7 ms and 22,471 canvas calls per frame.
 */
import { boatSpots, createWildlifeBatch, drawGroves, packGrove, type GroveView } from "../src/components/map/scenery";
import { eachCreature, groveOf, type Land } from "../src/shared/nature";
import { landLookup, makeTerrain } from "../src/shared/world";

const villages = Number(process.argv[2] ?? 200);
const frames = Number(process.argv[3] ?? 120);
const terrain = makeTerrain(1257650109);
const onLand = landLookup(terrain.elevation);

// A stand-in canvas: path building costs nothing here, so the time measured is the map's own work.
let calls = 0;
const nothing = () => {};
const count = () => { calls++; };
const ctx = {
  beginPath: nothing, moveTo: nothing, lineTo: nothing, arc: nothing, ellipse: nothing, closePath: nothing,
  fill: count, stroke: count, fillRect: count, drawImage: count,
  fillStyle: "", strokeStyle: "", lineWidth: 1, lineCap: "butt", globalAlpha: 1,
} as unknown as CanvasRenderingContext2D;

// Villages on land, spread over the continent.
const places: { id: number; x: number; y: number; biome: string; land: Land }[] = [];
const biomes = ["grassland", "forest", "savanna", "taiga", "jungle"];
for (let i = 0, id = 1; places.length < villages && i < 200000; i++) {
  const x = 60 + ((i * 7919) % 880);
  const y = 60 + ((i * 104729) % 880);
  if (!onLand(x, y) || places.some((p) => Math.hypot(p.x - x, p.y - y) < 30)) continue;
  places.push({ id: id++, x, y, biome: biomes[id % 5], land: { woods: 0.2 + 0.5 * ((id * 13) % 10) / 10, richness: 0.6, game: 220, beasts: 4, fish: 200, herd: 45 } });
}

const t0 = performance.now();
const views: GroveView[] = places.map((p) => ({ grove: packGrove(groveOf(p, p.land.woods, p.biome, onLand)), autumn: 0.4, bare: 0, charred: false }));
const boats = places.map((p) => boatSpots(p, terrain.elevation));
const setup = performance.now() - t0;

const z = 4;
const sx = (v: number) => v * z;
const sy = (v: number) => v * z;
const everything = { x0: -1e9, y0: -1e9, x1: 1e9, y1: 1e9 };
const batch = createWildlifeBatch();
const add = (kind: number, x: number, y: number, heading: number) => batch.add(kind, sx(x), sy(y), heading);
calls = 0;
const t1 = performance.now();
let creatures = 0;
for (let f = 0; f < frames; f++) {
  const tick = 15000 + f / 30;
  drawGroves(ctx, views, views.length, sx, sy, z, everything);
  batch.reset();
  for (const p of places) eachCreature(p, p.land, tick, 1, onLand, add);
  creatures += batch.total;
  batch.draw(ctx, 2);
}
const perFrame = (performance.now() - t1) / frames;
console.log(JSON.stringify({
  villages: places.length, trees: views.reduce((n, v) => n + v.grove.count, 0), boats: boats.reduce((n, b) => n + b.length, 0),
  setupMs: Math.round(setup), msPerFrame: Number(perFrame.toFixed(2)), canvasCallsPerFrame: Math.round(calls / frames), creaturesPerFrame: Math.round(creatures / frames),
}));
