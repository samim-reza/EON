// Tells the database where the AI worker lives and how to sign its wake-up call. Run once per world.
// Usage: set -a; . ./.env.local; set +a; npx tsx scripts/setup-minds.ts https://your-site.example
import { createClient } from "@supabase/supabase-js";

async function main() {
  const site = process.argv[2];
  const { NEXT_PUBLIC_SUPABASE_URL: url, SUPABASE_SECRET_KEY: key, MINDS_SECRET: secret } = process.env;
  if (!site || !url || !key || !secret) throw new Error("Pass the site URL, and set NEXT_PUBLIC_SUPABASE_URL, SUPABASE_SECRET_KEY and MINDS_SECRET");
  const db = createClient(url, key, { auth: { persistSession: false }, db: { schema: "api" } });
  const { error } = await db.rpc("minds_configure", { p_url: new URL("/api/internal/minds", site).href, p_secret: secret });
  if (error) throw error;
  console.log(`The worker will be woken at ${new URL("/api/internal/minds", site).href}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
