export type StatsRow = {
  tick: number;
  population: number;
  births: number;
  deaths: number;
  pregnant: number;
  sick: number;
  avg_wealth: number;
};

export type NowState = {
  tick: number;
  paused: boolean;
  genesis: boolean;
  seed: string;
  rosterVersion: number;
  year: number;
  dayOfYear: number;
  month: number;
  phase: number;
  genesisEra: boolean;
  lastTickMs: number;
  stats: StatsRow | null;
  settlements: number;
  /** God's climate sliders. Absent until the climate migration has run. */
  tune?: { tempShift: number; rainMult: number };
};

export type FeedEvent = {
  id: number;
  tick: number;
  kind: string;
  imp: number;
  agent: number | null;
  other: number | null;
  settlement: number | null;
  data: Record<string, unknown>;
  agentName: string | null;
  otherName: string | null;
  settlementName?: string | null;
};

export type ChronicleEntry = Omit<FeedEvent, "imp" | "settlement">;

export type Roster = {
  version: number;
  tick: number;
  id: number[];
  name: string[];
  sex: ("F" | "M")[];
  birth: number[];
  settlement: number[];
  home: (number | null)[];
  job: string[];
  partner: (number | null)[];
  flags: number[];
};

export const FLAG_PLAYER = 1;
export const FLAG_FOUNDER = 2;
export const FLAG_PREGNANT = 4;
export const FLAG_SICK = 8;

export type Settlement = {
  id: number;
  name: string;
  kind: "village" | "town" | "city";
  x: number;
  y: number;
  region: number;
  founded: number;
  pop: number;
  /** Food stores: 1 is a normal year. */
  food?: number;
};

/** [id, settlementId, kind, x, y] */
export type BuildingTuple = [number, number, string, number, number];

export type Geo = { seed: string; settlements: Settlement[]; buildings: BuildingTuple[] };

export type PersonRef = { id: number; name: string; alive?: boolean; birthTick?: number };

export type StoryEntry = {
  tick: number;
  kind: string;
  agent: number | null;
  agentName: string | null;
  other: number | null;
  otherName: string | null;
  data: Record<string, unknown>;
};

export type AgentDetail = {
  id: number;
  name: string;
  surname: string;
  sex: "F" | "M";
  alive: boolean;
  birthTick: number;
  deathTick: number | null;
  cause: string | null;
  age: number;
  generation: number;
  founder: boolean;
  occupation: string | null;
  kids: number;
  isPlayer: boolean;
  settlement: { id: number; name: string; kind: string; x?: number; y?: number; food?: number } | null;
  mother: PersonRef | null;
  father: PersonRef | null;
  partner?: PersonRef | null;
  traits?: Record<string, number>;
  health?: number;
  happiness?: number;
  wealth?: number;
  education?: number;
  reputation?: number;
  diagnosed?: string | null;
  homeId?: number | null;
  pregnant?: boolean;
  /** When the baby is due, so the wait is visible. */
  dueTick?: number | null;
  sick?: string[];
  children: PersonRef[];
  story: StoryEntry[];
};

export type FamilyPerson = {
  id: number;
  name: string;
  sex: "F" | "M";
  alive: boolean;
  mother: number | null;
  father: number | null;
  birthTick: number;
  deathTick: number | null;
  gen: number;
};

export type FamilyTree = { root: number; people: FamilyPerson[] };
