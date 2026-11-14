/**
 * The living land: what grows and roams around a village, how it is put into words, and where the
 * animals are at any moment. The numbers come from the database (`sim.p_nature`); everything here
 * is pure, so the map can draw herds without the server sending a single coordinate.
 */
import { hash01 } from "./world";

export type Fauna = {
  /** Wild grazing animals. */
  grazer: string;
  /** The animals that hunt them. */
  hunter: string;
  /** What people keep once they have learned herding. */
  herd: string;
  bird: string;
  tree: string;
  /** How much of this country is naturally under trees, 0 to 1. */
  woodsK: number;
  /** How many grazers the untouched land around one village feeds. */
  gameK: number;
};

/** Mirrors `sim.fauna` in the database. */
export const FAUNA: Record<string, Fauna> = {
  grassland: { grazer: "deer", hunter: "wolves", herd: "goats", bird: "cranes", tree: "oak", woodsK: 0.25, gameK: 260 },
  forest: { grazer: "deer", hunter: "wolves", herd: "pigs", bird: "geese", tree: "beech", woodsK: 0.85, gameK: 200 },
  savanna: { grazer: "antelope", hunter: "lions", herd: "cattle", bird: "storks", tree: "acacia", woodsK: 0.2, gameK: 320 },
  rainforest: { grazer: "boar", hunter: "bears", herd: "pigs", bird: "herons", tree: "cedar", woodsK: 0.95, gameK: 150 },
  jungle: { grazer: "tapirs", hunter: "jaguars", herd: "pigs", bird: "parrots", tree: "fig", woodsK: 0.95, gameK: 150 },
  taiga: { grazer: "elk", hunter: "bears", herd: "reindeer", bird: "geese", tree: "pine", woodsK: 0.8, gameK: 140 },
  mountain: { grazer: "wild goats", hunter: "lynx", herd: "goats", bird: "eagles", tree: "fir", woodsK: 0.35, gameK: 90 },
  desert: { grazer: "gazelles", hunter: "jackals", herd: "camels", bird: "falcons", tree: "palm", woodsK: 0.03, gameK: 40 },
  tundra: { grazer: "reindeer", hunter: "wolves", herd: "reindeer", bird: "geese", tree: "birch", woodsK: 0.05, gameK: 110 },
  ice: { grazer: "seals", hunter: "bears", herd: "dogs", bird: "gulls", tree: "willow", woodsK: 0, gameK: 30 },
};

export function faunaOf(biome: string | null | undefined): Fauna {
  return FAUNA[biome ?? ""] ?? FAUNA.grassland;
}

export type Land = { woods: number; richness: number; game: number; beasts: number; fish: number; herd: number };

