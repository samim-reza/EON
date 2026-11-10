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
