import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { env } from "@/lib/env";

let client: SupabaseClient<any, "api"> | null = null; // eslint-disable-line @typescript-eslint/no-explicit-any

/**
 * Privileged client (secret key). Server-only. Used for public world reads
 * (api.pub_*, granted to service_role only) and admin tasks. Never exposed to browsers.
 */
export function adminClient() {
  if (client) return client;
  const e = env();
  client = createClient(e.NEXT_PUBLIC_SUPABASE_URL, e.SUPABASE_SECRET_KEY, {
    db: { schema: "api" },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  return client;
}
