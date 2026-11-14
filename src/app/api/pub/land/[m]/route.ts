import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";
import type { Geo, LandFeed } from "@/shared/types";

export const dynamic = "force-dynamic";

/** Before the land feed exists in the database, the same numbers are cut out of the full geography. */
const fromGeo = (geo: Geo): LandFeed["land"] =>
  geo.settlements.filter((s) => Array.isArray(s.land)).map((s) => [s.id, ...(s.land as number[]), s.burn ?? null]);

/**
 * The land around every village (woods, soil, herds, fish) for EON month m.
 *
 * Each thing the map loads is keyed by what changes it. People change the big snapshot
 * (`/api/pub/world/[v]`, keyed by the roster version). The land changes slowly and by itself, so
 * it lives here, keyed by the month: a few hundred bytes per village, fetched twelve times a real
 * day and served to everyone from the CDN.
 */
export async function GET(req: Request, ctx: RouteContext<"/api/pub/land/[m]">) {
  if (onlyParams(new URL(req.url), [])) return problem(400, "unknown parameter");
  const m = parseIntStrict((await ctx.params).m, 0, 20_000_000);
  if (m === null) return problem(400, "bad month");
  // Only this month and the one just ended are real keys (a viewer's clock can lag a few seconds at
  // the turn), so nobody can mint cache keys for the same query.
  const now = await pub.now();
  const month = now ? Math.floor(now.tick / 120) : null;
  if (month === null || (m !== month && m !== month - 1)) return json({ error: "not the current month", month }, { kind: "shared", sMaxAge: 20 }, 409);
  const land = await pub.land().catch(async () => fromGeo(await pub.geo()));
  const body: LandFeed = { month: m, land };
  return json(body, m === month ? { kind: "immutable" } : { kind: "shared", sMaxAge: 60 });
}
