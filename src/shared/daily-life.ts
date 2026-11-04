/**
 * How someone spends the day. This replaces four fixed daily positions with a routine that follows
 * the clock, the sun and the weather. Like everything on the map it is derived, not stored: anyone
 * who knows a person's id, the time and the weather reaches the same answer.
 */
import { localHour } from "./climate";
import type { Biome, Weather, WeatherKind } from "./climate";
import { hash01, type BuildingIndex } from "./world";

export type Plan = { place: "home" | "work" | "school" | "market" | "temple" | "hall" | "wild"; doing: string; indoors: boolean; asleep?: boolean };

const WORKPLACE: Record<string, string> = { farmer: "farm", builder: "workshop", healer: "clinic" };
const AT_WORK: Record<string, string> = { farmer: "Working in the field", builder: "Building in the workshop", healer: "Treating patients at the clinic" };
/** Before the workplace exists, the same people live off the land. */
const IN_THE_WILD: Record<string, string> = { farmer: "Gathering food in the wild", builder: "Gathering wood", healer: "Looking for healing plants" };
const STORMS: WeatherKind[] = ["thunderstorm", "downpour", "blizzard", "sandstorm"];
const WET: WeatherKind[] = ["rain", "sleet", "snow", "thunderstorm", "downpour", "blizzard", "sandstorm"];

const SHELTER: Partial<Record<WeatherKind, string>> = {
  thunderstorm: "Sheltering from the storm",
  downpour: "Staying in out of the rain",
  blizzard: "Snowed in at home",
  sandstorm: "Sheltering from the sandstorm",
};

/** `home` of null means nobody has built this person a shelter yet. */
export type Person = { id: number; job: string; ageYears: number; home?: number | null };

/** Which buildings exist where this person lives. */
export type Has = (kind: string) => boolean;

/** What a person is doing at an hour by the sun. `day` varies the evening; `month` is 0–11. */
export function planFor(person: Person, hour: number, day: number, month: number, weather: Weather, has: Has = () => true): Plan {
  const { id, job, ageYears } = person;
  const lark = hash01(id, 3); // some people rise early, others stay up late
  const wake = (ageYears < 3 ? 6.5 : 5.2) + 2 * lark;
  const bed = (ageYears < 13 ? 19.5 : 20.8) + 2.4 * lark;
  const roofless = person.home === null;
  if (hour >= bed || hour < wake) return { place: "home", doing: roofless ? "Asleep by the fire" : "Asleep at home", indoors: !roofless, asleep: true };

  const home = (doing: string): Plan => ({ place: "home", doing, indoors: !roofless });
  if (ageYears < 3) return home("At home with family");

  const storm = STORMS.includes(weather.kind) || weather.temp <= -15;
  const midday = hour >= 11.5 && hour < 15.5;
  if (storm && job !== "healer" && !(job === "child" && hour < 14)) return home(SHELTER[weather.kind] ?? "Keeping warm indoors");
  if (weather.temp >= 37 && midday && job !== "healer") return home("Resting in the shade");

  const daytime = hour >= 8 && hour < 17 - lark;
  if (job === "child" && ageYears >= 6 && hour >= 8 && hour < 14) {
    return has("school") ? { place: "school", doing: "At school", indoors: true } : { place: "hall", doing: "Learning from the elders", indoors: false };
  }
  if (WORKPLACE[job] && daytime) {
    if (!has(WORKPLACE[job])) return { place: "wild", doing: IN_THE_WILD[job], indoors: false };
    if (job === "farmer" && (month === 10 || month === 11)) return home("Mending tools for spring"); // nothing grows in deep winter
    if (job === "farmer" && month >= 6 && month <= 7) return { place: "work", doing: "Bringing in the harvest", indoors: false };
    return { place: "work", doing: AT_WORK[job], indoors: job !== "farmer" };
  }
  if (job === "elder" && hour >= 8 && hour < 10.5 && has("temple")) return { place: "temple", doing: "Praying at the temple", indoors: true };

  if (hour >= 16 && hour < 19.5 && !WET.includes(weather.kind)) {
    const choice = hash01(id, day + 77);
    if (choice < 0.25 && has("market")) return { place: "market", doing: "At the market", indoors: false };
    if (choice < 0.42 && has("temple")) return { place: "temple", doing: "At the temple", indoors: true };
    if (choice < 0.6 && has("hall")) return { place: "hall", doing: "Talking at the gathering place", indoors: false };
  }
  return home(WET.includes(weather.kind) ? "Staying in out of the weather" : hour < 8 ? "Getting ready for the day" : "Relaxing at home");
}

/** Where a plan leads, for "On the way to …". */
export function destination(plan: Plan, job: string) {
  switch (plan.place) {
    case "home":
      return "home";
    case "work":
      return { farmer: "the field", builder: "the workshop", healer: "the clinic" }[job] ?? "work";
    case "wild":
      return "the wild";
    case "hall":
      return "the gathering place";
    default:
      return `the ${plan.place}`;
  }
}

type Spot = { x: number; y: number };

const CIVIC: Record<"work" | "school" | "market" | "temple" | "hall", (job: string) => string> = {
  work: (job) => WORKPLACE[job] ?? "hall",
  school: () => "school",
  market: () => "market",
  temple: () => "temple",
  hall: () => "hall",
};

/** The building a plan leads to, or null for the wild or someone with no home. */
export function buildingFor(person: { job: string; home: number | null; settlement: number }, plan: Plan, idx: BuildingIndex) {
  if (plan.place === "wild") return null;
  if (plan.place === "home") return person.home != null && idx.byId.has(person.home) ? person.home : idx.civicIds.get(`${person.settlement}:hall`) ?? null;
  return idx.civicIds.get(`${person.settlement}:${CIVIC[plan.place](person.job)}`) ?? null;
}

