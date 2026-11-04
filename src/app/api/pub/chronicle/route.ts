import { json, onlyParams, problem } from "@/lib/http";
import { pub } from "@/lib/pub";

export const dynamic = "force-dynamic";

export async function GET(req: Request) {
  if (onlyParams(new URL(req.url), [])) return problem(400, "unknown parameter");
  return json(await pub.chronicle(200), { kind: "shared", sMaxAge: 60, swr: 300 });
}
