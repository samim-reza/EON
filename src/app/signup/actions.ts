"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { clientKey, powKey } from "@/lib/client-key";
import { env } from "@/lib/env";
import { checkSolution } from "@/lib/pow-check";
import { rememberNav } from "@/lib/nav-session";
import { siteUrl } from "@/lib/site";
import { adminClient } from "@/lib/supabase/admin";
import { createUserClient } from "@/lib/supabase/server";

export type SignupState = { error: string | null; sent: boolean };

const schema = z.object({
  username: z.string().trim().toLowerCase().regex(/^[a-z0-9_]{3,20}$/, "Usernames are 3–20 letters, digits or underscores."),
  email: z.email("Enter a valid email address.").max(254),
  password: z
    .string()
    .min(12, "Passwords need at least 12 characters.")
    .max(72, "Passwords can be at most 72 characters.")
    .regex(/[a-zA-Z]/, "Passwords need at least one letter.")
    .regex(/\d/, "Passwords need at least one digit."),
  age: z.literal("on", "You must be at least 13 to join."),
});

const fail = (error: string): SignupState => ({ error, sent: false });

const GATE_ERRORS: Record<string, string> = {
  taken: "That username is taken. Try another.",
  reserved: "That username is reserved. Try another.",
  invalid: "Usernames are 3–20 letters, digits or underscores.",
  refused: "We couldn't create that account. If you already have one, sign in.",
};

const AUTH_ERRORS: Record<string, string> = {
  weak_password: "That password is too weak. Choose a longer one.",
  over_email_send_rate_limit: "We can't send more emails right now. Please try again later.",
  over_request_rate_limit: "Too many sign-ups right now. Please try again in a few minutes.",
  email_address_not_authorized: "Sign-ups are temporarily limited. Please try again later.",
};

const EMAIL_FAILED = "We couldn't create that account. If you already have one, sign in.";

/**
 * Sends a confirmation link. Needs a custom SMTP provider: Supabase's built-in mail only reaches
 * members of the project's own team.
 */
async function signUpWithEmail(email: string, password: string, username: string): Promise<SignupState> {
  const supabase = await createUserClient();
  const { error } = await supabase.auth.signUp({
    email,
    password,
    options: { data: { username }, emailRedirectTo: `${siteUrl}/auth/confirm` }, // never built from request headers
  });
  // Same message for an existing address: never reveal who has an account.
  if (error) return fail(AUTH_ERRORS[error.code ?? ""] ?? EMAIL_FAILED);
  return { error: null, sent: true };
}

/**
 * Creates a confirmed account straight away, without sending mail. Only this rate-limited form can
 * do so: Supabase's own "Confirm email" stays on, so direct calls to the Auth API can't.
 */
async function signUpInstantly(email: string, password: string, username: string): Promise<SignupState> {
  const { error } = await adminClient().auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { username } });
  if (error) return fail(EMAIL_FAILED);
  const supabase = await createUserClient();
  const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
  return signInError ? fail("Your account is ready. Please sign in.") : { error: null, sent: false };
}

export async function signUp(_prev: SignupState, form: FormData): Promise<SignupState> {
  if (form.get("website")) return { error: null, sent: true }; // honeypot: tell the bot nothing
  const parsed = schema.safeParse({
    username: form.get("username"),
    email: form.get("email"),
    password: form.get("password"),
    age: form.get("age"),
  });
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "Check the form and try again.");
  const { username, email, password } = parsed.data;

  const client = await clientKey();
  const fields = Object.fromEntries(form);
  const work = checkSolution(powKey(), client, fields);
  if (work === "expired") return fail("This page has been open a while. Reload it and try again.");
  if (work !== "ok") return fail("Please wait a moment for the page to finish loading, then try again.");
  // The salt goes along so the database can make sure each solved challenge is used only once.
  const { data: gate, error: gateError } = await adminClient().rpc("signup_gate", { p_client: client, p_username: username, p_email: email, p_salt: String(fields.pow_salt ?? "") });
  if (gateError) return fail(gateError.code === "P0429" ? "Too many attempts from your network. Try again in an hour." : "Sign-up is unavailable right now.");
  if (gate === "replayed") return fail("This page has been open a while. Reload it and try again.");
  if (gate !== "ok") return fail(GATE_ERRORS[gate] ?? "Check the form and try again.");

  const supabase = await createUserClient();
  const created = env().SIGNUP_EMAIL_CONFIRMATION === "on" ? await signUpWithEmail(email, password, username) : await signUpInstantly(email, password, username);
  if (created.error || created.sent) return created;

  const { data: me } = await supabase.rpc("whoami");
  await rememberNav(me?.username ?? username, false);
  redirect("/me");
}
