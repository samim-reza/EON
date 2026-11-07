"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { clientKey } from "@/lib/client-key";
import { forgetNav, rememberNav } from "@/lib/nav-session";
import { adminClient } from "@/lib/supabase/admin";
import { createUserClient } from "@/lib/supabase/server";

const schema = z.object({
  email: z.email().max(254),
  password: z.string().min(1).max(200),
});

export type LoginState = { error: string | null };

export async function signIn(_prev: LoginState, form: FormData): Promise<LoginState> {
  const parsed = schema.safeParse({ email: form.get("email"), password: form.get("password") });
  if (!parsed.success) return { error: "Enter a valid email and password." };
  // Attempts are counted per network and per account before Auth sees them, so one attacker cannot
  // spend the sign-in budget that Supabase keys on our server's shared address.
  const { error: gateError } = await adminClient().rpc("login_gate", { p_client: await clientKey(), p_email: parsed.data.email });
  if (gateError) return { error: gateError.code === "P0429" ? "Too many attempts. Try again in 15 minutes." : "Sign-in is unavailable right now." };
  const supabase = await createUserClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  // Same message for every failure: never reveal whether an email exists.
  if (error) return { error: "Those credentials did not work." };
  const { data } = await supabase.rpc("whoami");
  if (data?.username) await rememberNav(data.username, Boolean(data.is_god));
  redirect(data?.is_god ? "/god" : "/me");
}

export async function signOut() {
  const supabase = await createUserClient();
  await supabase.auth.signOut();
  await forgetNav();
  redirect("/");
}
