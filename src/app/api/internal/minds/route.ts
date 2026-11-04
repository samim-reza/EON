import { json, problem } from "@/lib/http";
import { writeLine } from "@/lib/minds";
import { adminClient } from "@/lib/supabase/admin";
import { verifyWake, type MindJob } from "@/shared/minds";

export const dynamic = "force-dynamic";
export const maxDuration = 50;

const BATCH = 6;

/** Woken by the database every two minutes while there is work. Almost all its time is spent waiting on Claude. */
export async function POST(req: Request) {
  const secret = process.env.MINDS_SECRET;
  if (!secret || !process.env.ANTHROPIC_API_KEY) return problem(503, "not configured");
  if (!verifyWake(req.headers.get("x-eon-sig"), secret, Date.now() / 1000)) return problem(401, "unauthorized");

  const db = adminClient();
  const { data, error } = await db.rpc("minds_claim", { p_limit: BATCH });
  if (error) return problem(503, "database unavailable");
  const jobs = data as MindJob[];
  const results = await Promise.all(
    jobs.map(async (job) => {
      const line = await writeLine(job);
      await db.rpc("minds_finish", { p_job: job.id, p_text: line.text, p_in: line.tokensIn, p_out: line.tokensOut });
      return line.text !== null;
    }),
  );
  return json({ claimed: jobs.length, written: results.filter(Boolean).length }, { kind: "none" });
}
