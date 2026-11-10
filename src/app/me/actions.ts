"use server";

import { revalidatePath } from "next/cache";
import { getMe } from "@/lib/auth";
import { clientKey } from "@/lib/client-key";
import { keysReady, sealKey } from "@/lib/keys";
import { checkKey } from "@/lib/providers";
import { adminClient } from "@/lib/supabase/admin";
import { createUserClient } from "@/lib/supabase/server";
import { isProviderId, lastFour, looksLikeKey, PROVIDERS } from "@/shared/providers";

export type LifeState = { error: string | null };
export type KeyState = { error: string | null; saved?: boolean };

/** Our own exceptions are written for people; anything else stays vague. */
function say(error: { code?: string; message: string }) {
  if (error.code === "P0429") return "Slow down a little and try again soon.";
  if (error.code === "P0001" || error.code === "42501") return error.message;
  return "That did not work. Try again in a moment.";
}

export async function requestLife(): Promise<LifeState> {
  const supabase = await createUserClient();
  const { error } = await supabase.rpc("request_life");
  if (error) return { error: say(error) };
  revalidatePath("/me");
  return { error: null };
}

export async function choose(_prev: LifeState, form: FormData): Promise<LifeState> {
  const choice = Number(form.get("choice"));
  const option = String(form.get("option") ?? "");
  if (!Number.isSafeInteger(choice) || choice <= 0 || !/^[a-z]{2,12}$/.test(option)) return { error: "That is not one of the options." };
  const supabase = await createUserClient();
  const { error } = await supabase.rpc("choose", { p_choice: choice, p_option: option });
  if (error) return { error: say(error) };
  revalidatePath("/me");
  return { error: null };
}

export async function pray(_prev: LifeState, form: FormData): Promise<LifeState> {
  const need = String(form.get("need") ?? "");
  const supabase = await createUserClient();
  const { error } = await supabase.rpc("soul_pray", { p_need: need });
  if (error) return { error: say(error) };
  revalidatePath("/me");
  return { error: null };
}

/**
 * Checks a key with its own provider, then seals it before it reaches the database. The key is
 * never logged, never stored in plain text, and never sent back to the browser.
 */
export async function connectKey(_prev: KeyState, form: FormData): Promise<KeyState> {
  const me = await getMe();
  if (!me) return { error: "Sign in first." };
  if (!keysReady()) return { error: "Keys cannot be saved right now. Please try again later." };
  const provider = form.get("provider");
  if (!isProviderId(provider)) return { error: "Choose a provider." };
  const key = String(form.get("key") ?? "").trim();
  if (!looksLikeKey(provider, key)) return { error: `That does not look like a ${PROVIDERS[provider].label} key (it ${PROVIDERS[provider].keyHint}).` };

  const admin = adminClient();
  const { error: gateError } = await admin.rpc("key_gate", { p_client: await clientKey(), p_user: me.userId });
  if (gateError) return { error: gateError.code === "P0429" ? "Too many tries. Wait an hour and try again." : "This is unavailable right now." };

  const check = await checkKey(provider, key);
  if (!check.ok) return { error: check.reason };
  const sealed = sealKey(me.userId, key);
  const { error } = await admin.rpc("key_save", {
    p_user: me.userId, p_provider: provider, p_model: check.model, p_ct: sealed.ciphertext, p_iv: sealed.iv, p_tag: sealed.tag,
    p_version: sealed.version, p_last4: lastFour(key),
  });
  if (error) return { error: "The key worked, but it could not be saved. Try again." };
  revalidatePath("/me");
  return { error: null, saved: true };
}

export async function removeKey(): Promise<void> {
  const supabase = await createUserClient();
  await supabase.rpc("key_delete");
  revalidatePath("/me");
}
