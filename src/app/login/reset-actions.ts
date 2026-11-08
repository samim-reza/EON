"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { clientKey } from "@/lib/client-key";
import { rememberNav } from "@/lib/nav-session";
import { adminClient } from "@/lib/supabase/admin";
import { createUserClient } from "@/lib/supabase/server";
import { passwordSchema, resetTokenSchema } from "@/shared/password";

export type ForgotState = { error: string | null; sent: boolean };
export type NewPasswordState = { error: string | null };

const LIMITED = "Too many attempts. Try again in 15 minutes.";
const UNAVAILABLE = "This is unavailable right now. Please try again later.";

/** Same rate limits as sign-in, so reset emails cannot be used to flood an inbox or the mail quota. */
async function gate(key: string): Promise<string | null> {
  const { error } = await adminClient().rpc("login_gate", { p_client: await clientKey(), p_email: key });
  if (!error) return null;
  return error.code === "P0429" ? LIMITED : UNAVAILABLE;
}

export async function requestReset(_prev: ForgotState, form: FormData): Promise<ForgotState> {
  const email = z.email().max(254).safeParse(form.get("email"));
  if (!email.success) return { error: "Enter a valid email address.", sent: false };
  const blocked = await gate(email.data);
  if (blocked) return { error: blocked, sent: false };
  // The link itself comes from the email template ({{ .SiteURL }}/auth/confirm?type=recovery).
  const { error } = await adminClient().auth.resetPasswordForEmail(email.data);
  if (error?.code === "over_email_send_rate_limit") return { error: "We can't send more emails right now. Please try again later.", sent: false };
  // Otherwise always the same answer, so nobody can learn which addresses have accounts.
  return { error: null, sent: true };
}

/**
 * The emailed link only opens the form; the one-time token is spent here, on submit. Mail
 * scanners that open links in advance therefore cannot use it up, and no half-finished
 * signed-in session is left behind when someone abandons the page.
 */
export async function setNewPassword(_prev: NewPasswordState, form: FormData): Promise<NewPasswordState> {
  const token = resetTokenSchema.safeParse(form.get("token"));
  if (!token.success) return { error: "This link is incomplete. Ask for a new one." };
  const password = passwordSchema.safeParse(form.get("password"));
  if (!password.success) return { error: password.error.issues[0]?.message ?? "Choose a stronger password." };
  if (form.get("confirm") !== password.data) return { error: "The two passwords don't match." };

  const blocked = await gate(`reset:${token.data}`);
  if (blocked) return { error: blocked };

  const supabase = await createUserClient();
  const { error: verifyError } = await supabase.auth.verifyOtp({ type: "recovery", token_hash: token.data });
  if (verifyError) return { error: "This link has expired or was already used. Ask for a new one." };

  const { error } = await supabase.auth.updateUser({ password: password.data });
  if (error) {
    await supabase.auth.signOut();
    return {
      error:
        error.code === "same_password"
          ? "That is already your password. Sign in with it, or ask for a new link to choose another."
          : "We couldn't change the password. Ask for a new link and try again.",
    };
  }

  const { data } = await supabase.rpc("whoami");
  if (data?.username) await rememberNav(data.username, Boolean(data.is_god));
  redirect(data?.is_god ? "/god" : "/me");
}
