import { json, onlyParams, parseIntStrict, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

export async function GET(req: Request) {
  const url = new URL(req.url);
  if (onlyParams(url, ["before", "imp"])) return problem(400, "unknown parameter");
  const beforeRaw = url.searchParams.get("before");
  const before = beforeRaw === null ? null : parseIntStrict(beforeRaw, 1, 2_000_000_000);
  const imp = parseIntStrict(url.searchParams.get("imp") ?? "2", 1, 3);
  if ((beforeRaw !== null && before === null) || imp === null) return problem(400, "bad parameter");
  const rows = await pub.feed(before, 40, imp);
  // Older pages are effectively frozen; the head of the feed changes every minute.
  return json(rows, before === null ? { kind: "shared", sMaxAge: 15, swr: 30 } : { kind: "shared", sMaxAge: 3600, swr: 86400 });
}
