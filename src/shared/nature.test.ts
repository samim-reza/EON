import { describe, expect, it } from "vitest";
import type { Biome } from "./climate";
import { describeLand, FAUNA, faunaOf, landOf, looksOf, roughly, SKIN_TONES, wildlifeAt } from "./nature";

const land = { woods: 0.2, richness: 0.6, game: 200, beasts: 4, fish: 300, herd: 30 };
const place = { id: 3, x: 500, y: 500 };
const everywhere = () => true;
const BIOMES: Biome[] = ["ice", "tundra", "taiga", "mountain", "grassland", "forest", "rainforest", "desert", "savanna", "jungle"];

describe("fauna", () => {
  it("knows what lives in every kind of country the climate can produce", () => {
    for (const biome of BIOMES) expect(FAUNA[biome], biome).toBeDefined();
  });
  it("falls back to grassland for a country it has not heard of", () => {
    expect(faunaOf("moon")).toBe(FAUNA.grassland);
    expect(faunaOf(null)).toBe(FAUNA.grassland);
  });
});

describe("landOf", () => {
  it("reads the six numbers the API sends", () => {
    expect(landOf([0.2, 0.6, 200, 4, 300, 30])).toEqual(land);
  });
  it("refuses anything else, so an old server never breaks the map", () => {
    expect(landOf(undefined)).toBeNull();
    expect(landOf([1, 2, 3])).toBeNull();
    expect(landOf([0.2, 0.6, 200, 4, 300, Number.NaN])).toBeNull();
  });
});

describe("describeLand", () => {
  it("names the animals of the country", () => {
    const lines = describeLand(land, "savanna", 20);
    expect(lines.map((l) => l.label)).toEqual(["Woods", "Soil", "Antelope", "Lions", "Fish", "The village cattle"]);
  });
  it("says so when the woods are cut, the soil is tired and the herds are gone", () => {
    const lines = describeLand({ woods: 0.1, richness: 0.2, game: 10, beasts: 0, fish: 10, herd: 0 }, "forest", 300);
    expect(lines.filter((l) => l.tone === "bad").map((l) => l.label)).toEqual(["Woods", "Soil", "Deer"]);
    expect(lines.some((l) => l.label === "Wolves")).toBe(false);
  });
  it("does not blame anyone for a desert having no trees", () => {
    expect(describeLand({ ...land, woods: 0.01 }, "desert", 10)[0]).toEqual({ label: "Trees", text: "A few palm trees" });
  });
});

describe("roughly", () => {
  it("counts the way a villager would", () => {
    expect(roughly(0)).toBe("none");
    expect(roughly(3)).toBe("a few");
    expect(roughly(100)).toBe("about a hundred");
    expect(roughly(5000)).toBe("many hundreds");
  });
});

describe("wildlifeAt", () => {
  it("is the same for everyone looking at the same moment", () => {
    expect(wildlifeAt(place, land, 1234, 1, everywhere)).toEqual(wildlifeAt(place, land, 1234, 1, everywhere));
  });
  it("draws herds, hunters, livestock and birds, never more than a screen can take", () => {
    const all = wildlifeAt(place, { ...land, game: 100000, beasts: 500, herd: 9000 }, 100, 1, everywhere);
    const count = (k: string) => all.filter((c) => c.kind === k).length;
    expect(count("grazer")).toBe(36);
    expect(count("hunter")).toBe(6);
    expect(count("herd")).toBe(20);
    expect(count("bird")).toBe(5);
  });
  it("keeps every animal close to its village", () => {
    for (const c of wildlifeAt(place, land, 777, 1, everywhere)) expect(Math.hypot(c.x - place.x, c.y - place.y)).toBeLessThan(60);
  });
  it("keeps animals out of the sea, and birds on the wing only by day", () => {
    expect(wildlifeAt(place, land, 50, 1, () => false).every((c) => c.kind === "bird")).toBe(true);
    expect(wildlifeAt(place, land, 50, 0, everywhere).some((c) => c.kind === "bird")).toBe(false);
  });
  it("pens the village animals at night", () => {
    const reach = (daylight: number) => {
      const herd = wildlifeAt(place, land, 50, daylight, everywhere).filter((c) => c.kind === "herd");
      const cx = herd.reduce((a, c) => a + c.x, 0) / herd.length;
      const cy = herd.reduce((a, c) => a + c.y, 0) / herd.length;
      return Math.max(...herd.map((c) => Math.hypot(c.x - cx, c.y - cy)));
    };
    expect(reach(0)).toBeLessThan(reach(1));
  });
});

describe("looksOf", () => {
  it("puts a person's looks into words", () => {
    expect(looksOf([3, 0, 2, 1, 80, 50], 30)).toBe("Tall, with curly black hair, brown eyes and dark brown skin");
    expect(looksOf([0, 4, 0, 3, 20, 75], 25)).toBe("Short and sturdy, with straight fair hair, grey eyes and fair skin");
    expect(looksOf([2, 2, 1, 2, 50, 50], 40)).toBe("Of middling height, with wavy brown hair, hazel eyes and brown skin");
  });
  it("lets hair grey with age, and says little about a baby's", () => {
    expect(looksOf([2, 1, 1, 0, 50, 50], 50)).toContain("greying dark brown hair");
    expect(looksOf([2, 1, 1, 0, 50, 50], 70)).toContain("wavy grey hair");
    expect(looksOf([2, 1, 1, 0, 90, 90], 0.5)).toBe("A little dark brown hair, dark eyes and brown skin");
  });
  it("says nothing when there are no looks to describe", () => {
    expect(looksOf(null, 30)).toBeNull();
    expect(looksOf([1, 2], 30)).toBeNull();
  });
  it("has a map colour for every skin tone", () => {
    expect(SKIN_TONES).toHaveLength(5);
  });
});
