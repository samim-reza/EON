/**
 * The reckoning: how a life is spoken of once it has ended and its deeds have been weighed.
 * The database does the weighing (`sim.weigh`); this only puts the result into words. Nothing is
 * said about what comes after death: EON shows how a person left the world, and stops there.
 */
export type Reckoning = "light" | "even" | "heavy" | "child";

const LINES: Record<Reckoning, string> = {
  light: "Left the world with a light heart: far more good done than ill.",
  even: "Left the world with good and ill in the balance.",
  heavy: "Left the world with a heavy record, and little done to mend it.",
  child: "Died before the age of reckoning. Nothing is held against a child.",
};

export function reckoningLine(r: string | null | undefined): string | null {
  return r && r in LINES ? LINES[r as Reckoning] : null;
}

/** A living person's own record, in words, for their player and nobody else. */
export function recordLine(record: { good: number; ill: number; mended: number } | null | undefined): string | null {
  if (!record) return null;
  const { good, ill, mended } = record;
  const deeds = (n: number, kind: string) => `${n} ${kind} ${n === 1 ? "deed" : "deeds"}`;
  const parts = [deeds(good, "good")];
  if (ill > 0) parts.push(`${deeds(ill, "ill")} to answer for`);
  else parts.push("nothing to answer for");
  if (mended > 0) parts.push(`${mended} laid down by asking forgiveness`);
  return parts.join(" · ");
}
