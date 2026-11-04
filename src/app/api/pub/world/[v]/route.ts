import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

/** Living roster + geography for roster version v. Immutable when the version matches. */
export async function GET(req: Request, ctx: RouteContext<"/api/pub/world/[v]">) {
  if (onlyParams(new URL(req.url), [])) return problem(400, "unknown parameter");
  const v = parseIntStrict((await ctx.params).v, 0, 2_000_000_000);
  if (v === null) return problem(400, "bad version");
  const [roster, geo] = await Promise.all([pub.roster(), pub.geo()]);
  const exact = roster.version === v;
  return json({ roster, geo }, exact ? { kind: "immutable" } : { kind: "shared", sMaxAge: 20 });
}
