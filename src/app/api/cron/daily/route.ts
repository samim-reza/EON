import { timingSafeEqual } from "node:crypto";
import { json, problem } from "@/lib/http";
import { adminClient } from "@/lib/supabase/admin";

export const dynamic = "force-dynamic";

function authorized(req: Request): boolean {
  const secret = process.env.CRON_SECRET;
  const got = req.headers.get("authorization") ?? "";
  if (!secret) return false;
  const want = Buffer.from(`Bearer ${secret}`);
  const have = Buffer.from(got);
  return want.length === have.length && timingSafeEqual(want, have);
}

/** Daily Vercel cron: proves the world is alive and keeps the Supabase project active. */
export async function GET(req: Request) {
  if (!authorized(req)) return problem(401, "unauthorized");
  const { data, error } = await adminClient().rpc("heartbeat");
  if (error) return problem(503, "database unavailable");
  return json({ ok: true, ...data }, { kind: "none" });
}
