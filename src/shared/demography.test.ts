import { describe, expect, it } from "vitest";
import {
  buildLifeTable,
  causeOfDeath,
  childLineage,
  conceptionMonthly,
  fateMonths,
  fateMonthsGivenAlive,
  isCloseKin,
  lifeExpectancy,
  MAX_MONTHS,
} from "./demography";
import { runLab } from "../../lab/sim";

describe("life table", () => {
  const cdf = buildLifeTable();

  it("hits the calibration targets", () => {
    expect(lifeExpectancy(cdf)).toBeGreaterThan(58);
    expect(lifeExpectancy(cdf)).toBeLessThan(62);
    expect(cdf[60]).toBeGreaterThan(0.02); // die before 5
    expect(cdf[60]).toBeLessThan(0.04);
    expect(1 - cdf[1200]).toBeLessThan(0.005); // alive at 100
    expect(cdf[MAX_MONTHS]).toBe(1);
  });

  it("is monotonic", () => {
    for (let m = 1; m < cdf.length; m++) expect(cdf[m]).toBeGreaterThanOrEqual(cdf[m - 1]);
  });

  it("inverse CDF never exceeds max age and is monotonic in u", () => {
    let prev = -1;
    for (let u = 0; u < 1; u += 0.01) {
      const f = fateMonths(u, cdf);
      expect(f).toBeLessThanOrEqual(MAX_MONTHS);
      expect(f).toBeGreaterThanOrEqual(prev);
      prev = f;
    }
  });

  it("conditional redraw never kills someone in the past", () => {
    for (const age of [0, 120, 600, 900, 1200, 1319]) {
      for (const u of [0, 0.3, 0.99]) expect(fateMonthsGivenAlive(u, age, cdf)).toBeGreaterThanOrEqual(age);
    }
  });

  it("higher mortality slider shortens lives", () => {
    expect(lifeExpectancy(buildLifeTable(undefined, 1.5))).toBeLessThan(lifeExpectancy(cdf));
  });
});

describe("causes", () => {
  it("infants mostly die of Boot Failure, elders of ageing causes", () => {
    expect(causeOfDeath(0.05, 0.01, 0.5)).toBe("Boot Failure");
    expect(["Core Arrest", "Battery Rot", "Memory Leak Syndrome", "Wear-out"]).toContain(causeOfDeath(85, 0.99, 0.5));
  });
  it("no Memory Leak Syndrome before 65", () => {
    for (let u = 0; u < 1; u += 0.02) expect(causeOfDeath(40, 0.999, u)).not.toBe("Memory Leak Syndrome");
  });
});

describe("kinship", () => {
  const gpa = { id: 1, lineage: [] }, gma = { id: 2, lineage: [] };
  const gpb = { id: 3, lineage: [] }, gmb = { id: 4, lineage: [] };
  const mom = { id: 5, lineage: childLineage(gma, gpa) };
  const aunt = { id: 6, lineage: childLineage(gma, gpa) };
  const dad = { id: 7, lineage: childLineage(gmb, gpb) };
  const uncleInLaw = { id: 8, lineage: [] };
  const kid = { id: 9, lineage: childLineage(mom, dad) };
  const sib = { id: 10, lineage: childLineage(mom, dad) };
  const cousin = { id: 11, lineage: childLineage(aunt, uncleInLaw) };
  const stranger = { id: 12, lineage: [] };

  it("blocks parent/child, grandparent, siblings, cousins, aunt", () => {
    expect(isCloseKin(kid, mom)).toBe(true);
    expect(isCloseKin(kid, gpa)).toBe(true);
    expect(isCloseKin(kid, sib)).toBe(true);
    expect(isCloseKin(kid, cousin)).toBe(true);
    expect(isCloseKin(kid, aunt)).toBe(true);
    expect(isCloseKin(mom, aunt)).toBe(true);
  });
  it("allows strangers and in-laws", () => {
    expect(isCloseKin(kid, stranger)).toBe(false);
    expect(isCloseKin(mom, dad)).toBe(false);
  });
});

describe("fertility", () => {
  it("is zero outside fertile ages", () => {
    expect(conceptionMonthly(15)).toBe(0);
    expect(conceptionMonthly(48.5)).toBe(0);
    expect(conceptionMonthly(25)).toBeCloseTo(0.15);
  });
});

describe("lab", () => {
  it("a 150-year world from Genesis grows, survives and never pairs kin", () => {
    const r = runLab(42, 150);
    expect(r.extinct).toBe(false);
    expect(r.kinViolations).toBe(0);
    expect(r.finalPop).toBeGreaterThan(500);
    expect(r.cohortE0).toBeGreaterThan(56);
    expect(r.cohortE0).toBeLessThan(64);
  });
});
