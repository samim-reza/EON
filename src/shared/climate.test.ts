import { describe, expect, it } from "vitest";
import { biomeOf, climateAt, hash3, moonAt, noise3, seasonCurve, springTide, sunElevation, sunTimes, ticksToFullMoon, tideAt, tideLabel, weatherAt, type Biome, type Climate, type Weather } from "./climate";
import { outfitFor, planFor, type Plan } from "./daily-life";
import golden from "./params/climate-golden.json";
import { makeWaters, makeWetness, sitesWithWater } from "./rivers";
import { ticksToHarvest } from "./time";
import { makeTerrain } from "./world";

const TUNE = { tempShift: 1.5, rainMult: 1.2 };
const climate = (over: Partial<Climate>): Climate => ({ lat: 35, elev: 0.1, tempMean: 18, tempSwing: 11, wet: 0.5, rainfall: 700, biome: "forest", ...over });
const sky = (over: Partial<Weather> = {}): Weather => ({ temp: 20, high: 24, low: 14, cloud: 0, rain: 0, wind: 8, kind: "clear", heatwave: false, coldSnap: false, ...over });

describe("the twin in Postgres", () => {
  it("hash3 and noise3 match the golden vectors", () => {
    for (const h of golden.hashes) expect(hash3(h.in[0], h.in[1], h.in[2], h.in[3])).toBe(h.out);
    for (const n of golden.noises) expect(noise3(n.in[0], n.in[1], n.in[2], n.in[3])).toBeCloseTo(n.out, 8);
    for (const t of golden.tides) expect(springTide(t.in[0], t.in[1])).toBeCloseTo(t.out, 8);
  });

  it("climate and weather match the golden vectors", () => {
    for (const v of golden.weather) {
      const { seed, x, y, elev, tf } = v.in;
      const c = climateAt(seed, x, y, elev);
      const w = weatherAt(seed, c, x, y, tf, TUNE);
      expect(c.biome).toBe(v.climate.biome);
      expect(c.tempMean).toBeCloseTo(v.climate.tempMean, 8);
      expect(w.kind).toBe(v.weather.kind);
      expect(w.temp).toBeCloseTo(v.weather.temp, 8);
      expect(w.rain).toBeCloseTo(v.weather.rain, 8);
      expect(w.wind).toBeCloseTo(v.weather.wind, 8);
    }
  });
});

describe("sun and moon", () => {
  it("stands overhead at the equator at noon on the equinox", () => {
    expect(sunElevation(1, 0, 500)).toBeCloseTo(90, 0); // tick 1 = 12:00 on the first day of spring
  });

  it("is below the horizon at midnight", () => {
    expect(sunElevation(3, 35, 500)).toBeLessThan(-20);
  });

  it("gives long summer days and short winter days", () => {
    const summer = sunTimes(360, 50);
    const winter = sunTimes(1080, 50);
    expect(summer.set - summer.rise).toBeGreaterThan(15);
    expect(winter.set - winter.rise).toBeLessThan(9);
  });

  it("has a midnight sun and a polar night in the far north", () => {
    expect(sunTimes(360, 72).polar).toBe("day");
    expect(sunTimes(1080, 72).polar).toBe("night");
  });

  it("rises in the east first", () => {
    expect(sunElevation(0, 35, 900)).toBeGreaterThan(sunElevation(0, 35, 100));
  });

  it("goes through full and new moons every 29.5 days", () => {
    const light = Array.from({ length: 120 }, (_, i) => moonAt(5, i, 35, 500).light);
    expect(Math.max(...light)).toBeGreaterThan(0.99);
    expect(Math.min(...light)).toBeLessThan(0.01);
  });
});

