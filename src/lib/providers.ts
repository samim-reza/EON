import "server-only";
import Anthropic from "@anthropic-ai/sdk";
import { GoogleGenAI, ThinkingLevel } from "@google/genai";
import OpenAI from "openai";
import type { ChatCompletionCreateParamsNonStreaming } from "openai/resources/chat/completions";
import { pickModel, PROVIDERS, type ProviderId } from "@/shared/providers";

/**
 * Calls a player's own provider with the player's own key. Nothing here ever logs or returns a
 * provider's error message, which can echo request details: only a coarse reason leaves.
 */
export type Problem = "invalid" | "limited" | "error";
export type Answer = { text: string | null; tokensIn: number; tokensOut: number; problem?: Problem };

const TIMEOUT = 20_000;

function classify(error: unknown): Problem {
  const status = typeof (error as { status?: unknown })?.status === "number" ? (error as { status: number }).status : 0;
  const message = error instanceof Error ? error.message : "";
  if (status === 401 || status === 403) return "invalid";
  if (status === 400 && /api[ _-]?key|API_KEY_INVALID|credential/i.test(message)) return "invalid";
  if (status === 402 || status === 429) return "limited";
  if (status === 400 && /credit|balance|billing|quota/i.test(message)) return "limited";
  return "error";
}

const openaiCompatible = (provider: ProviderId, key: string) =>
  new OpenAI({ apiKey: key, baseURL: PROVIDERS[provider].baseURL, maxRetries: 0, timeout: TIMEOUT });

async function listModels(provider: ProviderId, key: string): Promise<string[]> {
  const ids: string[] = [];
  if (provider === "anthropic") {
    const client = new Anthropic({ apiKey: key, maxRetries: 0, timeout: TIMEOUT });
    for await (const m of client.models.list({ limit: 100 })) ids.push(m.id);
  } else if (provider === "gemini") {
    const ai = new GoogleGenAI({ apiKey: key, httpOptions: { timeout: TIMEOUT } });
    for await (const m of await ai.models.list({ config: { pageSize: 100 } })) if (m.name) ids.push(m.name);
  } else {
    for await (const m of openaiCompatible(provider, key).models.list()) {
      if ((m as { shutdown_date?: unknown }).shutdown_date) continue; // OpenAI lists models that are about to go
      ids.push(m.id);
    }
  }
  return ids;
}

/** One short call. Reasoning is switched off or kept low where the model allows it. */
export async function ask(provider: ProviderId, model: string, key: string, system: string, user: string, maxTokens: number): Promise<Answer> {
  try {
    if (provider === "anthropic") {
      const client = new Anthropic({ apiKey: key, maxRetries: 0, timeout: TIMEOUT });
      const reply = await client.messages.create({
        model, max_tokens: maxTokens, system, thinking: { type: "disabled" }, messages: [{ role: "user", content: user }],
      });
      const text = reply.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join(" ");
      return { text: text || null, tokensIn: reply.usage.input_tokens, tokensOut: reply.usage.output_tokens };
    }
    if (provider === "gemini") {
      const ai = new GoogleGenAI({ apiKey: key, httpOptions: { timeout: TIMEOUT } });
      const reply = await ai.models.generateContent({
        model, contents: user,
        // The output limit includes any thinking, so it leaves room above the short answer.
        config: { systemInstruction: system, maxOutputTokens: maxTokens + 700, responseMimeType: "application/json",
                  thinkingConfig: { thinkingLevel: ThinkingLevel.MINIMAL } },
      });
      const usage = reply.usageMetadata;
      return { text: reply.text ?? null, tokensIn: usage?.promptTokenCount ?? 0,
               tokensOut: (usage?.candidatesTokenCount ?? 0) + (usage?.thoughtsTokenCount ?? 0) };
    }
    const body: Record<string, unknown> = {
      model, messages: [{ role: "system", content: system }, { role: "user", content: user }], response_format: { type: "json_object" },
    };
    if (provider === "groq") Object.assign(body, { max_completion_tokens: maxTokens + 1000, reasoning_effort: "low", include_reasoning: false });
    else if (provider === "deepseek") Object.assign(body, { max_tokens: maxTokens, reasoning_effort: "none" });
    else Object.assign(body, { max_completion_tokens: maxTokens + 300, reasoning_effort: "none" });
    const reply = await openaiCompatible(provider, key).chat.completions.create(body as unknown as ChatCompletionCreateParamsNonStreaming);
    return { text: reply.choices[0]?.message?.content ?? null, tokensIn: reply.usage?.prompt_tokens ?? 0, tokensOut: reply.usage?.completion_tokens ?? 0 };
  } catch (error) {
    return { text: null, tokensIn: 0, tokensOut: 0, problem: classify(error) };
  }
}

export type KeyCheck = { ok: true; model: string } | { ok: false; reason: string };

/** Lists the key's models, picks the cheapest suitable one, and makes one tiny call to prove it works. */
export async function checkKey(provider: ProviderId, key: string): Promise<KeyCheck> {
  const label = PROVIDERS[provider].label;
  const why = (p: Problem) =>
    p === "invalid" ? `${label} did not accept this key.`
      : p === "limited" ? "This key has no credit, or is over its limit right now."
        : `Could not reach ${label}. Try again in a minute.`;
  let ids: string[];
  try {
    ids = await listModels(provider, key);
  } catch (error) {
    return { ok: false, reason: why(classify(error)) };
  }
  const model = pickModel(provider, ids);
  if (!model) return { ok: false, reason: "This key cannot use any of the small models EON needs." };
  const reply = await ask(provider, model, key, "Reply with JSON only.", 'Reply with this JSON exactly: {"ok": true}', 20);
  if (reply.problem) return { ok: false, reason: why(reply.problem) };
  return { ok: true, model };
}
