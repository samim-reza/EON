import { describe, expect, it } from "vitest";
import { passwordSchema, resetTokenSchema } from "./password";

describe("passwordSchema", () => {
  it("accepts 12+ characters with a letter and a digit", () => {
    expect(passwordSchema.safeParse("watching eon 1").success).toBe(true);
  });
  it("rejects short, letterless, digitless and overlong passwords", () => {
    expect(passwordSchema.safeParse("short1a").success).toBe(false);
    expect(passwordSchema.safeParse("123456789012").success).toBe(false);
    expect(passwordSchema.safeParse("abcdefghijkl").success).toBe(false);
    expect(passwordSchema.safeParse(`a1${"x".repeat(71)}`).success).toBe(false);
  });
});

describe("resetTokenSchema", () => {
  it("accepts a token hash", () => {
    expect(resetTokenSchema.safeParse("a".repeat(56)).success).toBe(true);
  });
  it("rejects anything that could smuggle markup or a path", () => {
    for (const bad of ["", "short", "../../etc/passwd-aaaaaaaaaa", "<script>aaaaaaaaaaaaa", "a".repeat(129)]) {
      expect(resetTokenSchema.safeParse(bad).success).toBe(false);
    }
  });
});
