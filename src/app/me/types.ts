import type { Choice } from "@/shared/choices";
import type { ProviderId } from "@/shared/providers";
import type { FeedEvent } from "@/shared/types";

export type KeyInfo = { provider: ProviderId; model: string; last4: string; status: "ok" | "limited" | "error" | "invalid"; cap: number; used: number };
type Kin = { id: number; name: string; alive?: boolean };
export type Person = {
  id: number; sex: "F" | "M"; birthTick: number; work: string; health: number; happiness: number; wealth: number; piety: number;
  calling?: string; place?: string; mother?: Kin; father?: Kin; partner?: Kin; children: Kin[]; need?: string; openPrayer: boolean;
  /** Good deeds, ill deeds not yet repented of, and ill deeds laid down. Absent before the age of reckoning. */
  record?: { good: number; ill: number; mended: number };
  /** The Whisperer keeps away until this tick, after refuge was sought. */
  refuge?: number;
};
export type Life = {
  tick: number; key: KeyInfo | null; freeDays: boolean; expecting: number;
  status?: "waiting" | "assigned" | "living" | "ended"; agent?: number | null; dueTick?: number | null;
  mother?: string | null; father?: string | null; place?: string | null; name?: string | null;
  mind?: "world" | "own" | "none"; trialUntil?: number | null; bornTick?: number | null;
  person?: Person; choices?: Choice[]; thoughts?: { tick: number; kind: string; body: string; question?: string }[];
  deeds?: { id: string; label: string; other?: number }[]; deedsLeft?: number; asksLeft?: number; asking?: boolean;
  done?: { tick: number; kind: string; told: string }[];
  prayers?: { tick: number; need: string; words?: string; status: string }[]; happened?: FeedEvent[];
  /** How the last life weighed, once it has ended. */
  reckoning?: "light" | "even" | "heavy" | "child" | null;
};
