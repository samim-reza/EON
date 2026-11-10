/**
 * The AI providers a player can bring a key for. Base URLs are fixed here, never taken from the
 * player, so a key can only ever be sent to its own provider. Model names change often: each
 * provider lists its preferred cheap models first, then a pattern to fall back on if those are gone.
 * Checked against each provider's documentation on 2026-11-10.
 */
export type ProviderId = "anthropic" | "gemini" | "openai" | "groq" | "deepseek" | "xai";

export type Provider = {
  id: ProviderId;
  label: string;
  free: boolean; // offers free API use without a card
  keyUrl: string;
  keyHint: string;
  keyPattern: RegExp;
  baseURL?: string; // OpenAI-compatible providers
  prefer: string[];
  fallback: RegExp;
};

export const PROVIDERS: Record<ProviderId, Provider> = {
  gemini: {
    id: "gemini", label: "Gemini (Google)", free: true,
    keyUrl: "https://aistudio.google.com/apikey", keyHint: "starts with AIza or AQ.",
    keyPattern: /^(AIza[0-9A-Za-z_-]{30,}|AQ\.[0-9A-Za-z_.-]{20,})$/,
    prefer: ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite"], fallback: /^gemini-[\d.]+-flash-lite$/,
  },
  groq: {
    id: "groq", label: "Groq", free: true,
    keyUrl: "https://console.groq.com/keys", keyHint: "starts with gsk_",
    keyPattern: /^gsk_[0-9A-Za-z]{20,}$/, baseURL: "https://api.groq.com/openai/v1",
    prefer: ["openai/gpt-oss-20b", "openai/gpt-oss-120b"], fallback: /^openai\/gpt-oss-(20b|120b)$/,
  },
  anthropic: {
    id: "anthropic", label: "Claude (Anthropic)", free: false,
    keyUrl: "https://platform.claude.com/settings/keys", keyHint: "starts with sk-ant-",
    keyPattern: /^sk-ant-[0-9A-Za-z_-]{20,}$/,
    prefer: ["claude-haiku-5-5"], fallback: /^claude-haiku-/,
  },
  openai: {
    id: "openai", label: "OpenAI", free: false,
    keyUrl: "https://platform.openai.com/api-keys", keyHint: "starts with sk-",
    keyPattern: /^sk-[0-9A-Za-z_-]{20,}$/, baseURL: "https://api.openai.com/v1",
    prefer: ["gpt-6-luna", "gpt-5.6-luna"], fallback: /^gpt-[\d.]+-luna$/,
  },
  deepseek: {
    id: "deepseek", label: "DeepSeek", free: false,
    keyUrl: "https://platform.deepseek.com/api_keys", keyHint: "starts with sk-",
    keyPattern: /^sk-[0-9A-Za-z]{20,}$/, baseURL: "https://api.deepseek.com",
    prefer: ["deepseek-flash", "deepseek-v4-flash"], fallback: /flash/,
  },
  xai: {
    id: "xai", label: "Grok (xAI)", free: false,
    keyUrl: "https://console.x.ai", keyHint: "starts with xai-",
    keyPattern: /^xai-[0-9A-Za-z]{20,}$/, baseURL: "https://api.x.ai/v1",
    prefer: ["grok-4.3"], fallback: /^grok-4\.3$|non-reasoning$/,
  },
};

export const PROVIDER_IDS = Object.keys(PROVIDERS) as ProviderId[];

export const isProviderId = (v: unknown): v is ProviderId => typeof v === "string" && v in PROVIDERS;

/** A quick check before anything is sent anywhere. Lenient on purpose: providers change formats. */
export function looksLikeKey(provider: ProviderId, raw: string): boolean {
  const key = raw.trim();
  return key.length <= 300 && PROVIDERS[provider].keyPattern.test(key);
}

/** The cheapest suitable model this key can use, from the provider's own list. */
export function pickModel(provider: ProviderId, available: string[]): string | null {
  const ids = available.map((m) => m.replace(/^models\//, ""));
  const p = PROVIDERS[provider];
  return p.prefer.find((m) => ids.includes(m)) ?? ids.filter((m) => p.fallback.test(m)).sort()[0] ?? null;
}

/** Only the last four characters are ever shown back. */
export const lastFour = (key: string) => key.trim().slice(-4);