describe("climate", () => {
  it("makes summer warmer than winter", () => {
    expect(seasonCurve(480)).toBeCloseTo(1, 1);
    expect(seasonCurve(1200)).toBeCloseTo(-1, 1);
  });

  it("sorts the world into biomes by warmth and rain", () => {
    expect(biomeOf(26, 150, 0.1)).toBe("desert");
    expect(biomeOf(26, 2400, 0.1)).toBe("jungle");
    expect(biomeOf(24, 600, 0.1)).toBe("savanna");
    expect(biomeOf(12, 900, 0.1)).toBe("forest");
    expect(biomeOf(2, 500, 0.1)).toBe("taiga");
    expect(biomeOf(-5, 300, 0.1)).toBe("tundra");
    expect(biomeOf(-14, 300, 0.1)).toBe("ice");
    expect(biomeOf(8, 700, 0.6)).toBe("mountain");
  });

  it("cools with height", () => {
    expect(climateAt(9, 500, 500, 0.5).tempMean).toBeLessThan(climateAt(9, 500, 500, 0.1).tempMean - 5);
  });
});

describe("weather", () => {
  const share = (c: Climate, test: (w: Weather) => boolean) => {
    let hits = 0;
    let all = 0;
    for (let tf = 0; tf < 1440 * 12; tf += 3.7) {
      all++;
      if (test(weatherAt(17, c, 400, 400, tf))) hits++;
    }
    return hits / all;
  };

  it("is the same for everyone who asks", () => {
    const c = climate({});
    expect(weatherAt(3, c, 200, 300, 1234.5)).toEqual(weatherAt(3, c, 200, 300, 1234.5));
  });

  it("rains in a jungle far more than in a desert", () => {
    const rainy = (w: Weather) => w.rain > 0.08;
    const jungle = share(climate({ lat: 8, tempMean: 26, tempSwing: 3, wet: 0.95, rainfall: 2500, biome: "jungle" }), rainy);
    const desert = share(climate({ lat: 25, tempMean: 24, tempSwing: 12, wet: 0.12, rainfall: 100, biome: "desert" }), rainy);
    expect(jungle).toBeGreaterThan(0.35);
    expect(desert).toBeLessThan(0.05);
  });

  it("falls as snow only in the cold", () => {
    const c = climate({ lat: 55, tempMean: 3, tempSwing: 15, wet: 0.6, rainfall: 900, biome: "taiga" });
    for (let tf = 0; tf < 1440 * 3; tf += 3.7) {
      const w = weatherAt(17, c, 400, 400, tf);
      if (w.kind === "snow" || w.kind === "blizzard") expect(w.temp).toBeLessThanOrEqual(0.5);
      if (w.kind === "thunderstorm") expect(w.temp).toBeGreaterThanOrEqual(16);
    }
  });

  it("whips up sandstorms only in the desert", () => {
    const stormy = (w: Weather) => w.kind === "sandstorm";
    expect(share(climate({ lat: 25, tempMean: 24, wet: 0.12, rainfall: 100, biome: "desert" }), stormy)).toBeGreaterThan(0);
    expect(share(climate({}), stormy)).toBe(0);
  });

  it("obeys God: no rain at zero, warmer when told", () => {
    const c = climate({ rainfall: 2000, wet: 0.9 });
    const dry = { tempShift: 0, rainMult: 0 };
    for (let tf = 0; tf < 1440; tf += 3.7) expect(weatherAt(17, c, 400, 400, tf, dry).rain).toBeLessThan(0.01);
    const base = weatherAt(17, c, 400, 400, 500);
    expect(weatherAt(17, c, 400, 400, 500, { tempShift: 5, rainMult: 1 }).temp).toBeCloseTo(base.temp + 5, 6);
  });

  it("dries out cloud, and swings hardest in dry air", () => {
    const hot = weatherAt(17, climate({ wet: 0.05 }), 400, 400, 500);
    const humid = weatherAt(17, climate({ wet: 0.95 }), 400, 400, 500);
    expect(hot.high - hot.low).toBeGreaterThan(humid.high - humid.low);
  });
});

