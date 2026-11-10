import { describe, expect, it } from "vitest";
import { lastFour, looksLikeKey, pickModel, PROVIDER_IDS, PROVIDERS } from "./providers";

describe("providers", () => {
  it("only talks to fixed https addresses", () => {
    for (const id of PROVIDER_IDS) {
      const url = PROVIDERS[id].baseURL;
      if (url) expect(url).toMatch(/^https:\/\/api\.[a-z.]+(\/|$)/);
    }
  });

  it("recognises each provider's key shape and rejects junk", () => {
    expect(looksLikeKey("groq", "gsk_" + "a".repeat(40))).toBe(true);
    expect(looksLikeKey("gemini", "AIza" + "b".repeat(35))).toBe(true);
    expect(looksLikeKey("gemini", "AQ." + "c".repeat(40))).toBe(true);
    expect(looksLikeKey("anthropic", "sk-ant-api03-" + "d".repeat(40))).toBe(true);
    expect(looksLikeKey("xai", "xai-" + "e".repeat(40))).toBe(true);
    expect(looksLikeKey("groq", "sk-" + "a".repeat(40))).toBe(false);
    expect(looksLikeKey("openai", "sk-abc def")).toBe(false);
    expect(looksLikeKey("openai", "sk-" + "a".repeat(400))).toBe(false);
  });

  it("picks the preferred cheap model, then falls back by pattern", () => {
    expect(pickModel("gemini", ["models/gemini-3.6-pro", "models/gemini-3.1-flash-lite", "models/gemini-3.5-flash-lite"])).toBe("gemini-3.5-flash-lite");
    expect(pickModel("gemini", ["models/gemini-3.9-flash-lite", "models/gemini-3.9-flash-lite-preview"])).toBe("gemini-3.9-flash-lite");
    expect(pickModel("groq", ["qwen/qwen3.8-27b", "openai/gpt-oss-120b"])).toBe("openai/gpt-oss-120b");
    expect(pickModel("openai", ["gpt-6-astra"])).toBeNull();
  });

  it("shows only the last four characters", () => {
    expect(lastFour(" gsk_abcdefgh1234 ")).toBe("1234");
  });
});
