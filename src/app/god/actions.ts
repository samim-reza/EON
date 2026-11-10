"use server";

import { randomInt } from "node:crypto";
import { revalidatePath } from "next/cache";
import { z } from "zod";
import { createUserClient } from "@/lib/supabase/server";
import { sitesWithWater } from "@/shared/rivers";

export type ActionResult = { ok: boolean; error: string | null; data?: unknown };

const fail = (error: string): ActionResult => ({ ok: false, error });

/** Every God action goes through the user's own session; the database enforces God + fresh MFA. */
async function godRpc(fn: string, args: Record<string, unknown>): Promise<ActionResult> {
  const supabase = await createUserClient();
  const { data, error } = await supabase.rpc(fn, args);
  if (error) return fail(error.message);
  revalidatePath("/god");
  return { ok: true, error: null, data };
}

// ---------------------------------------------------------------- MFA

export async function mfaEnroll(): Promise<ActionResult> {
  const supabase = await createUserClient();
  const { data: list } = await supabase.auth.mfa.listFactors();
  for (const f of list?.all ?? []) {
    if (f.status === "unverified") await supabase.auth.mfa.unenroll({ factorId: f.id });
  }
  const { data, error } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: `EON Creator ${Date.now()}` });
  if (error || !data) return fail(error?.message ?? "Could not start enrollment");
  return { ok: true, error: null, data: { factorId: data.id, qr: data.totp.qr_code, secret: data.totp.secret } };
}

const codeSchema = z.object({ factorId: z.string().uuid(), code: z.string().regex(/^\d{6}$/) });

export async function mfaVerify(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = codeSchema.safeParse({ factorId: form.get("factorId"), code: form.get("code") });
  if (!parsed.success) return fail("Enter the 6-digit code from your authenticator app.");
  const supabase = await createUserClient();
  const { error } = await supabase.auth.mfa.challengeAndVerify(parsed.data);
  if (error) return fail("That code did not work. Wait for a fresh code and try again.");
  revalidatePath("/god");
  return { ok: true, error: null };
}

// ---------------------------------------------------------------- Genesis

