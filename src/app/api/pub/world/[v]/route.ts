import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

/**
 * Living roster + geography for roster version v. Immutable when the version matches.
 *
 * The land around each village (woods, herds, soil) changes without anyone being born or dying, so
 * the map also names the EON month it is asking in (`m`). That gives the same snapshot a fresh
 * cache key once a month: twelve a real day, however many people are watching.
 */
export async function GET(req: Request, ctx: RouteContext<"/api/pub/world/[v]">) {
  const url = new URL(req.url);
  if (onlyParams(url, ["m"])) return problem(400, "unknown parameter");
  const asked = url.searchParams.get("m");
  const month = asked === null ? null : parseIntStrict(asked, 0, 20_000_000);
  if (asked !== null && month === null) return problem(400, "bad month");
  const v = parseIntStrict((await ctx.params).v, 0, 2_000_000_000);
  if (v === null) return problem(400, "bad version");
  // Only the current version is served: any other number would be a fresh cache key for the same
  // heavy query, so a stale or made-up one gets a short answer and the client asks again.
  const now = await pub.now();
  if (!now || now.rosterVersion !== v) return json({ error: "not the current version", version: now?.rosterVersion ?? null }, { kind: "shared", sMaxAge: 20 }, 409);
  // Only this month and the one just ended are real keys (a viewer's clock can lag a few seconds at the turn).
  const thisMonth = Math.floor(now.tick / 120);
  if (month !== null && month !== thisMonth && month !== thisMonth - 1) return json({ error: "not the current month", month: thisMonth }, { kind: "shared", sMaxAge: 20 }, 409);
  const [roster, geo] = await Promise.all([pub.roster(), pub.geo()]);
  return json({ roster, geo }, roster.version === v ? { kind: "immutable" } : { kind: "shared", sMaxAge: 20 });
}
