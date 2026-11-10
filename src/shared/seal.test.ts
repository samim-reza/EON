import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { seal, unseal } from "./seal";

const kek = randomBytes(32);
const user = "22222222-2222-2222-2222-222222222222";

describe("seal", () => {
  it("round-trips a key", () => {
    const sealed = seal(kek, user, "gsk_example_key_1234567890");
    expect(sealed.ciphertext).not.toContain("gsk_");
    expect(unseal(kek, user, sealed)).toBe("gsk_example_key_1234567890");
  });

  it("uses a fresh nonce every time", () => {
    expect(seal(kek, user, "same").iv).not.toBe(seal(kek, user, "same").iv);
  });

  it("refuses another account, another master key, or any tampering", () => {
    const sealed = seal(kek, user, "sk-ant-secret");
    expect(() => unseal(kek, "33333333-3333-3333-3333-333333333333", sealed)).toThrow();
    expect(() => unseal(randomBytes(32), user, sealed)).toThrow();
    const flipped = Buffer.from(sealed.ciphertext, "base64");
    flipped[0] ^= 1;
    expect(() => unseal(kek, user, { ...sealed, ciphertext: flipped.toString("base64") })).toThrow();
    expect(() => unseal(kek, user, { ...sealed, version: 2 })).toThrow();
  });

  it("insists on a 32-byte master key", () => {
    expect(() => seal(randomBytes(16), user, "x")).toThrow();
  });
});
