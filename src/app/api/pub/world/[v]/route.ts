import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

/** Living roster + geography for roster version v. Immutable when the version matches. */
export async function GET(req: Request, ctx: RouteContext<"/api/pub/world/[v]">) {
  if (onlyParams(new URL(req.url), [])) return problem(400, "unknown parameter");
  const v = parseIntStrict((await ctx.params).v, 0, 2_000_000_000);
  if (v === null) return problem(400, "bad version");
  // Only the current version is served: any other number would be a fresh cache key for the same
  // heavy query, so a stale or made-up one gets a short answer and the client asks again.
  const now = await pub.now();
  if (!now || now.rosterVersion !== v) return json({ error: "not the current version", version: now?.rosterVersion ?? null }, { kind: "shared", sMaxAge: 20 }, 409);
  const [roster, geo] = await Promise.all([pub.roster(), pub.geo()]);
  return json({ roster, geo }, roster.version === v ? { kind: "immutable" } : { kind: "shared", sMaxAge: 20 });
}
