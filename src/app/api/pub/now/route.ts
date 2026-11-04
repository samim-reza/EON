import { json, onlyParams, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

export async function GET(req: Request) {
  if (onlyParams(new URL(req.url), [])) return problem(400, "unknown parameter");
  try {
    return json(await pub.now(), { kind: "shared", sMaxAge: 10, swr: 20, browser: 5 });
  } catch {
    return problem(503, "world unavailable");
  }
}
