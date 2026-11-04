/**
 * EON demography model — single source of truth shared by the offline lab,
 * unit tests and (via identical constants in SQL) the Postgres engine.
 *
 * Time units: 1 EON year = 1440 ticks = 12 months; 1 month = 120 ticks.
 */
import params from "./params/demography.json";

export type DemographyParams = typeof params;
export const DEMOGRAPHY: DemographyParams = params;

export const MONTHS_PER_YEAR = 12;
export const MAX_MONTHS = params.maxAge * MONTHS_PER_YEAR; // 1320

export type HazardTerms = { infant: number; background: number; ageing: number };

/** Annual hazard split into its three named terms at age `x` (years). */
export function hazardTerms(x: number, p: DemographyParams = params): HazardTerms {
  const h = p.hazard;
  return {
    infant: h.infantA * Math.exp(-x / h.infantTau),
    background: h.makeham,
    ageing: h.gompertzB * Math.exp(h.gompertzC * x),
  };
}

export function hazard(x: number, p: DemographyParams = params): number {
  const t = hazardTerms(x, p);
  return t.infant + t.background + t.ageing;
}

/**
 * Monthly life table: cdf[m] = P(death before age m months), m = 0..MAX_MONTHS.
 * cdf[MAX_MONTHS] is forced to 1 (nobody lives past maxAge).
 * Integrates the hazard with 10 sub-steps per month (accurate to ~1e-6).
 */
export function buildLifeTable(p: DemographyParams = params, mortalityMult = 1): number[] {
  const months = p.maxAge * MONTHS_PER_YEAR;
  const cdf = new Array<number>(months + 1);
  cdf[0] = 0;
  let cumHazard = 0;
  const sub = 10;
  const dt = 1 / MONTHS_PER_YEAR / sub; // years
  for (let m = 0; m < months; m++) {
    for (let s = 0; s < sub; s++) {
      const x = (m + (s + 0.5) / sub) / MONTHS_PER_YEAR;
      cumHazard += hazard(x, p) * mortalityMult * dt;
    }
    cdf[m + 1] = 1 - Math.exp(-cumHazard);
  }
  cdf[months] = 1;
  return cdf;
}

/** Inverse CDF: age at death in (fractional) months for uniform u ∈ [0,1). */
export function fateMonths(u: number, cdf: number[]): number {
  if (u <= 0) return 0;
  let lo = 0;
  let hi = cdf.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (cdf[mid] < u) lo = mid;
    else hi = mid;
  }
  const span = cdf[hi] - cdf[lo];
  const frac = span > 0 ? (u - cdf[lo]) / span : 0;
  return lo + Math.min(1, Math.max(0, frac));
}

/** Conditional redraw for someone already alive at `ageMonths`, reusing their u. */
export function fateMonthsGivenAlive(u: number, ageMonths: number, cdf: number[]): number {
  const m = Math.floor(ageMonths);
  const fa = cdf[Math.min(m, cdf.length - 1)];
  const target = fa + u * (1 - fa);
  return Math.max(ageMonths, fateMonths(target, cdf));
}

/** Picks a named cause of death proportional to hazard terms at age `x`. u2, u3 ∈ [0,1). */
export function causeOfDeath(x: number, u2: number, u3: number, p: DemographyParams = params): string {
  const t = hazardTerms(x, p);
  const total = t.infant + t.background + t.ageing;
  let r = u2 * total;
  let group: keyof typeof p.causes = "ageing";
  if ((r -= t.infant) < 0) group = "infant";
  else if ((r -= t.background) < 0) group = "background";
  let options = p.causes[group] as [string, number][];
  if (group === "ageing" && x < p.causes.memoryLeakMinAge) {
    options = options.filter(([name]) => name !== "Memory Leak Syndrome");
  }
  const sum = options.reduce((a, [, w]) => a + w, 0);
  let q = u3 * sum;
  for (const [name, w] of options) {
    if ((q -= w) < 0) return name;
  }
  return options[options.length - 1][0];
}

/** Monthly conception probability for a woman of age `x` (years). */
export function conceptionMonthly(x: number, p: DemographyParams = params): number {
  for (const [lo, hi, prob] of p.fertility.conceptionMonthlyByAge) {
    if (x >= lo && x < hi + 1) return prob;
  }
  return 0;
}

/** Desired number of children after Genesis, given population N and capacity K. */
export function laterDesiredKidsMean(N: number, K: number, p: DemographyParams = params): number {
  const d = p.fertility.laterDesiredKids;
  return d.base + d.extra / (1 + Math.pow(N / K, d.power));
}

/** Life expectancy at birth (years) from a monthly CDF. */
export function lifeExpectancy(cdf: number[]): number {
  let e = 0;
  for (let m = 0; m < cdf.length - 1; m++) {
    const survStart = 1 - cdf[m];
    const survEnd = 1 - cdf[m + 1];
    e += (survStart + survEnd) / 2; // trapezoid, in months
  }
  return e / MONTHS_PER_YEAR;
}

/** Kinship guard: true if a and b are close kin (parent/child, grandparent, siblings, half-siblings, first cousins, aunt/uncle). */
export function isCloseKin(
  a: { id: number; lineage: readonly number[] },
  b: { id: number; lineage: readonly number[] },
): boolean {
  if (a.id === b.id) return true;
  if (a.lineage.includes(b.id) || b.lineage.includes(a.id)) return true;
  for (const x of a.lineage) if (b.lineage.includes(x)) return true;
  return false;
}

/** Child lineage = [mother, father] + mother's parents + father's parents. */
export function childLineage(
  mother: { id: number; lineage: readonly number[] },
  father: { id: number; lineage: readonly number[] },
): number[] {
  return [mother.id, father.id, ...mother.lineage.slice(0, 2), ...father.lineage.slice(0, 2)];
}

/** Small deterministic PRNG (mulberry32) for the lab and tests. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Standard normal via Box–Muller. */
export function normal(rand: () => number, mean = 0, sd = 1): number {
  const u = Math.max(rand(), 1e-12);
  const v = rand();
  return mean + sd * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}
