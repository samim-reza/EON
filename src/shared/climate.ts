/**
 * The climate of EON: latitude, biomes, seasons, sun, moon and weather. Everything here is a pure
 * function of the world seed, a place and a time, so nothing is stored or sent: every browser and
 * the database reach the same answer on their own.
 *
 * The simulation needs the same weather as the map, so `weatherAt` has a twin in SQL
 * (`sim.weather_at`). Change one and you must change the other; golden vectors in climate.test.ts
 * and supabase/tests/eon_test.sql fail if they drift apart. That is why the noise below uses only
 * integer hashing and plain arithmetic, which give identical results in JavaScript and Postgres.
 */

const TAU = Math.PI * 2;
const DEG = Math.PI / 180;

export const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const mix = (a: number, b: number, t: number) => a + (b - a) * t;
export const smooth = (edge0: number, edge1: number, v: number) => {
  const t = clamp01((v - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
};
const bump = (v: number, centre: number, width: number) => Math.exp(-(((v - centre) / width) ** 2));

// --- Portable noise -------------------------------------------------------------------------

/** 32-bit hash to [0, 1). The multipliers stay below 2^31 so SQL can multiply them in a bigint. */
export function hash3(seed: number, a: number, b: number, c: number): number {
  let h = Math.imul(seed ^ a, 0x5bd1e995);
  h ^= h >>> 15;
  h = Math.imul(h ^ b, 0x27d4eb2d);
  h ^= h >>> 13;
  h = Math.imul(h ^ c, 0x165667b1);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

/** Value noise over a 3-D lattice, in [0, 1]. */
export function noise3(seed: number, x: number, y: number, z: number): number {
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const z0 = Math.floor(z);
  const fx = x - x0;
  const fy = y - y0;
  const fz = z - z0;
  const u = fx * fx * (3 - 2 * fx);
  const v = fy * fy * (3 - 2 * fy);
  const w = fz * fz * (3 - 2 * fz);
  const near = mix(
    mix(hash3(seed, x0, y0, z0), hash3(seed, x0 + 1, y0, z0), u),
    mix(hash3(seed, x0, y0 + 1, z0), hash3(seed, x0 + 1, y0 + 1, z0), u),
    v,
  );
  const far = mix(
    mix(hash3(seed, x0, y0, z0 + 1), hash3(seed, x0 + 1, y0, z0 + 1), u),
    mix(hash3(seed, x0, y0 + 1, z0 + 1), hash3(seed, x0 + 1, y0 + 1, z0 + 1), u),
    v,
  );
  return mix(near, far, w);
}

// --- Geography ------------------------------------------------------------------------------

/** The map runs from the Arctic at the top to the equator at the bottom. */
export const latitudeOf = (y: number) => 72 - 0.075 * y;

/** The sun reaches the east of the map up to 2 hours before the world clock, the west 2 hours after. */
export const solarOffset = (x: number) => ((x - 500) / 1000) * 4;

export type Biome = "ice" | "tundra" | "taiga" | "mountain" | "grassland" | "forest" | "rainforest" | "desert" | "savanna" | "jungle";

export const BIOME_NAMES: Record<Biome, string> = {
  ice: "ice field",
  tundra: "tundra",
  taiga: "pine forest",
  mountain: "mountains",
  grassland: "grassland",
  forest: "forest",
  rainforest: "misty rainforest",
  desert: "desert",
  savanna: "savanna",
  jungle: "jungle",
};

export type Climate = {
  lat: number;
  elev: number;
  /** Average temperature over the year, °C. */
  tempMean: number;
  /** How far summer and winter sit from that average, °C. */
  tempSwing: number;
  /** 0 (bone dry) to 1 (soaked). */
  wet: number;
  /** Rain and snow per year, mm. */
  rainfall: number;
  biome: Biome;
};

export function biomeOf(tempMean: number, rainfall: number, elev: number): Biome {
  if (tempMean < -9) return "ice";
  if (elev > 0.5) return "mountain";
  if (tempMean < -2) return "tundra";
  if (tempMean < 5) return rainfall < 220 ? "tundra" : "taiga";
  if (tempMean < 18) return rainfall < 240 ? "desert" : rainfall < 520 ? "grassland" : rainfall < 1500 ? "forest" : "rainforest";
  return rainfall < 300 ? "desert" : rainfall < 850 ? "savanna" : rainfall < 1500 ? "forest" : "jungle";
}

/** How wet a place is, from a seeded pattern laid over the planet's real rain belts. */
export function wetnessAt(seed: number, x: number, y: number): number {
  const lat = latitudeOf(y);
  const pattern = 0.6 * noise3(seed ^ 0x51ed27, x / 340, y / 340, 0.5) + 0.4 * noise3(seed ^ 0x1c3f11, x / 120, y / 120, 7.5);
  // Rain at the equator, deserts near 25°, storms at 50°, dry polar air.
  const belts = 0.34 * bump(lat, 2, 13) - 0.3 * bump(lat, 25, 9) + 0.16 * bump(lat, 50, 12) - 0.12 * bump(lat, 74, 10);
  return clamp01((pattern - 0.5) * 2.6 + 0.56 + belts);
}

export function climateAt(seed: number, x: number, y: number, elevation: number): Climate {
  const lat = latitudeOf(y);
  const elev = Math.max(0, elevation);
  const wet = wetnessAt(seed, x, y);
  const rainfall = 60 + 2700 * wet ** 2.2;
  const tempMean = 27.5 - 0.0072 * lat * lat - 30 * Math.max(0, elev - 0.1) ** 1.3; // thin mountain air
  const tempSwing = 1 + 0.26 * Math.abs(lat) + 2 * (1 - wet);
  return { lat, elev, tempMean, tempSwing, wet, rainfall, biome: biomeOf(tempMean, rainfall, elev) };
}

// --- Calendar and sky -----------------------------------------------------------------------

/** 0 at the spring equinox (the first day of the year), 0.25 at the summer solstice. */
export const yearFraction = (tf: number) => ((tf % 1440) + 1440) % 1440 / 1440;

/** The hour on the world clock, 0–24. */
export const clockHour = (tf: number) => (6 + (((tf % 4) + 4) % 4) * 6) % 24;

/** The hour by the sun at a place. */
export const localHour = (tf: number, x: number) => (clockHour(tf) + solarOffset(x) + 24) % 24;

/** +1 in the warmest week, -1 in the coldest: land and sea lag the sun by about a month. */
export const seasonCurve = (tf: number) => Math.cos(TAU * (yearFraction(tf) - 0.333));

const declination = (fraction: number) => 23.44 * Math.sin(TAU * fraction);

function elevationDeg(lat: number, decl: number, hour: number) {
  const sin = Math.sin(lat * DEG) * Math.sin(decl * DEG) + Math.cos(lat * DEG) * Math.cos(decl * DEG) * Math.cos((hour - 12) * 15 * DEG);
  return Math.asin(Math.max(-1, Math.min(1, sin))) / DEG;
}

/** Sunrise and sunset by local solar time, or null during polar day and polar night. */
export function sunTimes(tf: number, lat: number): { rise: number; set: number; polar: "day" | "night" | null } {
  const decl = declination(yearFraction(tf));
  const cosH = (Math.sin(-0.83 * DEG) - Math.sin(lat * DEG) * Math.sin(decl * DEG)) / (Math.cos(lat * DEG) * Math.cos(decl * DEG));
  if (cosH <= -1) return { rise: 0, set: 24, polar: "day" };
  if (cosH >= 1) return { rise: 12, set: 12, polar: "night" };
  const half = Math.acos(cosH) / DEG / 15;
  return { rise: 12 - half, set: 12 + half, polar: null };
}

/** Height of the sun above the horizon, in degrees. */
export const sunElevation = (tf: number, lat: number, x: number) => elevationDeg(lat, declination(yearFraction(tf)), localHour(tf, x));

const SYNODIC_TICKS = 118.12; // 29.53 EON days, as on Earth

export const MOON_PHASES = ["New moon", "Waxing crescent", "First quarter", "Waxing gibbous", "Full moon", "Waning gibbous", "Last quarter", "Waning crescent"] as const;

export type Moon = {
  /** 0 new, 0.5 full, back to 1. */
  phase: number;
  name: (typeof MOON_PHASES)[number];
  /** Lit share of the disc, 0–1. */
  light: number;
  /** Height above the horizon, in degrees. */
  elevation: number;
};

const moonPhase = (seed: number, tf: number) => (((tf / SYNODIC_TICKS + hash3(seed, 11, 0, 0)) % 1) + 1) % 1;

export function moonAt(seed: number, tf: number, lat: number, x: number): Moon {
  const phase = moonPhase(seed, tf);
  // The moon rises later each day, and sits opposite the sun's declination when full.
  const hour = (localHour(tf, x) - phase * 24 + 24) % 24;
  return {
    phase,
    name: MOON_PHASES[Math.floor(phase * 8 + 0.5) % 8],
    light: (1 - Math.cos(TAU * phase)) / 2,
    elevation: elevationDeg(lat, declination(yearFraction(tf) + phase), hour),
  };
}

/** Ticks until the next full moon. */
export function ticksToFullMoon(seed: number, tf: number) {
  return (((0.5 - moonPhase(seed, tf)) % 1) + 1) % 1 * SYNODIC_TICKS;
}

/** 1 at new and full moon, when sun and moon pull together; 0 at the quarters. */
export const springTide = (seed: number, tf: number) => Math.abs(Math.cos(TAU * moonPhase(seed, tf)));

/** Sea level from -1 to 1. It peaks twice per trip of the moon: under it, and on the far side of the world. */
export function tideAt(seed: number, tf: number, x: number) {
  const moonHour = localHour(tf, x) - moonPhase(seed, tf) * 24;
  return (0.6 + 0.4 * springTide(seed, tf)) * Math.cos((TAU * (moonHour - 12)) / 12);
}

export function tideLabel(seed: number, tf: number, x: number) {
  const now = tideAt(seed, tf, x);
  const spring = springTide(seed, tf) > 0.85;
  if (Math.abs(now) > 0.55) return `${spring ? "Spring" : now > 0 ? "High" : "Low"} tide${spring ? (now > 0 ? ", high" : ", low") : ""}`;
  return tideAt(seed, tf + 0.05, x) > now ? "Tide coming in" : "Tide going out";
}

// --- Weather --------------------------------------------------------------------------------

export type WeatherKind =
  | "clear" | "partly" | "cloudy" | "overcast" | "fog" | "drizzle" | "rain" | "downpour" | "thunderstorm"
  | "sleet" | "snow" | "blizzard" | "sandstorm";

export const WEATHER_LABELS: Record<WeatherKind, string> = {
  clear: "Clear",
  partly: "Partly cloudy",
  cloudy: "Cloudy",
  overcast: "Overcast",
  fog: "Fog",
  drizzle: "Drizzle",
  rain: "Rain",
  downpour: "Heavy rain",
  thunderstorm: "Thunderstorm",
  sleet: "Sleet",
  snow: "Snow",
  blizzard: "Blizzard",
  sandstorm: "Sandstorm",
};

export type Weather = {
  /** °C at this moment, and today's extremes. */
  temp: number;
  high: number;
  low: number;
  /** 0–1. */
  cloud: number;
  /** 0–1: how hard rain or snow is falling. */
  rain: number;
  /** km/h. */
  wind: number;
  kind: WeatherKind;
  heatwave: boolean;
  coldSnap: boolean;
};

/** God's sliders: both sides of the twin read them, so a change reaches the map and the world together. */
export type WeatherTuning = { tempShift: number; rainMult: number };
export const NO_TUNING: WeatherTuning = { tempShift: 0, rainMult: 1 };

/** Clouds and rain travel east at the speed of real weather systems: 115 map units per EON day. */
export const WEATHER_DRIFT = 115;

/** Chance of a rainy spell here right now. Monsoons fall in summer; Mediterranean rain falls in winter. */
function rainChance(c: Climate, season: number, rainMult: number) {
  const monsoon = 0.75 * clamp01((26 - c.lat) / 10);
  const dryPeak = -0.6 * clamp01((c.lat - 28) / 6) * clamp01((48 - c.lat) / 6);
  const wetBase = 0.015 + 0.6 * (c.rainfall / 2000) ** 0.75;
  return Math.max(0.002, Math.min(0.85, wetBase * (1 + (monsoon + dryPeak) * season) * rainMult));
}

export function weatherAt(seed: number, c: Climate, x: number, y: number, tf: number, tune: WeatherTuning = NO_TUNING): Weather {
  const days = tf / 4;
  const season = seasonCurve(tf);
  const large = noise3(seed ^ 0x2f6e2b, (x - WEATHER_DRIFT * days) / 260, y / 260, days / 3);
  const small = noise3(seed ^ 0x7a3d91, (x - WEATHER_DRIFT * days) / 90, y / 90, days / 1.2);
  const front = 0.72 * large + 0.28 * small; // close to a bell curve: mean 0.5, sd 0.15
  const chance = rainChance(c, season, tune.rainMult);
  const threshold = 0.5 - 0.088 * Math.log(chance / (1 - chance)); // the front level exceeded `chance` of the time
  const cloud = smooth(threshold - 0.22, threshold + 0.02, front);
  const rain = smooth(threshold, threshold + 0.3, front);

  const drift = (noise3(seed ^ 0x3b1c55, x / 520, y / 520, days / 14) - 0.5) * 2.8; // heat waves and cold spells
  const anomaly = drift * (2 + 0.07 * Math.abs(c.lat));
  const daily = c.tempMean + tune.tempShift + c.tempSwing * season + anomaly - 4 * rain;
  const range = (3 + 6 * (1 - c.wet)) * (1 - 0.55 * cloud); // deserts swing most between day and night
  const hour = localHour(tf, x);
  const temp = daily + range * Math.cos((TAU * (hour - 15)) / 24);
  const gust = noise3(seed ^ 0x4d8a13, x / 300, y / 300, days / 2);
  const wind = 6 + 42 * gust * gust + 52 * rain * rain;

  let kind: WeatherKind;
  if (rain > 0.08) {
    if (temp <= 0.5) kind = rain >= 0.82 && wind >= 50 ? "blizzard" : "snow";
    else if (temp <= 2.5) kind = "sleet";
    else if (rain < 0.28) kind = "drizzle";
    else if (rain < 0.62) kind = "rain";
    else kind = rain >= 0.82 && temp >= 16 ? "thunderstorm" : "downpour";
  } else if (c.biome === "desert" && wind >= 34) kind = "sandstorm";
  else if (c.wet > 0.32 && wind < 16 && cloud > 0.15 && (hour > 3.5 && hour < 8.5)) kind = "fog";
  else kind = cloud > 0.82 ? "overcast" : cloud > 0.45 ? "cloudy" : cloud > 0.18 ? "partly" : "clear";

  return {
    temp,
    high: daily + range,
    low: daily - range,
    cloud,
    rain,
    wind,
    kind,
    heatwave: daily + range >= 38 || (season > 0.3 && anomaly >= 5),
    coldSnap: daily - range <= -18 || (season < -0.3 && anomaly <= -5),
  };
}