/** A spot near where a plan leads, the same one every time for a person. */
export function spotFor(person: { id: number; job: string; home: number | null; settlement: number }, plan: Plan, idx: BuildingIndex, fallback: Spot): Spot {
  if (plan.place === "wild") {
    const angle = hash01(person.id, 21) * Math.PI * 2;
    const reach = 13 + hash01(person.id, 22) * 9;
    return { x: fallback.x + Math.cos(angle) * reach, y: fallback.y + Math.sin(angle) * reach };
  }
  const id = buildingFor(person, plan, idx);
  const anchor = (id != null && idx.byId.get(id)) || fallback;
  const angle = hash01(person.id, plan.place.length) * Math.PI * 2;
  const reach = 0.5 + hash01(person.id, 99) * (plan.indoors ? 0.9 : 2.8);
  return { x: anchor.x + Math.cos(angle) * reach, y: anchor.y + Math.sin(angle) * reach };
}

/** A person's position changes on half-hour slots: 5 real seconds each. */
export const SLOTS_PER_TICK = 12;

export function slotInfo(slot: number, x: number) {
  const tf = slot / SLOTS_PER_TICK;
  const day = Math.floor((tf + 1) / 4); // the calendar day turns at midnight, one tick before the morning
  return { tf, hour: localHour(tf, x), day, month: ((Math.floor(tf / 120) % 12) + 12) % 12 };
}

export type Outfit = {
  /** Finishes the sentence "wearing …". */
  wearing: string;
  /** Colour of the main garment. */
  colour: string;
  headwear: "none" | "straw" | "wool" | "hood" | "wrap";
  umbrella: boolean;
};

const WOOLS = ["#3f4a63", "#5b3a3f", "#3e5448", "#5a4a36", "#4a4458"];
const FURS = ["#6d5a45", "#54483e", "#7a6650"];
const EVERYDAY = ["#3f7d8c", "#a0603f", "#6c7a3a", "#7d5a8a", "#b0893d", "#44678f"];
const SUMMER = ["#e6dfc9", "#bcd4dc", "#e2c9a6", "#d9b8c0", "#c6d6a8"];
const ROBES = ["#f0ead8", "#e4d6b4", "#d8dde0"];

const pick = (list: string[], id: number) => list[Math.floor(hash01(id, 41) * list.length)];

/**
 * What someone wears today. People dress for how cold it feels, wind included, then for the rain,
 * then for the place they live and the work they do.
 */
export function outfitFor(person: Person, plan: Plan, weather: Weather, biome: Biome): Outfit {
  const { id, job } = person;
  if (plan.asleep) return { wearing: "night clothes", colour: "#8f94a8", headwear: "none", umbrella: false };

  const feels = weather.temp - (weather.temp < 12 ? weather.wind * 0.12 : 0);
  const outdoors = !plan.indoors || plan.place === "market";
  const snowing = weather.kind === "snow" || weather.kind === "blizzard" || weather.kind === "sleet";
  const raining = weather.rain > 0.08 && !snowing;
  const sunny = weather.cloud < 0.45 && weather.rain <= 0.08;

  let outfit: Outfit;
  if (feels <= -12) outfit = { wearing: "a fur-lined parka and thick boots", colour: pick(FURS, id), headwear: "hood", umbrella: false };
  else if (feels <= 0) outfit = { wearing: "a heavy wool coat, scarf and gloves", colour: pick(WOOLS, id), headwear: "wool", umbrella: false };
  else if (feels <= 9) outfit = { wearing: "a warm coat", colour: pick(WOOLS, id), headwear: "none", umbrella: false };
  else if (feels <= 17) outfit = { wearing: "a light jacket", colour: pick(EVERYDAY, id), headwear: "none", umbrella: false };
  else if (feels <= 26) outfit = { wearing: "everyday clothes", colour: pick(EVERYDAY, id), headwear: "none", umbrella: false };
  else if (biome === "desert") outfit = { wearing: "loose robes and a head wrap", colour: pick(ROBES, id), headwear: "wrap", umbrella: false };
  else outfit = { wearing: "light linen clothes", colour: pick(SUMMER, id), headwear: "none", umbrella: false };

  if (plan.place === "work" && job === "healer") outfit = { ...outfit, wearing: feels <= 9 ? `a healer's white coat over ${outfit.wearing}` : "a healer's white coat", colour: "#eef2f2" };
  else if (plan.place === "school") outfit = { ...outfit, wearing: feels <= 9 ? `${outfit.wearing} over a school smock` : "a school smock", colour: "#4f6f9a" };
  else if (job === "farmer" && plan.place === "work" && feels > 9) {
    outfit = { ...outfit, wearing: sunny && feels > 14 ? "work clothes and a straw hat" : "work clothes", colour: "#7a6a48", headwear: sunny && feels > 14 ? "straw" : outfit.headwear };
  } else if (job === "builder" && plan.place === "work" && feels > 9) outfit = { ...outfit, wearing: "sturdy work clothes", colour: "#5d6066" };

  if (outdoors && raining) {
    return weather.rain >= 0.62 || weather.wind >= 30
      ? { ...outfit, wearing: "a hooded raincoat", colour: "#c9a640", headwear: "hood" }
      : { ...outfit, wearing: `${outfit.wearing}, under an umbrella`, umbrella: true };
  }
  if (outdoors && snowing && feels > -12) return { ...outfit, wearing: `${outfit.wearing}, with snow boots` };
  return outfit;
}
