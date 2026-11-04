import { describe, expect, it } from "vitest";
import { decodeNav, encodeNav } from "./nav-cookie";
import { advanceAnchor, eonClock, eonDate, formatAge, formatAgeExact, tickAt, TICKS_PER_DAY, TICKS_PER_MONTH, TICKS_PER_YEAR } from "./time";

describe("EON calendar", () => {
  it("advances from day to month to year", () => {
    expect(eonDate(0)).toMatchObject({ year: 0, monthName: "Thaw", day: 1, phaseName: "Morning" });
    expect(eonDate(TICKS_PER_DAY)).toMatchObject({ year: 0, day: 2 });
    expect(eonDate(TICKS_PER_MONTH)).toMatchObject({ year: 0, monthName: "Bloom", day: 1 });
    expect(eonDate(TICKS_PER_YEAR)).toMatchObject({ year: 1, monthName: "Thaw", day: 1 });
  });

  it("reads a 24-hour clock across one day", () => {
    expect([0, 1, 2, 3].map((t) => eonClock(t).time)).toEqual(["06:00", "12:00", "18:00", "00:00"]);
    expect(eonClock(0.5).time).toBe("09:00");
    expect(eonClock(3.5).time).toBe("03:00");
  });

  it("changes the date at midnight, not at dawn", () => {
    expect(eonClock(2.9)).toMatchObject({ day: 1, phaseName: "Evening" });
    expect(eonClock(3)).toMatchObject({ day: 2, phaseName: "Night", time: "00:00" });
    expect(eonClock(4)).toMatchObject({ day: 2, phaseName: "Morning", time: "06:00" });
  });

  it("rolls into the next year at the last midnight", () => {
    expect(eonClock(TICKS_PER_YEAR - 1)).toMatchObject({ year: 1, monthName: "Thaw", day: 1 });
  });
});

describe("age", () => {
  it("shows months and years, and counts months up", () => {
    expect(formatAge(0)).toBe("0 months");
    expect(formatAge(1 / 12)).toBe("1 month");
    expect(formatAge(1)).toBe("1 year");
    expect(formatAge(22 + 3 / 12)).toBe("22 years, 3 months");
    expect(formatAge(1 + 1 / 12)).toBe("1 year, 1 month");
  });

  it("grows by one month every 120 ticks", () => {
    const birth = 100;
    const ageAt = (tick: number) => formatAge((tick - birth) / TICKS_PER_YEAR);
    expect(ageAt(birth + 119)).toBe("0 months");
    expect(ageAt(birth + 120)).toBe("1 month");
    expect(ageAt(birth + TICKS_PER_YEAR)).toBe("1 year");
  });
});

describe("exact age", () => {
  it("counts days, months and years", () => {
    expect(formatAgeExact(0)).toBe("0 days");
    expect(formatAgeExact(TICKS_PER_DAY * 4)).toBe("4 days");
    expect(formatAgeExact(TICKS_PER_MONTH + TICKS_PER_DAY)).toBe("1 month, 1 day");
    expect(formatAgeExact(TICKS_PER_YEAR * 20)).toBe("20 years, 0 months, 0 days");
  });

  it("gains a day every 4 ticks, so a founder visibly ages within minutes", () => {
    const born = -28800;
    expect(formatAgeExact(3 - born)).toBe("20 years, 0 months, 0 days");
    expect(formatAgeExact(4 - born)).toBe("20 years, 0 months, 1 day");
    expect(formatAgeExact(17 - born)).toBe("20 years, 0 months, 4 days");
  });
});

describe("dead-reckoned world time", () => {
  const start = { tick: 100, at: 0 };

  it("runs at one tick per real minute between polls", () => {
    expect(tickAt(start, 30_000)).toBe(100.5);
    expect(tickAt(start, 90_000)).toBe(101.5);
  });

  it("stands still while the world is paused", () => {
    expect(tickAt(start, 90_000, true)).toBe(100);
  });

  it("never runs backwards on a stale reply", () => {
    expect(advanceAnchor(start, 100, 40_000)).toBe(start);
  });

  it("jumps forward when the server is ahead", () => {
    expect(advanceAnchor(start, 103, 40_000)).toEqual({ tick: 103, at: 40_000 });
  });

  it("corrects itself after drifting well ahead of the server", () => {
    expect(advanceAnchor(start, 100, 120_000)).toEqual({ tick: 100, at: 120_000 });
  });

  it("re-anchors on every poll while paused", () => {
    expect(advanceAnchor(start, 100, 40_000, true)).toEqual({ tick: 100, at: 40_000 });
  });
});

describe("nav hint cookie", () => {
  it("round-trips", () => {
    expect(decodeNav(encodeNav("lyra_voss", false))).toEqual({ username: "lyra_voss", isGod: false });
    expect(decodeNav(encodeNav("creator", true))).toEqual({ username: "creator", isGod: true });
  });

  it("rejects anything else", () => {
    for (const bad of ["", null, undefined, "x.1", "<script>.1", "creator.2", "creator"]) expect(decodeNav(bad)).toBeNull();
  });
});
