import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

/** Population history sampled once per EON month (or coarser). */
export async function GET(req: Request) {
  const url = new URL(req.url);
  if (onlyParams(url, ["from", "to", "step"])) return problem(400, "unknown parameter");
  const from = parseIntStrict(url.searchParams.get("from"), 0, 2_000_000_000);
  const to = parseIntStrict(url.searchParams.get("to"), 0, 2_000_000_000);
  const step = parseIntStrict(url.searchParams.get("step") ?? "120", 120, 144_000);
  if (from === null || to === null || step === null || to <= from || step % 120 !== 0) return problem(400, "bad range");
  return json(await pub.stats(from, to, step), { kind: "shared", sMaxAge: 300, swr: 900 });
}
