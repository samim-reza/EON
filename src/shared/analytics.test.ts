import { describe, expect, it } from "vitest";
import { redactPageUrl } from "./analytics";

const site = "https://eon-rose.vercel.app";

describe("redactPageUrl", () => {
  it("keeps plain pages as they are", () => {
    expect(redactPageUrl(`${site}/agents/42`)).toBe(`${site}/agents/42`);
    expect(redactPageUrl(`${site}/`)).toBe(`${site}/`);
  });

  it("drops tokens, codes and fragments but keeps campaign tags", () => {
    expect(redactPageUrl(`${site}/login?next=/me&code=abc#x`)).toBe(`${site}/login`);
    expect(redactPageUrl(`${site}/?utm_source=devto&token_hash=secret&ref=itch`)).toBe(
      `${site}/?utm_source=devto&ref=itch`,
    );
    expect(redactPageUrl(`${site}/?utm_source=${"x".repeat(65)}`)).toBe(`${site}/`);
  });

  it("does not count auth callbacks or the Creator's pages", () => {
    expect(redactPageUrl(`${site}/auth/confirm?token_hash=secret&type=signup`)).toBeNull();
    expect(redactPageUrl(`${site}/god`)).toBeNull();
    expect(redactPageUrl(`${site}/god/anything`)).toBeNull();
    expect(redactPageUrl(`${site}/godly`)).toBe(`${site}/godly`);
  });

  it("ignores garbage", () => {
    expect(redactPageUrl("not a url")).toBeNull();
  });
});
