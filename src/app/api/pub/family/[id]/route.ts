import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

export async function GET(req: Request, ctx: RouteContext<"/api/pub/family/[id]">) {
  if (onlyParams(new URL(req.url), [])) return problem(400, "unknown parameter");
  const id = parseIntStrict((await ctx.params).id, 1, 9_000_000_000_000);
  if (id === null) return problem(400, "bad id");
  return json(await pub.family(id), { kind: "shared", sMaxAge: 300, swr: 900 });
}
