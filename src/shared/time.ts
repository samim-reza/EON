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

export function ageYears(birthTick: number, tick: number): number {
  return (tick - birthTick) / TICKS_PER_YEAR;
}

export function formatAge(years: number): string {
  if (years < 1) return `${Math.max(0, Math.floor(years * 12))} months`;
  return `${Math.floor(years)} years`;
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