describe("what is coming up", () => {
  it("counts down to the next full moon", () => {
    for (const tf of [0, 57.5, 300, 1234.25]) {
      const left = ticksToFullMoon(5, tf);
      expect(left).toBeLessThanOrEqual(118.12);
      expect(moonAt(5, tf + left, 35, 500).light).toBeCloseTo(1, 6);
    }
  });

  it("counts down to the next harvest, then the one after", () => {
    expect(ticksToHarvest(0)).toBe(720);
    expect(ticksToHarvest(700)).toBe(20);
    expect(ticksToHarvest(721)).toBe(1439);
    expect(ticksToHarvest(1440 * 3 + 700)).toBe(20);
  });
});

describe("a day in a life", () => {
  const farmer = { id: 8, job: "farmer", ageYears: 30 };

  it("sleeps at night and works by day", () => {
    expect(planFor(farmer, 2, 40, 3, sky()).asleep).toBe(true);
    expect(planFor(farmer, 10, 40, 3, sky()).place).toBe("work");
    expect(planFor(farmer, 23.9, 40, 3, sky()).asleep).toBe(true);
  });

  it("sends children to school and keeps babies at home", () => {
    expect(planFor({ id: 2, job: "child", ageYears: 9 }, 10, 40, 3, sky()).place).toBe("school");
    expect(planFor({ id: 2, job: "baby", ageYears: 1 }, 10, 40, 3, sky()).place).toBe("home");
  });

  it("drives people indoors in a storm, except healers", () => {
    const storm = sky({ kind: "thunderstorm", rain: 0.9, temp: 22 });
    expect(planFor(farmer, 10, 40, 3, storm).doing).toBe("Sheltering from the storm");
    expect(planFor({ id: 8, job: "healer", ageYears: 30 }, 10, 40, 3, storm).place).toBe("work");
  });

  it("rests through the hottest hours", () => {
    expect(planFor(farmer, 13, 40, 3, sky({ temp: 41 })).doing).toBe("Resting in the shade");
  });

  it("brings in the harvest in autumn and mends tools in deep winter", () => {
    expect(planFor(farmer, 10, 40, 6, sky()).doing).toBe("Bringing in the harvest");
    expect(planFor(farmer, 10, 40, 10, sky({ temp: -2 })).doing).toBe("Mending tools for spring");
  });
});

describe("tides", () => {
  it("rises and falls twice a day, with the moon", () => {
    const heights = Array.from({ length: 480 }, (_, i) => tideAt(9, 400 + i / 40, 500)); // 12 ticks = 3 days
    let highs = 0;
    for (let i = 1; i < heights.length - 1; i++) if (heights[i] > heights[i - 1] && heights[i] >= heights[i + 1]) highs++;
    expect(highs).toBeGreaterThanOrEqual(5); // a tide about every 12.4 hours
    expect(highs).toBeLessThanOrEqual(6);
  });

  it("is strongest at new and full moon", () => {
    const range = (from: number) => Math.max(...Array.from({ length: 16 }, (_, i) => Math.abs(tideAt(5, from + i / 3, 500))));
    const springs: number[] = [];
    const neaps: number[] = [];
    for (let tf = 0; tf < 240; tf += 2) (springTide(5, tf) > 0.95 ? springs : springTide(5, tf) < 0.1 ? neaps : []).push(tf);
    expect(range(springs[0])).toBeGreaterThan(range(neaps[0]) + 0.2);
  });

  it("names what the sea is doing", () => {
    const seen = new Set(Array.from({ length: 400 }, (_, i) => tideLabel(5, i * 0.13, 500)));
    expect(seen.has("Tide coming in")).toBe(true);
    expect(seen.has("Tide going out")).toBe(true);
  });
});

