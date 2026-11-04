import "server-only";
import { createUserClient } from "@/lib/supabase/server";

export type Me = { userId: string; username: string | null; isGod: boolean; aal: string | null };

/** Current signed-in account, verified against Supabase Auth (never trusts the cookie alone). */
export async function getMe(): Promise<Me | null> {
  const supabase = await createUserClient();
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims?.sub) return null;
  const { data, error } = await supabase.rpc("whoami");
  if (error || !data) return null;
  return { userId: data.user_id, username: data.username, isGod: data.is_god, aal: data.aal };
}
