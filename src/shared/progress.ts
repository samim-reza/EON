/** The ages of history and what each kind of place is called. The discoveries themselves live in the database. */
export const AGES = ["The First Days", "The Age of Farming", "The Age of Villages", "The Age of Towns", "The Age of Industry", "The Modern Age"] as const;

export const ageName = (age: number | undefined) => AGES[Math.max(0, Math.min(AGES.length, age ?? 1) - 1)];

/** What people call each building, on the map and in sentences. */
export const PLACE_NAMES: Record<string, string> = {
  hall: "Gathering place",
  home: "House",
  farm: "Field",
  workshop: "Workshop",
  clinic: "Clinic",
  market: "Market",
  temple: "Temple",
  school: "School",
  smithy: "Smithy",
  mill: "Mill",
  library: "Library",
  factory: "Factory",
  station: "Station",
};

/** Which discovery makes each building possible. */
const NEEDS: Record<string, string> = {
  farm: "farming", workshop: "tools", clinic: "herbs", market: "trade", temple: "worship", school: "writing",
  smithy: "iron", mill: "mills", library: "printing", factory: "steam", station: "railways",
};

/** Could this building exist yet? Worlds from before progress existed report nothing, and have everything. */
export function knownBuildings(known: string[] | undefined) {
  return (kind: string) => !known || !NEEDS[kind] || known.includes(NEEDS[kind]);
}

/** 1 footpaths, 2 dirt roads between villages, 3 paved roads, 4 railways. */
export function roadTier(known: string[] | undefined) {
  if (known?.includes("railways")) return 4;
  if (known?.includes("paving")) return 3;
  if (known?.includes("roads")) return 2;
  return 1;
}
