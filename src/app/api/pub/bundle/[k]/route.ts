import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";
const BUNDLE_TICKS = 5;

/** Five ticks of history. Immutable once complete → served from the CDN to every viewer. */
export async function GET(req: Request, ctx: RouteContext<"/api/pub/bundle/[k]">) {
  if (onlyParams(new URL(req.url), [])) return problem(400, "unknown parameter");
  const k = parseIntStrict((await ctx.params).k, 0, 50_000_000);
  if (k === null) return problem(400, "bad bundle");
  const now = await pub.now();
  const from = k * BUNDLE_TICKS;
  const to = from + BUNDLE_TICKS;
  if (to > now.tick + 1) return json({ error: "not yet" }, { kind: "none" }, 425);
  if (to < now.tick - 3 * 1440) return problem(410, "expired");
  return json(await pub.events(from, to), { kind: "immutable" });
}