/** The public API sends the land as `[woods, richness, game, beasts, fish, herd]`. */
export function landOf(tuple: readonly number[] | null | undefined): Land | null {
  if (!Array.isArray(tuple) || tuple.length < 6 || tuple.some((n) => typeof n !== "number" || !Number.isFinite(n))) return null;
  const [woods, richness, game, beasts, fish, herd] = tuple;
  return { woods, richness, game, beasts, fish, herd };
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** A head count the way a villager would give it: nobody counts deer to the last one. */
export function roughly(n: number): string {
  if (n < 1) return "none";
  if (n < 6) return "a few";
  if (n < 15) return "about ten";
  if (n >= 1000) return "more than a thousand";
  const step = n < 100 ? 10 : n < 300 ? 50 : 100;
  return `about ${Math.round(n / step) * step}`;
}

export type LandLine = { label: string; text: string; tone?: "good" | "bad" };

/** What a visitor is told about the country around a village. */
export function describeLand(land: Land, biome: string | null | undefined, pop: number): LandLine[] {
  const f = faunaOf(biome);
  const lines: LandLine[] = [];
  if (f.woodsK < 0.1) {
    lines.push({ label: "Trees", text: land.woods < 0.01 ? "Almost none grow here" : `A few ${f.tree} trees` });
  } else {
    const share = land.woods / f.woodsK;
    lines.push(
      share < 0.3 ? { label: "Woods", text: `Thin: the ${f.tree} woods have been cut hard`, tone: "bad" }
        : share < 0.7 ? { label: "Woods", text: `Open ${f.tree} woods, with clearings` }
          : { label: "Woods", text: `Thick ${f.tree} woods` });
  }
  lines.push(
    land.richness < 0.35 ? { label: "Soil", text: "Tired: it has been farmed too hard", tone: "bad" }
      : land.richness < 0.55 ? { label: "Soil", text: "Thin" }
        : land.richness < 0.8 ? { label: "Soil", text: "Good" }
          : { label: "Soil", text: "Dark and rich", tone: "good" });
  const scarce = land.game < 0.15 * f.gameK;
  lines.push({ label: cap(f.grazer), text: scarce ? `Scarce: ${roughly(land.game)}` : cap(roughly(land.game)), ...(scarce ? { tone: "bad" as const } : {}) });
  if (land.beasts >= 1) lines.push({ label: cap(f.hunter), text: cap(roughly(land.beasts)) });
  lines.push({ label: "Fish", text: land.fish < 40 ? "Little" : land.fish < 200 ? "Some, in the streams" : "Plenty" });
  if (land.herd >= 1) lines.push({ label: `The village ${f.herd}`, text: cap(roughly(land.herd)), ...(pop > 0 && land.herd >= pop ? { tone: "good" as const } : {}) });
  return lines;
}

export type Creature = { x: number; y: number; kind: "grazer" | "hunter" | "herd" | "bird"; heading: number };

const TAU = Math.PI * 2;
const MAX_GRAZERS = 36;
const MAX_HUNTERS = 6;
const MAX_HERD = 20;

/**
 * Where the animals around a village are at this tick. Wild herds graze in small groups that drift
 * round the village over days; hunters keep their distance and come closer in the dark; the
 * village's own animals stay near the homes and bunch up at night; birds fly by day.
 * `isLand` keeps everything out of the sea.
 */
export function wildlifeAt(
  place: { id: number; x: number; y: number },
  land: Land,
  tick: number,
  daylight: number,
  isLand: (x: number, y: number) => boolean,
): Creature[] {
  const out: Creature[] = [];
  const add = (kind: Creature["kind"], x: number, y: number, heading: number) => {
    if (kind === "bird" || isLand(x, y)) out.push({ kind, x, y, heading });
  };

  const grazers = Math.min(MAX_GRAZERS, Math.round(land.game / 8));
  for (let i = 0; i < grazers; i++) {
    const group = Math.floor(i / 6);
    const turn = hash01(place.id * 131 + group, 7) < 0.5 ? 1 : -1;
    const angle = TAU * hash01(place.id * 131 + group, 1) + turn * tick * 0.0009;
    const radius = 20 + 18 * hash01(place.id * 131 + group, 2);
    const wander = tick / 9 + i * 1.7;
    add("grazer",
      place.x + radius * Math.cos(angle) + 2.4 * Math.cos(TAU * hash01(place.id * 977 + i, 3)) + 0.5 * Math.sin(wander),
      place.y + radius * Math.sin(angle) + 2.4 * Math.sin(TAU * hash01(place.id * 977 + i, 4)) + 0.5 * Math.cos(wander * 0.8),
      angle + (turn * Math.PI) / 2);
  }

  const hunters = Math.min(MAX_HUNTERS, Math.round(land.beasts));
  const prowl = 1 - 0.3 * (1 - daylight); // closer at night
  for (let i = 0; i < hunters; i++) {
    const angle = TAU * hash01(place.id * 313 + i, 5) - tick * 0.0016;
    const radius = (34 + 12 * hash01(place.id * 313 + i, 6)) * prowl;
    add("hunter", place.x + radius * Math.cos(angle), place.y + radius * Math.sin(angle), angle - Math.PI / 2);
  }

  const herd = Math.min(MAX_HERD, Math.round(land.herd / 3));
  const spread = 1.2 + 2.6 * daylight; // out at pasture by day, penned at night
  const pasture = TAU * hash01(place.id, 11);
  for (let i = 0; i < herd; i++) {
    const a = TAU * hash01(place.id * 71 + i, 8);
    const d = spread * Math.sqrt(hash01(place.id * 71 + i, 9));
    add("herd", place.x + 11 * Math.cos(pasture) + d * Math.cos(a) + 0.3 * Math.sin(tick / 11 + i),
      place.y + 11 * Math.sin(pasture) + d * Math.sin(a) + 0.3 * Math.cos(tick / 13 + i), a);
  }

  if (daylight > 0.35) {
    // One flock circling wide over the village.
    const sweep = tick * 0.02 + TAU * hash01(place.id, 12);
    const cx = place.x + 26 * Math.cos(sweep);
    const cy = place.y + 16 * Math.sin(sweep * 1.3);
    const heading = Math.atan2(16 * 1.3 * Math.cos(sweep * 1.3), -26 * Math.sin(sweep));
    for (let i = 0; i < 5; i++) {
      const back = Math.ceil(i / 2) * 1.1;
      const side = (i % 2 === 0 ? 1 : -1) * Math.ceil(i / 2) * 0.8;
      add("bird", cx - back * Math.cos(heading) - side * Math.sin(heading), cy - back * Math.sin(heading) + side * Math.cos(heading), heading);
    }
  }
  return out;
}

const SKIN = ["fair", "light brown", "brown", "dark brown", "deep brown"];
const HAIR = ["black", "dark brown", "brown", "auburn", "fair"];
const CURL = ["straight", "wavy", "curly"];
const EYES = ["dark", "brown", "hazel", "grey"];

/**
 * A person's looks in words, from `[skin, hair, curl, eyes, height, build]`. Children inherit
 * these from their parents in the database. Hair greys with age.
 */
export function looksOf(looks: readonly number[] | null | undefined, ageYears: number): string | null {
  if (!Array.isArray(looks) || looks.length < 6) return null;
  const [skin, hair, curl, eyes, height, build] = looks;
  const tall = height >= 68 ? "tall" : height <= 32 ? "short" : null;
  const frame = build >= 68 ? "sturdy" : build <= 32 ? "slight" : null;
  const body = ageYears < 3 ? null : [tall, frame].filter(Boolean).join(" and ") || "of middling height";
  const colour = ageYears >= 62 ? "grey" : ageYears >= 48 ? `greying ${HAIR[hair] ?? "dark"}` : HAIR[hair] ?? "dark";
  const head = ageYears < 1 ? `a little ${HAIR[hair] ?? "dark"} hair` : `${CURL[curl] ?? "straight"} ${colour} hair`;
  const rest = `${head}, ${EYES[eyes] ?? "brown"} eyes and ${SKIN[skin] ?? "brown"} skin`;
  return body ? `${cap(body)}, with ${rest}` : cap(rest);
}

/** The tone the map paints a figure with. Matches `looks[0]`. */
export const SKIN_TONES = ["#f1d3b8", "#e0b48e", "#c68f63", "#9a6a45", "#6f4a31"];

export type CreatureKind = Creature["kind"];

/** What a visitor is told when they click an animal on the map. */
export function creatureStory(kind: CreatureKind, land: Land, biome: string | null | undefined, village: string): { title: string; lines: string[] } {
  const f = faunaOf(biome);
  switch (kind) {
    case "grazer": {
      const state = land.game < 0.15 * f.gameK ? "They have been hunted hard and are scarce now."
        : land.game > 0.6 * f.gameK ? "The herds are healthy."
          : `People hunt them, and so do the ${f.hunter}.`;
      return { title: cap(f.grazer), lines: [`${cap(roughly(land.game))} ${f.grazer} graze around ${village}.`, state] };
    }
    case "hunter": {
      const lines = [`${cap(roughly(land.beasts))} ${f.hunter} live off the ${f.grazer} around ${village}.`, "They keep their distance by day and come closer after dark."];
      if (land.game < 0.25 * f.gameK) lines.push(`With so few ${f.grazer} left they are hungry, and the village's own animals are in danger.`);
      return { title: cap(f.hunter), lines };
    }
    case "herd":
      return { title: `The village ${f.herd}`, lines: [`The people of ${village} keep ${roughly(land.herd)} ${f.herd}.`, "They go out to pasture in the morning and are penned at night."] };
    case "bird":
      return { title: cap(f.bird), lines: [`${cap(f.bird)} over ${village}.`, "They leave for the winter and come back with the spring."] };
  }
}

export type GroveTree = { x: number; y: number; size: number; shape: "round" | "conifer" | "palm" };
export type Grove = { trees: GroveTree[]; stumps: { x: number; y: number }[] };

const GROVE_SLOTS = 150; // one drawn tree stands for a little under 1% of the land around a village
const MAX_STUMPS = 40; // older stumps have rotted away
const CONIFERS = new Set(["pine", "fir", "cedar"]);

/**
 * The woods a village can see from its doors. The number of trees follows the real share of land
 * under trees, so woods that are cut thin out on the map, nearest the houses first, and leave
 * stumps. `isClear` keeps trees off the sea and off buildings.
 */
export function groveOf(place: { id: number; x: number; y: number }, woods: number, biome: string | null | undefined, isClear: (x: number, y: number) => boolean): Grove {
  const f = faunaOf(biome);
  const natural = Math.round(GROVE_SLOTS * f.woodsK);
  const standing = Math.max(0, Math.min(GROVE_SLOTS, Math.round(GROVE_SLOTS * woods)));
  const total = Math.max(natural, standing);
  const shape: GroveTree["shape"] = CONIFERS.has(f.tree) ? "conifer" : f.tree === "palm" ? "palm" : "round";
  const slots = Array.from({ length: total }, (_, i) => {
    const angle = TAU * hash01(place.id * 17 + i, 21);
    const radius = 13 + 34 * Math.sqrt(hash01(place.id * 17 + i, 22));
    return { x: place.x + radius * Math.cos(angle), y: place.y + radius * Math.sin(angle), radius, size: 0.8 + 0.7 * hash01(place.id * 17 + i, 23) };
  }).sort((a, b) => a.radius - b.radius);
  const cut = total - standing;
  const grove: Grove = { trees: [], stumps: [] };
  slots.forEach((s, i) => {
    if (!isClear(s.x, s.y)) return;
    if (i >= cut) grove.trees.push({ x: s.x, y: s.y, size: s.size, shape });
    else if (i >= cut - MAX_STUMPS) grove.stumps.push({ x: s.x, y: s.y });
  });
  return grove;
}

/** How much of a fire's mark is still on the land: 1 on the day, 0 once two EON years have grown over it. */
export function burnScar(burnTick: number | null | undefined, tick: number): number {
  if (burnTick == null || tick < burnTick) return 0;
  return Math.max(0, 1 - (tick - burnTick) / 2880);
}