describe("what people wear", () => {
  const adult = { id: 12, job: "builder", ageYears: 30 };
  const street: Plan = { place: "market", doing: "At the market", indoors: false };
  const dress = (weather: Partial<Weather>, biome: Biome = "forest", plan: Plan = street, person = adult) => outfitFor(person, plan, sky(weather), biome);

  it("dresses for the cold", () => {
    expect(dress({ temp: -20 }).wearing).toContain("parka");
    expect(dress({ temp: -4 }).wearing).toContain("wool coat");
    expect(dress({ temp: 6 }).wearing).toBe("a warm coat");
    expect(dress({ temp: 14 }).wearing).toBe("a light jacket");
    expect(dress({ temp: 22 }).wearing).toBe("everyday clothes");
    expect(dress({ temp: 33 }).wearing).toBe("light linen clothes");
  });

  it("counts the wind", () => {
    expect(dress({ temp: 2, wind: 8 }).wearing).toBe("a warm coat");
    expect(dress({ temp: 2, wind: 40 }).wearing).toContain("wool coat");
  });

  it("wears robes in the desert sun", () => {
    const robes = dress({ temp: 40 }, "desert");
    expect(robes.wearing).toContain("robes");
    expect(robes.headwear).toBe("wrap");
  });

  it("takes an umbrella in light rain and a raincoat in heavy rain, but only outdoors", () => {
    expect(dress({ temp: 18, rain: 0.3, kind: "rain", cloud: 1 }).umbrella).toBe(true);
    expect(dress({ temp: 18, rain: 0.7, kind: "downpour", cloud: 1 }).wearing).toBe("a hooded raincoat");
    const home: Plan = { place: "home", doing: "Relaxing at home", indoors: true };
    expect(dress({ temp: 18, rain: 0.3, kind: "rain", cloud: 1 }, "forest", home).umbrella).toBe(false);
  });

  it("dresses for the job", () => {
    const work: Plan = { place: "work", doing: "Working", indoors: true };
    expect(dress({ temp: 22 }, "forest", work, { id: 3, job: "healer", ageYears: 40 }).wearing).toBe("a healer's white coat");
    const field: Plan = { place: "work", doing: "Working on the farm", indoors: false };
    expect(dress({ temp: 24 }, "forest", field, { id: 3, job: "farmer", ageYears: 40 }).headwear).toBe("straw");
  });

  it("changes for bed", () => {
    expect(dress({ temp: -20 }, "forest", { place: "home", doing: "Asleep at home", indoors: true, asleep: true }).wearing).toBe("night clothes");
  });
});

describe("rivers", () => {
  const seed = 1257650109;
  const { elevation } = makeTerrain(seed);
  const waters = makeWaters(seed, elevation, makeWetness(seed));

  it("always reach the sea", () => {
    for (let c = 0; c < waters.next.length; c += 397) {
      let at = c;
      let steps = 0;
      while (waters.next[at] >= 0 && steps++ < 250000) at = waters.next[at];
      expect(waters.next[at]).toBe(-1);
    }
  });

  it("grow as they gather water", () => {
    let grown = 0;
    let checked = 0;
    for (let c = 0; c < waters.next.length; c++) {
      const to = waters.next[c];
      if (to < 0 || waters.flow[c] < 100) continue;
      checked++;
      if (waters.flow[to] >= waters.flow[c]) grown++;
    }
    expect(checked).toBeGreaterThan(500);
    expect(grown).toBe(checked);
  });

  it("form rivers and lakes on real land", () => {
    expect(waters.segmentCount).toBeGreaterThan(500);
    expect(waters.lake.some((depth) => depth > 0)).toBe(true);
  });

  it("are the same for everyone", () => {
    const again = makeWaters(seed, elevation, makeWetness(seed));
    expect(again.segmentCount).toBe(waters.segmentCount);
    expect(again.segments.slice(0, 700)).toEqual(waters.segments.slice(0, 700));
  });

  it("tell each site about the water around it", () => {
    const sites = sitesWithWater(seed);
    expect(sites.some((s) => s[5] > 0)).toBe(true);
    expect(sites.some((s) => s[6])).toBe(true);
    for (const s of sites) expect(s[5]).toBeLessThanOrEqual(1);
  });
});
