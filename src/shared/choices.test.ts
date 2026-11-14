import { describe, expect, it } from "vitest";
import { outcome, situation, timeLeft, type Choice } from "./choices";

const base: Choice = {
  id: 1, kind: "year", tick: 100, dueTick: 460, status: "settled", facts: { age: 6 },
  options: [{ id: "help", label: "Help your family at home and in the fields" }, { id: "play", label: "Play with the other children" }],
};

describe("choices as the player reads them", () => {
  it("says what you did, and who pushed back", () => {
    expect(outcome({ ...base, choice: "play", outcome: { did: "help", result: "help", sway: { want: "help", role: "mother", won: true } } }))
      .toBe("You chose to help your family at home and in the fields. Your mother pushed you to help your family at home and in the fields, and you gave in.");
    expect(outcome({ ...base, choice: "play", outcome: { did: "play", result: "play", sway: { want: "help", role: "mother", won: false } } }))
      .toBe("You chose to play with the other children. Your mother pushed you to help your family at home and in the fields, but you held firm.");
  });

  it("tells love from both sides", () => {
    const love: Choice = { ...base, kind: "love", otherName: "Tavi Kell", options: [{ id: "accept", label: "Let Tavi court you" }, { id: "decline", label: "Turn Tavi away" }] };
    expect(situation(love)).toBe("Tavi wants to court you.");
    expect(outcome({ ...love, outcome: { did: "accept", result: "together" } })).toBe("You and Tavi are together now.");
    expect(outcome({ ...love, outcome: { did: "accept", result: "apart" } })).toBe("Tavi turned you away.");
    expect(outcome({ ...love, outcome: { did: "decline", result: "apart" } })).toBe("You turned Tavi away.");
  });

  it("shows a sign from God as a dream, in its own words", () => {
    expect(situation({ ...base, kind: "sign", facts: { text: "Go to the river at dawn." } })).toBe('A dream that will not leave you: "Go to the river at dawn."');
  });

  it("counts down in hours and minutes", () => {
    expect(timeLeft(330)).toBe("5 h 30 min");
    expect(timeLeft(60)).toBe("1 h");
    expect(timeLeft(45)).toBe("45 min");
    expect(timeLeft(-3)).toBe("now");
  });
});

describe("a whisper as the player reads it", () => {
  const whisper: Choice = {
    id: 9, kind: "whisper", tick: 100, dueTick: 460, status: "open", otherName: "Orin Kell",
    facts: { what: "take", line: "Take it. Orin has more than enough, and nobody will see." },
    options: [{ id: "yield", label: "Take it from Orin" }, { id: "resist", label: "Turn away" }, { id: "refuge", label: "Seek refuge with the Creator" }],
  };
  it("comes in a voice almost your own", () => {
    expect(situation(whisper)).toBe('A whisper, in a voice almost your own: "Take it. Orin has more than enough, and nobody will see."');
  });
  it("tells you what came of it, and that wrongs go on your record", () => {
    const after = (result: string, what = "take") => outcome({ ...whisper, status: "settled", facts: { ...whisper.facts, what }, choice: "yield", outcome: { did: "yield", result } });
    expect(after("took")).toBe("You took from Orin, and nobody saw. It is on your record.");
    expect(after("caught")).toBe("You took from Orin, and you were caught.");
    expect(after("caught", "cheat")).toBe("You gave short measure, and you were found out.");
    expect(after("resisted")).toBe("You turned away.");
    expect(after("refuge")).toContain("sought refuge with the Creator");
    expect(after("gone")).toBe("The moment passed.");
  });
  it("says who held you back", () => {
    expect(outcome({ ...whisper, status: "settled", choice: "yield", outcome: { did: "resist", result: "resisted", sway: { want: "resist", role: "mother", won: true } } }))
      .toBe("You turned away. Your mother pushed you to turn away, and you gave in.");
  });
});
