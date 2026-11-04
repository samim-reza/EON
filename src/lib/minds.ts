import "server-only";
import Anthropic from "@anthropic-ai/sdk";
import { MAX_WORDS_TOKENS, MINDS_MODEL, cleanVoice, promptFor, SYSTEM_PROMPT, type MindJob } from "@/shared/minds";

let client: Anthropic | null = null;

/** Writes one line. A failure returns no text and the plain event stands: it never throws. */
export async function writeLine(job: MindJob): Promise<{ text: string | null; tokensIn: number; tokensOut: number }> {
  client ??= new Anthropic({ maxRetries: 1, timeout: 20_000 });
  try {
    const reply = await client.messages.create({
      model: MINDS_MODEL,
      max_tokens: MAX_WORDS_TOKENS,
      system: SYSTEM_PROMPT,
      thinking: { type: "disabled" }, // a sentence needs no reasoning, and thinking would be billed
      output_config: { effort: "low" },
      messages: [{ role: "user", content: promptFor(job) }],
    });
    const tokensIn = reply.usage.input_tokens;
    const tokensOut = reply.usage.output_tokens;
    if (reply.stop_reason !== "end_turn") return { text: null, tokensIn, tokensOut }; // cut off, or refused
    const text = reply.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join(" ");
    return { text: cleanVoice(text), tokensIn, tokensOut };
  } catch {
    return { text: null, tokensIn: 0, tokensOut: 0 }; // errors can carry request details, so they stop here
  }
}
