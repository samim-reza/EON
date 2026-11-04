import { climateAt, NO_TUNING, weatherAt, type Climate, type Weather } from "@/shared/climate";
import { isCoastal } from "@/shared/rivers";
import type { NowState } from "@/shared/types";
import { makeTerrain, type Terrain } from "@/shared/world";

let terrain: { seed: number; value: Terrain } | null = null;
const climates = new Map<string, Climate>();

/** A place's climate never changes, so it is worked out once. */
export function climateOf(seed: number, x: number, y: number): Climate {
  const key = `${seed}:${x}:${y}`;
  const hit = climates.get(key);
  if (hit) return hit;
  if (terrain?.seed !== seed) terrain = { seed, value: makeTerrain(seed) };
  const climate = climateAt(seed, x, y, terrain.value.elevation(x, y));
  if (climates.size > 500) climates.clear();
  climates.set(key, climate);
  return climate;
}

const coasts = new Map<string, boolean>();

/** Is this place close enough to the sea for its tides to matter? */
export function coastalAt(seed: number, x: number, y: number) {
  const key = `${seed}:${x}:${y}`;
  let coastal = coasts.get(key);
  if (coastal === undefined) {
    if (terrain?.seed !== seed) terrain = { seed, value: makeTerrain(seed) };
    coastal = isCoastal(terrain.value.elevation, x, y);
    coasts.set(key, coastal);
  }
  return coastal;
}

export function weatherHere(now: NowState, x: number, y: number, tf: number): { climate: Climate; weather: Weather } {
  const seed = Number(now.seed);
  const climate = climateOf(seed, x, y);
  return { climate, weather: weatherAt(seed, climate, x, y, tf, now.tune ?? NO_TUNING) };
}
