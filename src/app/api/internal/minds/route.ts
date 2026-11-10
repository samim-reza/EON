import { json, problem } from "@/lib/http";
import { mailReady, sendMail } from "@/lib/mail";
import { writeLine } from "@/lib/minds";
import { siteUrl } from "@/lib/site";
import { think, type SoulJob } from "@/lib/soul";
import { adminClient } from "@/lib/supabase/admin";
import { bornEmail, trialOverEmail, type EmailFacts } from "@/shared/emails";
import { verifyWake, type MindJob } from "@/shared/minds";

export const dynamic = "force-dynamic";
export const maxDuration = 50;

const BATCH = 8;

type Mail = EmailFacts & { id: number; kind: "born" | "trial_over"; email?: string };

/**
 * Woken by the database every two minutes while there is work: lines in EON's narrator voice, the
 * thoughts and choices of people with souls, and emails to players. Almost all its time is spent
 * waiting on the models.
 */
export async function POST(req: Request) {
  const secret = process.env.MINDS_SECRET;
  if (!secret || !process.env.ANTHROPIC_API_KEY) return problem(503, "not configured");
  // The database signs the moment it calls; 45 s covers clock drift and leaves little room for a replay.
  if (!verifyWake(req.headers.get("x-eon-sig"), secret, Date.now() / 1000, 45)) return problem(401, "unauthorized");

  const db = adminClient();
  const { data, error } = await db.rpc("minds_claim", { p_limit: BATCH });
  if (error) return problem(503, "database unavailable");
  const jobs = data as (MindJob | SoulJob)[];
  const problems: Record<string, number> = {};
  const note = (p: string) => (problems[p] = (problems[p] ?? 0) + 1);

  const results = await Promise.all(
    jobs.map(async (job) => {
      if ("soul" in job && job.soul) {
        const t = await think(job);
        await db.rpc("minds_finish_soul", {
          p_job: job.id, p_choice: t.choice, p_text: t.thought, p_prayer: t.prayer, p_in: t.tokensIn, p_out: t.tokensOut,
          p_problem: job.mind.source === "own" ? t.problem : null,
        });
        if (t.problem) note(`soul ${job.mind.source}: ${t.problem}`);
        return t.thought !== null || t.choice !== null;
      }
      const line = await writeLine(job as MindJob);
      await db.rpc("minds_finish", { p_job: job.id, p_text: line.text, p_in: line.tokensIn, p_out: line.tokensOut });
      if (line.problem) note(line.problem);
      return line.text !== null;
    }),
  );

  let mailed = 0;
  if (mailReady()) {
    const { data: mails } = await db.rpc("outbox_claim", { p_limit: 10 });
    for (const m of (mails ?? []) as Mail[]) {
      let ok = true;
      if (m.email) {
        try {
          await sendMail(m.email, m.kind === "born" ? bornEmail(m, siteUrl) : trialOverEmail(m, siteUrl));
          mailed += 1;
        } catch (e) {
          ok = false;
          note(`mail: ${e instanceof Error ? e.name : "unknown"}`);
        }
      }
      await db.rpc("outbox_finish", { p_id: m.id, p_ok: ok });
    }
  }

  // The database keeps this reply for a day (net._http_response), and the log keeps it too.
  if (Object.keys(problems).length) console.error("minds: some work was not done", problems);
  return json({ claimed: jobs.length, written: results.filter(Boolean).length, mailed, problems }, { kind: "none" });
}
