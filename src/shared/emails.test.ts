import { describe, expect, it } from "vitest";
import { bornEmail, trialOverEmail } from "./emails";

describe("emails", () => {
  it("tells a player they are born, and where", () => {
    const e = bornEmail({ name: "Mira Voss", mother: "Lyra Voss", father: "Orin Kell", place: "Elysium" }, "https://eon.example");
    expect(e.subject).toBe("You are born: Mira Voss");
    expect(e.text).toContain("Mira Voss was born today in Elysium, to Lyra Voss and Orin Kell.");
    expect(e.text).toContain("https://eon.example/me");
  });

  it("says so when the soul was given a young child rather than a newborn", () => {
    const e = bornEmail({ name: "Kai Voss", mother: "Lyra Voss", father: "Orin Kell", place: "Elysium", ageTicks: 1440 + 360 }, "https://eon.example");
    expect(e.subject).toBe("You have a life: Kai Voss");
    expect(e.text).toContain("Kai Voss, a child 1 year old in Elysium, the child of Lyra Voss and Orin Kell.");
    expect(bornEmail({ name: "Ada", ageTicks: 30 }, "https://x").subject).toBe("You are born: Ada");
    expect(bornEmail({ name: "Ada", ageTicks: 600 }, "https://x").text).toContain("a child 5 months old");
  });

  it("escapes names in the HTML version", () => {
    expect(trialOverEmail({ name: "<b>Kai</b>" }, "https://eon.example").html).not.toContain("<b>Kai</b>");
  });

  it("never names a real person as the Creator", () => {
    const all = JSON.stringify([bornEmail({}, "https://x"), trialOverEmail({}, "https://x")]);
    expect(all).not.toMatch(/owner|real person|console/i);
  });
});
