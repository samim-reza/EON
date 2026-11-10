import { describe, expect, it } from "vitest";
import { bornEmail, trialOverEmail } from "./emails";

describe("emails", () => {
  it("tells a player they are born, and where", () => {
    const e = bornEmail({ name: "Mira Voss", mother: "Lyra Voss", father: "Orin Kell", place: "Elysium" }, "https://eon.example");
    expect(e.subject).toBe("You are born: Mira Voss");
    expect(e.text).toContain("Mira Voss was born today in Elysium, to Lyra Voss and Orin Kell.");
    expect(e.text).toContain("https://eon.example/me");
  });

  it("escapes names in the HTML version", () => {
    expect(trialOverEmail({ name: "<b>Kai</b>" }, "https://eon.example").html).not.toContain("<b>Kai</b>");
  });

  it("never names a real person as the Creator", () => {
    const all = JSON.stringify([bornEmail({}, "https://x"), trialOverEmail({}, "https://x")]);
    expect(all).not.toMatch(/owner|real person|console/i);
  });
});
