// One-off for a world created before sites stored their geography. Run once after the climate
// migration. New worlds get it at Genesis and never need this. Safe to run twice.
// Usage: set -a; . ./.env.local; set +a; npx tsx scripts/backfill-climate.ts
import { createClient } from "@supabase/supabase-js";
import { sitesWithWater } from "../src/shared/rivers";

async function main() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) throw new Error("Set NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SECRET_KEY");

  const db = createClient(url, key, { auth: { persistSession: false }, db: { schema: "api" } });
  const { data: now, error } = await db.rpc("pub_now");
  if (error) throw error;

  const sites = sitesWithWater(Number(now.seed)).map(([id, , , , elevation, river, coast]) => [id, elevation, river, coast]);
  const { data: filled, error: fillError } = await db.rpc("set_site_geography", { p_sites: sites });
  if (fillError) throw fillError;
  console.log(`seed ${now.seed}: filled ${filled} of ${sites.length} sites`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
