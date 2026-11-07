import "server-only";
import Anthropic from "@anthropic-ai/sdk";
import { MAX_WORDS_TOKENS, MINDS_MODEL, cleanVoice, promptFor, SYSTEM_PROMPT, type MindJob } from "@/shared/minds";

let client: Anthropic | null = null;

export type Line = { text: string | null; tokensIn: number; tokensOut: number; problem?: string };

/**
 * Writes one line. A failure returns no text and the plain event stands: it never throws.
 * `problem` says why, in a few safe words (a status and an error type, never a message), so a
 * broken key shows up in minutes instead of days.
 */
export async function writeLine(job: MindJob): Promise<Line> {
  const workspace = process.env.ANTHROPIC_WORKSPACE_ID;
  // An organization-wide key must name the workspace it bills; a workspace key needs nothing.
  client ??= new Anthropic({ maxRetries: 1, timeout: 20_000, defaultHeaders: workspace ? { "anthropic-workspace-id": workspace } : undefined });
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
    if (reply.stop_reason !== "end_turn") return { text: null, tokensIn, tokensOut, problem: `stopped: ${reply.stop_reason}` }; // cut off, or refused
    const text = cleanVoice(reply.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join(" "));
    return text ? { text, tokensIn, tokensOut } : { text: null, tokensIn, tokensOut, problem: "filtered" };
  } catch (error) {
    // Messages can carry request details, so only the status and the error type leave this function.
    if (error instanceof Anthropic.APIError) {
      const type = (error.error as { error?: { type?: string } } | undefined)?.error?.type ?? "unknown";
      return { text: null, tokensIn: 0, tokensOut: 0, problem: `http ${error.status ?? "?"} ${type}` };
    }
    return { text: null, tokensIn: 0, tokensOut: 0, problem: error instanceof Error ? error.name : "unknown" };
  }
}
