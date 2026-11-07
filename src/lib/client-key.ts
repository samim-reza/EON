import "server-only";
import { createHmac } from "node:crypto";
import { headers } from "next/headers";
import { env } from "@/lib/env";

/** The visitor's network as a keyed hash: enough to rate-limit and bind challenges, never stored as an address. */
export async function clientKey() {
  const h = await headers();
  const ip = h.get("x-forwarded-for")?.split(",")[0]?.trim() || h.get("x-real-ip") || "unknown";
  return createHmac("sha256", env().SUPABASE_SECRET_KEY).update(ip).digest("hex");
}

/** A key for signing sign-up challenges, derived so that no extra secret is needed. */
export const powKey = () => createHmac("sha256", env().SUPABASE_SECRET_KEY).update("eon:pow").digest("hex");
