import "server-only";
import { openKey } from "@/lib/keys";
import { askWorld } from "@/lib/minds";
import { ask, type Problem } from "@/lib/providers";
import { isProviderId } from "@/shared/providers";
import { parseSoulReply, SOUL_MAX_TOKENS, SOUL_SYSTEM, soulPrompt, type SoulJobKind } from "@/shared/soul-mind";

type OwnMind = { source: "own"; user: string; provider: string; model: string; ciphertext: string; iv: string; tag: string; version: number };
export type SoulJob = {
  id: number;
  kind: SoulJobKind;
  soul: true;
  facts: Record<string, unknown>;
  mind: { source: "world" } | OwnMind;
};

export type Thought = { choice: string | null; thought: string | null; prayer: string | null; tokensIn: number; tokensOut: number; problem: Problem | null };

const none = (problem: Problem | null): Thought => ({ choice: null, thought: null, prayer: null, tokensIn: 0, tokensOut: 0, problem });

/**
 * One thought from a person's own mind: EON's during their free days, the player's own AI after.
 * The key is opened only here, only for its owner's person, and never leaves this function.
 */
export async function think(job: SoulJob): Promise<Thought> {
  const user = soulPrompt(job.kind, job.facts);
  const choice = job.facts.choice as { options?: { id: string }[] } | undefined;
  const offered = (choice?.options ?? []).map((o) => o.id);
  let answer: { text: string | null; tokensIn: number; tokensOut: number; problem?: Problem };
  if (job.mind.source === "world") {
    const line = await askWorld(SOUL_SYSTEM, user, SOUL_MAX_TOKENS);
    answer = { text: line.text, tokensIn: line.tokensIn, tokensOut: line.tokensOut };
  } else {
    const mind = job.mind;
    if (!isProviderId(mind.provider)) return none("error");
    let key: string;
    try {
      key = openKey(mind.user, { ciphertext: mind.ciphertext, iv: mind.iv, tag: mind.tag, version: mind.version });
    } catch {
      return none(null); // our own configuration, not the player's key: leave its status alone
    }
    answer = await ask(mind.provider, mind.model, key, SOUL_SYSTEM, user, SOUL_MAX_TOKENS);
  }
  const parsed = answer.text ? parseSoulReply(answer.text, offered) : { choice: null, thought: null, prayer: null };
  return { ...parsed, tokensIn: answer.tokensIn, tokensOut: answer.tokensOut, problem: answer.problem ?? null };
}
