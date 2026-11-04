/** EON calendar. 1 tick = 1 real minute; 1440 ticks = 1 EON year = 1 real day. */
export const TICKS_PER_YEAR = 1440;
export const TICKS_PER_MONTH = 120;
export const TICKS_PER_DAY = 4;
export const REAL_MS_PER_TICK = 60_000;

export const MONTHS = ["Thaw", "Bloom", "Spark", "Sunpeak", "Highsun", "Ember", "Harvest", "Rustfall", "Dimming", "Frost", "Deepcold", "Longnight"] as const;
export const PHASES = ["Morning", "Afternoon", "Evening", "Night"] as const;

export function season(month: number): "Spring" | "Summer" | "Autumn" | "Winter" {
  if (month <= 2) return "Spring";
  if (month <= 5) return "Summer";
  if (month <= 8) return "Autumn";
  return "Winter";
}

export function eonDate(tick: number) {
  const year = Math.floor(tick / TICKS_PER_YEAR);
  const month = Math.floor((tick % TICKS_PER_YEAR) / TICKS_PER_MONTH);
  const day = Math.floor((tick % TICKS_PER_MONTH) / TICKS_PER_DAY) + 1;
  const phase = ((tick % TICKS_PER_DAY) + TICKS_PER_DAY) % TICKS_PER_DAY;
  return { year, month, monthName: MONTHS[((month % 12) + 12) % 12], day, phase, phaseName: PHASES[phase], season: season(month) };
}

export function formatEonDate(tick: number): string {
  const d = eonDate(tick);
  return `Year ${d.year}, ${d.monthName} ${d.day}`;
}

/** Real minutes until the year's harvest, on the first day of the month of Harvest. */
export function ticksToHarvest(tf: number) {
  const left = 720 - (((tf % TICKS_PER_YEAR) + TICKS_PER_YEAR) % TICKS_PER_YEAR);
  return left > 0 ? left : left + TICKS_PER_YEAR;
}

export function ageYears(birthTick: number, tick: number): number {
  return (tick - birthTick) / TICKS_PER_YEAR;
}

const plural = (n: number, unit: string) => `${n} ${unit}${n === 1 ? "" : "s"}`;

/** "22 years, 3 months": months change every 2 real hours, so ageing is visible through the day. */
export function formatAge(years: number): string {
  const totalMonths = Math.floor(Math.max(0, years) * 12 + 1e-9);
  if (totalMonths < 12) return plural(totalMonths, "month");
  const y = Math.floor(totalMonths / 12);
  const m = totalMonths % 12;
  return m ? `${plural(y, "year")}, ${plural(m, "month")}` : plural(y, "year");
}

/** Exact age: the days change every 4 real minutes, so you can watch someone get older. */
export function formatAgeExact(ticks: number): string {
  const t = Math.max(0, Math.floor(ticks));
  const y = Math.floor(t / TICKS_PER_YEAR);
  const m = Math.floor((t % TICKS_PER_YEAR) / TICKS_PER_MONTH);
  const d = Math.floor((t % TICKS_PER_MONTH) / TICKS_PER_DAY);
  const parts = [y ? plural(y, "year") : "", y || m ? plural(m, "month") : "", plural(d, "day")];
  return parts.filter(Boolean).join(", ");
}

/**
 * What a wall clock in EON reads at a fractional tick. One tick is six EON hours:
 * Morning 06:00, Afternoon 12:00, Evening 18:00, Night 00:00. The date rolls over at
 * midnight, so the Night tick already belongs to the next calendar day.
 */
export function eonClock(tf: number) {
  const tick = Math.floor(tf);
  const phase = ((tick % TICKS_PER_DAY) + TICKS_PER_DAY) % TICKS_PER_DAY;
  const date = eonDate(phase === 3 ? tick + 1 : tick);
  const minutes = (360 + (phase + (tf - tick)) * 360) % 1440;
  const pad = (n: number) => String(n).padStart(2, "0");
  return { ...date, phase, phaseName: PHASES[phase], time: `${pad(Math.floor(minutes / 60))}:${pad(Math.floor(minutes % 60))}` };
}

/** The last tick we trust and when we learned it (a monotonic clock reading, in ms). */
export type TickAnchor = { tick: number; at: number };

/**
 * Dead reckoning: between server polls the clock runs on its own. A poll can only ever move it
 * forward, because a CDN-cached reply is usually a little behind our own estimate. Time jumps
 * back only if we have drifted more than 1.5 ticks ahead of the server (a pause or an outage).
 */
export function advanceAnchor(prev: TickAnchor | null, tick: number, at: number, paused = false): TickAnchor {
  if (!prev || paused) return { tick, at };
  const predicted = prev.tick + (at - prev.at) / REAL_MS_PER_TICK;
  return tick <= predicted && predicted - tick < 1.5 ? prev : { tick, at };
}

export function tickAt(a: TickAnchor, at: number, paused = false): number {
  return paused ? a.tick : a.tick + Math.max(0, at - a.at) / REAL_MS_PER_TICK;
}

/** "in 3 h 20 m" style real-time duration for a number of ticks. */
export function realDuration(ticks: number): string {
  const mins = Math.max(0, Math.round(ticks));
  if (mins < 60) return `${mins} min`;
  const h = Math.floor(mins / 60);
  if (h < 48) return `${h} h ${mins % 60} m`;
  return `${Math.floor(h / 24)} days`;
}

export function lifeStage(years: number): string {
  if (years < 3) return "baby";
  if (years < 13) return "child";
  if (years < 18) return "teen";
  if (years < 65) return "adult";
  return "elder";
}
