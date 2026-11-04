import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

export async function GET(req: Request, ctx: RouteContext<"/api/pub/agent/[id]">) {
  if (onlyParams(new URL(req.url), [])) return problem(400, "unknown parameter");
  const id = parseIntStrict((await ctx.params).id, 1, 9_000_000_000_000);
  if (id === null) return problem(400, "bad id");
  const agent = await pub.agent(id);
  if (!agent) return json({ error: "not found" }, { kind: "shared", sMaxAge: 60 }, 404);
  return json(agent, agent.alive ? { kind: "shared", sMaxAge: 60, swr: 300 } : { kind: "shared", sMaxAge: 3600, swr: 86400 });
}
