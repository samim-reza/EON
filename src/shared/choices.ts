/**
 * How a choice reads to the player whose person faces it. The player is the soul, so it is "you".
 * Pure, so every sentence can be tested.
 */
export type ChoiceOption = { id: string; label: string };
export type Sway = { want: string; who?: number | null; name?: string | null; role: string; won: boolean };
export type Choice = {
  id: number;
  kind: "year" | "work" | "love" | "wed" | "child" | "quarrel" | "tempt" | "sign" | "whisper";
  tick: number;
  dueTick: number;
  options: ChoiceOption[];
  facts: Record<string, unknown>;
  otherName?: string;
  status: "open" | "asked" | "chosen" | "settled" | "void";
  choice?: string;
  by?: "player" | "mind" | "habit" | "god";
  thought?: string;
  outcome?: { did?: string; their?: string; result?: string; sway?: Sway; waiting?: boolean };
};

const first = (name?: string) => (name ?? "someone").split(" ")[0];
const lower = (s: string) => s.charAt(0).toLowerCase() + s.slice(1);
const labelOf = (c: Choice, id?: string) => c.options.find((o) => o.id === id)?.label ?? id ?? "";

export function situation(c: Choice): string {
  const o = first(c.otherName);
  switch (c.kind) {
    case "year": return "A new year of your childhood begins. How will you spend it?";
    case "work": return "You are old enough to work. What will you do?";
    case "love": return `${o} wants to court you.`;
    case "wed": return `You and ${o} have been together a year. Marry now, or wait?`;
    case "child": return `Do you and ${o} hope for a child this year?`;
    case "quarrel": return `You fell out with ${o}${typeof c.facts.about === "string" ? ` over ${c.facts.about}` : ""}. What will you do?`;
    case "tempt": return `You are poor, and ${o} has plenty.`;
    case "sign": return `A dream that will not leave you: "${typeof c.facts.text === "string" ? c.facts.text : ""}"`;
    case "whisper": return `A whisper, in a voice almost your own: "${typeof c.facts.line === "string" ? c.facts.line : "Go on."}"`;
  }
}

/** What came of a whisper, told to the person it came to. */
function whisperOutcome(c: Choice, o: string): string {
  const what = typeof c.facts.what === "string" ? c.facts.what : "";
  switch (c.outcome?.result) {
    case "refuge": return "You sought refuge with the Creator, and the whisper fell silent. It will keep away for a while.";
    case "resisted": return "You turned away.";
    case "took": return `You took from ${o}, and nobody saw. It is on your record.`;
    case "cheated": return "You gave short measure, and nobody noticed. It is on your record.";
    case "caught": return what === "cheat" ? "You gave short measure, and you were found out." : `You took from ${o}, and you were caught.`;
    case "slandered": return `You spread a lie about ${o}. It is on your record.`;
    case "found": return `You spread a lie about ${o}, and it came out who said it.`;
    case "struck": return `You struck ${o}. It is on your record.`;
    case "idled": return "You left the work to the others. It is on your record.";
    case "forsook": return "You stopped praying for a while, and felt further from everything.";
    default: return "The moment passed.";
  }
}

const WHO: Record<string, string> = { mother: "Your mother", father: "Your father", hunger: "Hunger" };

function swayLine(c: Choice): string | null {
  const s = c.outcome?.sway;
  if (!s) return null;
  const who = WHO[s.role] ?? (s.role === "partner" ? first(s.name ?? undefined) : first(s.name ?? c.otherName));
  const want = lower(labelOf(c, s.want));
  return s.won
    ? `${who} pushed you to ${want}, and you gave in.`
    : `${who} pushed you to ${want}, but you held firm.`;
}

export function outcome(c: Choice): string {
  const o = first(c.otherName);
  const did = c.outcome?.did ?? c.choice;
  const r = c.outcome?.result;
  let line: string;
  switch (c.kind) {
    case "year":
    case "work":
      line = `You chose to ${lower(labelOf(c, did))}.`;
      break;
    case "love":
      line = r === "together" ? `You and ${o} are together now.`
        : r === "gone" ? "The moment passed."
          : did === "decline" ? `You turned ${o} away.` : `${o} turned you away.`;
      break;
    case "wed":
      line = r === "married" ? `You married ${o}.` : did === "wait" ? "You chose to wait." : `${o} wanted to wait.`;
      break;
    case "child":
      line = did === "yes" ? "You hope for a child this year." : "Not this year.";
      break;
    case "quarrel":
      line = r === "fought" ? `It came to blows with ${o}.`
        : r === "reconciled" ? `You made peace with ${o}.`
          : r === "rebuffed" ? `You went to make peace, but ${o} would not hear of it.`
            : r === "gone" ? "The moment passed." : `You kept your distance from ${o}.`;
      break;
    case "tempt":
      line = r === "caught" ? `You took from ${o}, and you were caught.`
        : r === "took" ? `You took what you needed from ${o}, and nobody saw.` : "You went without.";
      break;
    case "sign":
      line = did === "heed" ? "You took it to heart." : "You put it out of your mind.";
      break;
    case "whisper":
      line = whisperOutcome(c, o);
      break;
  }
  const sway = swayLine(c);
  return sway ? `${line} ${sway}` : line;
}

export const BY: Record<NonNullable<Choice["by"]>, string> = {
  player: "you chose",
  mind: "their own mind chose",
  habit: "habit chose",
  god: "something greater chose",
};

/** Minutes until the player's turn is over (one tick is one real minute). */
export function timeLeft(minutes: number): string {
  if (minutes <= 0) return "now";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h > 0 ? `${h} h${m ? ` ${m} min` : ""}` : `${m} min`;
}
