import { describe, expect, it } from "vitest";
import { checkSolution, makeChallenge } from "@/lib/pow-check";
import { leadingZeroBits, solvePow } from "./pow";

const KEY = "test-key";
const CLIENT = "a".repeat(64);

describe("proof of work at sign-up", () => {
  it("counts leading zero bits", () => {
    expect(leadingZeroBits(new Uint8Array([0, 0, 0x0f]))).toBe(20);
    expect(leadingZeroBits(new Uint8Array([0x80]))).toBe(0);
    expect(leadingZeroBits(new Uint8Array([0, 1]))).toBe(15);
  });

  it("is solvable in the browser, and the server accepts the answer", async () => {
    const challenge = makeChallenge(KEY, CLIENT);
    const started = performance.now();
    const nonce = await solvePow(challenge);
    expect(performance.now() - started).toBeLessThan(15_000);
    const form = { pow_salt: challenge.salt, pow_expires: challenge.expires, pow_bits: challenge.bits, pow_sig: challenge.sig, pow_nonce: nonce };
    expect(checkSolution(KEY, CLIENT, form)).toBe("ok");
  });

  it("refuses a wrong answer, a forged challenge, another network or an old page", async () => {
    const challenge = makeChallenge(KEY, CLIENT, 1_000);
    const nonce = await solvePow(challenge);
    const form = { pow_salt: challenge.salt, pow_expires: challenge.expires, pow_bits: challenge.bits, pow_sig: challenge.sig, pow_nonce: nonce };
    expect(checkSolution(KEY, CLIENT, form, 2_000)).toBe("ok");
    expect(checkSolution(KEY, CLIENT, { ...form, pow_nonce: nonce + 1 }, 2_000)).toBe("invalid");
    expect(checkSolution(KEY, CLIENT, { ...form, pow_bits: 1 }, 2_000)).toBe("invalid");
    expect(checkSolution(KEY, "b".repeat(64), form, 2_000)).toBe("invalid");
    expect(checkSolution("other-key", CLIENT, form, 2_000)).toBe("invalid");
    expect(checkSolution(KEY, CLIENT, form, challenge.expires + 1)).toBe("expired");
    expect(checkSolution(KEY, CLIENT, {}, 2_000)).toBe("invalid");
  });
});
