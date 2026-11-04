/**
 * EON demography lab — month-granularity Monte Carlo of the same rules the
 * Postgres engine uses (fate-at-birth mortality, kin-blocked partnering,
 * age-banded conception, Genesis founder couples, capacity-damped family size).
 */
import {
  DEMOGRAPHY as P,
  buildLifeTable,
  childLineage,
  conceptionMonthly,
  fateMonths,
  fateMonthsGivenAlive,
  isCloseKin,
  laterDesiredKidsMean,
  mulberry32,
  normal,
} from "../src/shared/demography";

type Agent = {
  id: number;
  sex: "F" | "M";
  birth: number; // absolute month
  fate: number; // absolute month of death
  lineage: number[];
  partner: number | null;
  desiredKids: number;
  kids: number;
  fertileAfter: number;
  pregnantDue: number | null;
  pregnantFather: number | null;
};

export type LabResult = {
  seed: number;
  years: number;
  K: number;
  popByDecade: number[];
  finalPop: number;
  peakPop: number;
  births: number;
  cohortE0: number;
  under5Share: number;
  maxFateAge: number;
  extinct: boolean;
  kinViolations: number;
};

export function runLab(seed: number, years = 300, K: number = P.capacity.defaultK): LabResult {
  const rand = mulberry32(seed);
  const cdf = buildLifeTable();
  const alive = new Map<number, Agent>();
  let nextId = 1;
  let births = 0;
  let fateSum = 0;
  let under5 = 0;
  let maxFateAge = 0;
  let kinViolations = 0;
  let peakPop = 0;
  const popByDecade: number[] = [];
  const fert = P.fertility;
  const genesisMonths = P.genesis.years * 12;

  const makeAdult = (sex: "F" | "M", birth: number, nowMonth: number): Agent => {
    const ageM = nowMonth - birth;
    const fate = birth + fateMonthsGivenAlive(rand(), ageM, cdf);
    return { id: nextId++, sex, birth, fate, lineage: [], partner: null, desiredKids: 0, kids: 0, fertileAfter: 0, pregnantDue: null, pregnantFather: null };
  };

  const desiredKids = (month: number): number => {
    if (month < genesisMonths) {
      const g = fert.genesisDesiredKids;
      return Math.max(0, Math.round(normal(rand, g.mean, g.sd)));
    }
    return Math.max(0, Math.round(normal(rand, laterDesiredKidsMean(alive.size, K), 1)));
  };

  const totalMonths = years * 12;
  for (let m = 0; m <= totalMonths; m++) {
    // Genesis: one unrelated founder couple per EON year (the first at month 0 is God's Adam & Eve equivalent).
    if (m < genesisMonths && m % 12 === 0) {
      for (let c = 0; c < P.genesis.foundersCouplesPerYear; c++) {
        const span = P.genesis.founderAgeMax - P.genesis.founderAgeMin;
        const ageF = (P.genesis.founderAgeMin + rand() * span) * 12;
        const ageM = (P.genesis.founderAgeMin + rand() * span) * 12;
        const f = makeAdult("F", m - ageF, m);
        const h = makeAdult("M", m - ageM, m);
        alive.set(f.id, f);
        alive.set(h.id, h);
      }
    }

    // Deaths (fate reached)
    for (const a of [...alive.values()]) {
      if (a.fate <= m) {
        alive.delete(a.id);
        if (a.partner !== null) {
          const p = alive.get(a.partner);
          if (p) p.partner = null;
        }
      }
    }

    // Births
    for (const mother of [...alive.values()]) {
      if (mother.pregnantDue !== null && mother.pregnantDue <= m) {
        const fatherId = mother.pregnantFather!;
        const father = alive.get(fatherId) ?? { id: fatherId, lineage: [] as number[] };
        const n = rand() < fert.twinChance ? 2 : 1;
        for (let k = 0; k < n; k++) {
          const fateAge = fateMonths(rand(), cdf);
          const child: Agent = {
            id: nextId++, sex: rand() < 0.5 ? "F" : "M", birth: m, fate: m + fateAge,
            lineage: childLineage(mother, father), partner: null, desiredKids: 0, kids: 0,
            fertileAfter: 0, pregnantDue: null, pregnantFather: null,
          };
          alive.set(child.id, child);
          births++;
          fateSum += fateAge / 12;
          if (fateAge < 60) under5++;
          maxFateAge = Math.max(maxFateAge, fateAge / 12);
        }
        mother.kids += n;
        const f = alive.get(fatherId);
        if (f) f.kids += n;
        mother.pregnantDue = null;
        mother.pregnantFather = null;
        mother.fertileAfter = m + fert.postpartumMonths;
      }
    }

    // Partnering (monthly chance per single adult; kin-blocked; age gap limit)
    const singles = [...alive.values()].filter((a) => a.partner === null && m - a.birth >= fert.partnerMinAge * 12);
    const singleF = singles.filter((a) => a.sex === "F");
    const singleM = singles.filter((a) => a.sex === "M");
    for (const s of singles) {
      if (s.partner !== null || rand() >= fert.matchChanceMonthly) continue;
      const pool = s.sex === "F" ? singleM : singleF;
      for (let tries = 0; tries < 20 && pool.length > 0; tries++) {
        const c = pool[Math.floor(rand() * pool.length)];
        if (c.partner !== null) continue;
        if (Math.abs(c.birth - s.birth) > fert.maxAgeGap * 12) continue;
        if (isCloseKin(s, c)) continue;
        s.partner = c.id;
        c.partner = s.id;
        const d = desiredKids(m);
        s.desiredKids = d;
        c.desiredKids = d;
        break;
      }
    }

    // Conception
    for (const w of alive.values()) {
      if (w.sex !== "F" || w.partner === null || w.pregnantDue !== null || m < w.fertileAfter) continue;
      if (w.kids >= w.desiredKids) continue;
      const age = (m - w.birth) / 12;
      if (rand() < conceptionMonthly(age)) {
        w.pregnantDue = m + fert.pregnancyTicks / P.ticksPerMonth;
        w.pregnantFather = w.partner;
        const h = alive.get(w.partner);
        if (h && isCloseKin(w, h)) kinViolations++;
      }
    }

    peakPop = Math.max(peakPop, alive.size);
    if (m % 120 === 0) popByDecade.push(alive.size);
    if (alive.size === 0 && m > genesisMonths) break;
  }

  return {
    seed, years, K, popByDecade, finalPop: alive.size, peakPop, births,
    cohortE0: births ? fateSum / births : 0,
    under5Share: births ? under5 / births : 0,
    maxFateAge,
    extinct: alive.size === 0,
    kinViolations,
  };
}