const name = z.string().trim().regex(/^[A-Za-z][A-Za-z' -]{1,15}$/, "Names: 2–16 letters");
const genesisSchema = z.object({
  village: z.string().trim().regex(/^[A-Za-z][A-Za-z' -]{1,23}$/, "Village: 2–24 letters"),
  eve: name,
  eveSurname: name,
  adam: name,
  adamSurname: name,
});

export async function genesis(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = genesisSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Invalid names");
  const seed = randomInt(1, 2_147_483_647);
  const sites = sitesWithWater(seed);
  if (sites.length < 40) return fail("This seed produced too little land — try again.");
  const p = parsed.data;
  return godRpc("god_genesis", {
    p_seed: seed, p_sites: sites, p_village: p.village,
    p_eve_name: p.eve, p_adam_name: p.adam, p_surname_f: p.eveSurname, p_surname_m: p.adamSurname,
  });
}

// ---------------------------------------------------------------- World balance

const worldSchema = z.object({
  fertility_mult: z.coerce.number().min(0).max(5),
  mortality_mult: z.coerce.number().min(0.2).max(5),
  disease_mult: z.coerce.number().min(0).max(5),
  crime_mult: z.coerce.number().min(0).max(5),
  temp_shift: z.coerce.number().min(-20).max(20),
  rain_mult: z.coerce.number().min(0).max(4),
  llm_cap: z.coerce.number().min(0).max(5),
  female_ratio: z.coerce.number().min(0.3).max(0.7),
  capacity_k: z.coerce.number().int().min(50).max(200_000),
  autopilot: z.enum(["on", "off"]),
});

export async function setWorld(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = worldSchema.safeParse({ ...Object.fromEntries(form), autopilot: form.get("autopilot") ? "on" : "off" });
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Invalid values");
  const { autopilot, ...rest } = parsed.data;
  return godRpc("god_set_world", { p: { ...rest, autopilot: autopilot === "on" } });
}

export async function setPaused(paused: boolean): Promise<ActionResult> {
  return godRpc("god_set_world", { p: { paused } });
}

// ---------------------------------------------------------------- Powers

const idSchema = z.coerce.number().int().min(1).max(9_000_000_000_000);

export async function heal(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const id = idSchema.safeParse(form.get("agent"));
  if (!id.success) return fail("Enter an agent id.");
  return godRpc("god_heal", { p_agent: id.data });
}

const smiteSchema = z.object({ agent: idSchema, cause: z.enum(["Core Arrest", "Logic Stroke", "Accident", "Divine Will"]) });

export async function smite(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = smiteSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail("Choose an agent and a cause.");
  return godRpc("god_smite", { p_agent: parsed.data.agent, p_cause: parsed.data.cause });
}

const founderSchema = z.object({
  name, surname: name, sex: z.enum(["F", "M"]), age: z.coerce.number().int().min(16).max(60), settlement: z.coerce.number().int().min(1),
});

export async function createFounder(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = founderSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Invalid founder");
  const f = parsed.data;
  return godRpc("god_create_founder", { p_name: f.name, p_surname: f.surname, p_sex: f.sex, p_age: f.age, p_settlement: f.settlement });
}

const settlementSchema = z.object({
  site: z.coerce.number().int().min(1),
  name: z.string().trim().min(2, "A name needs at least 2 letters").max(24).regex(/^[\p{L}][\p{L} '-]*$/u, "Use letters only"),
});

export async function foundSettlement(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = settlementSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Invalid settlement");
  return godRpc("god_found_settlement", { p_site: parsed.data.site, p_name: parsed.data.name });
}

const moveSchema = z.object({ agent: z.coerce.number().int().min(1), settlement: z.coerce.number().int().min(1) });

export async function moveAgent(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = moveSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail("Choose a person and a settlement");
  return godRpc("god_move_agent", { p_agent: parsed.data.agent, p_settlement: parsed.data.settlement });
}

const prayerSchema = z.object({ prayer: z.coerce.number().int().min(1), answer: z.enum(["grant", "deny"]) });

export async function answerPrayer(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = prayerSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail("Invalid prayer");
  return godRpc("god_answer_prayer", { p_prayer: parsed.data.prayer, p_grant: parsed.data.answer === "grant" });
}

const soulSchema = z.object({ soul: z.coerce.number().int().min(1), family: z.string().regex(/^[pc]\d{1,12}$/) });

/** A family's coming baby ("p" and the pregnancy) or a young child already alive ("c" and the person). */
export async function assignSoul(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = soulSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail("Choose a soul and a family");
  const id = Number(parsed.data.family.slice(1));
  return parsed.data.family.startsWith("c")
    ? godRpc("god_give_child", { p_soul: parsed.data.soul, p_agent: id })
    : godRpc("god_assign_soul", { p_soul: parsed.data.soul, p_pregnancy: id });
}

const possessSchema = z.object({
  agent: z.coerce.number().int().min(1),
  job: z.enum(["", "farmer", "builder", "healer"]).optional(),
  say: z.string().trim().max(200, "Keep it under 200 characters").optional(),
});

export async function possess(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = possessSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Invalid command");
  const { agent, job, say } = parsed.data;
  return godRpc("god_possess", { p_agent: agent, p_job: job || null, p_say: say || null });
}

export async function release(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const agent = z.coerce.number().int().min(1).safeParse(form.get("agent"));
  if (!agent.success) return fail("Invalid agent");
  return godRpc("god_release", { p_agent: agent.data });
}

const overruleSchema = z.object({ choice: z.coerce.number().int().min(1), option: z.string().regex(/^[a-z]{2,12}$/) });

/** A player's person chose, or is about to; God's will is done instead. */
export async function overrule(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = overruleSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail("Choose one of the options");
  return godRpc("god_choose", { p_choice: parsed.data.choice, p_option: parsed.data.option });
}

const signSchema = z.object({
  agent: z.coerce.number().int().min(1),
  text: z.string().trim().min(1, "Write what they dream").max(200, "Keep it under 200 characters"),
});

export async function sendSign(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = signSchema.safeParse(Object.fromEntries(form));
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Invalid sign");
  return godRpc("god_sign", { p_agent: parsed.data.agent, p_text: parsed.data.text });
}

// ---------------------------------------------------------------- Account

const passwordSchema = z.object({
  current: z.string().min(1).max(200),
  next: z.string().min(12, "At least 12 characters").max(200).regex(/[a-zA-Z]/, "Include letters").regex(/\d/, "Include digits"),
});

export async function changePassword(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = passwordSchema.safeParse({ current: form.get("current"), next: form.get("next") });
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Invalid password");
  if (parsed.data.current === parsed.data.next) return fail("Choose a different password.");
  const supabase = await createUserClient();
  const { data: who } = await supabase.rpc("whoami");
  if (!who?.is_god) return fail("Only God may do this here.");
  const { error } = await supabase.auth.updateUser({ password: parsed.data.next, current_password: parsed.data.current });
  if (error) return fail("Could not change the password — check the current one.");
  return { ok: true, error: null };
}
