import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { describe } from "@/components/EventLine";
import { LiveActivity, LiveAge, LiveDue } from "@/components/WorldClock";
import { pub } from "@/lib/pub";
import { formatAge, formatEonDate } from "@/shared/time";
import type { AgentDetail, FeedEvent } from "@/shared/types";

export const revalidate = 60;

// Rendered on first visit, then cached (ISR) — no agent pages are built ahead of time.
export async function generateStaticParams() {
  return [];
}

async function getAgent(raw: string): Promise<AgentDetail | null> {
  if (!/^\d{1,13}$/.test(raw)) return null;
  return pub.agent(Number(raw)).catch(() => null);
}

export async function generateMetadata(props: PageProps<"/agents/[id]">): Promise<Metadata> {
  const a = await getAgent((await props.params).id);
  if (!a) return { title: "Unknown agent" };
  const fullName = `${a.name} ${a.surname}`;
  const description = `${fullName}, ${formatAge(a.age)} old, ${a.alive ? "lives" : "lived"} in ${a.settlement?.name ?? "EON"}: an AI agent with a family, a body and a fate of their own.`;
  return { title: fullName, description, openGraph: { title: `${fullName} · EON`, description } };
}

function Bar({ label, value, tone }: { label: string; value: number; tone: string }) {
  return (
    <div>
      <div className="flex justify-between text-xs text-ink-3">
        <span>{label}</span>
        <span>{value}</span>
      </div>
      <div className="mt-1 h-1.5 rounded bg-bg-2">
        <div className={`h-1.5 rounded ${tone}`} style={{ width: `${Math.max(2, Math.min(100, value))}%` }} />
      </div>
    </div>
  );
}

function Person({ p, label }: { p: { id: number; name: string; alive?: boolean } | null | undefined; label: string }) {
  return (
    <div className="flex justify-between gap-3 py-1.5 text-sm">
      <span className="text-ink-3">{label}</span>
      {p ? (
        <Link href={`/agents/${p.id}`} prefetch={false} className={`hover:underline ${p.alive === false ? "text-ink-3" : "text-ink"}`}>
          {p.name}
          {p.alive === false ? " ✝" : ""}
        </Link>
      ) : (
        <span className="text-ink-3">—</span>
      )}
    </div>
  );
}

export default async function AgentPage(props: PageProps<"/agents/[id]">) {
  const a = await getAgent((await props.params).id);
  if (!a) notFound();
  const pronoun = a.sex === "F" ? "she" : "he";
  return (
    <div className="mx-auto max-w-5xl px-4 py-10">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex flex-wrap gap-2">
            {a.founder && <span className="tag text-god">founder</span>}
            {a.isPlayer && <span className="tag text-life">human soul</span>}
            <span className="tag">generation {a.generation}</span>
            {!a.alive && <span className="tag text-death">deceased</span>}
          </div>
          <h1 className="mt-3 text-3xl font-semibold">
            {a.name} {a.surname}
          </h1>
          <p className="mt-1 text-ink-2">
            {a.alive ? (
              <>
                <LiveAge birthTick={a.birthTick} fallback={formatAge(a.age)} /> old · {a.occupation} in {a.settlement?.name ?? "the wilds"}
                {a.pregnant ? " · expecting a child" : ""}
                {a.pregnant && a.dueTick != null ? (
                  <>
                    {" "}· <LiveDue dueTick={a.dueTick} />
                  </>
                ) : null}
              </>
            ) : (
              <>
                Lived {formatAge(a.age)} · died of <span className="text-death">{a.cause}</span> on{" "}
                {a.deathTick != null ? formatEonDate(a.deathTick) : "?"}
              </>
            )}
          </p>
          {a.alive && a.settlement?.x != null && a.settlement.y != null && (
            <p className="mt-1 text-sm text-ink-3">
              <LiveActivity
                person={{ id: a.id, job: a.occupation ?? "adult", birth: a.birthTick, home: a.homeId ?? null }}
                place={{ name: a.settlement.name, x: a.settlement.x, y: a.settlement.y }}
                showWeather
              />
            </p>
          )}
        </div>
        <Link href={`/family/${a.id}`} prefetch={false} className="btn btn-ghost">
          Family tree
        </Link>
      </div>

      <div className="mt-8 grid gap-6 lg:grid-cols-[1fr_1.5fr]">
        <div className="space-y-6">
          {a.alive && a.health != null && (
            <div className="panel space-y-3 p-5">
              <Bar label="Health" value={a.health} tone="bg-life" />
              <Bar label="Happiness" value={a.happiness ?? 0} tone="bg-love" />
              <Bar label="Education" value={a.education ?? 0} tone="bg-ink-2" />
              <div className="flex justify-between pt-1 text-sm">
                <span className="text-ink-3">Wealth</span>
                <span className="tabular-nums">{a.wealth?.toLocaleString()} credits</span>
              </div>
              {a.diagnosed && (
                <p className="text-sm text-sick">Living with {a.diagnosed}.</p>
              )}
              {a.sick && a.sick.length > 0 && <p className="text-sm text-sick">Currently ill: {a.sick.join(", ")}</p>}
            </div>
          )}
          <div className="panel p-5">
            <h2 className="mb-2 font-semibold">Family</h2>
            <Person p={a.mother} label="Mother" />
            <Person p={a.father} label="Father" />
            {a.alive && <Person p={a.partner} label="Partner" />}
            <div className="mt-2 border-t border-line/60 pt-2">
              <div className="text-xs text-ink-3">Children ({a.children.length})</div>
              <div className="mt-1 flex flex-wrap gap-2">
                {a.children.map((c) => (
                  <Link key={c.id} href={`/agents/${c.id}`} prefetch={false} className={`tag hover:text-ink ${c.alive ? "" : "opacity-60"}`}>
                    {c.name}
                    {c.alive ? "" : " ✝"}
                  </Link>
                ))}
                {a.children.length === 0 && <span className="text-sm text-ink-3">none</span>}
              </div>
            </div>
          </div>
          {a.traits && (
            <div className="panel space-y-3 p-5">
              <h2 className="font-semibold">Personality</h2>
              {Object.entries(a.traits).map(([k, v]) => (
                <Bar key={k} label={k} value={v} tone="bg-life-2" />
              ))}
            </div>
          )}
        </div>
        <div className="panel p-5">
          <h2 className="mb-1 font-semibold">Life story</h2>
          <p className="mb-3 text-xs text-ink-3">
            Born {formatEonDate(a.birthTick)}. What {pronoun} has lived through so far:
          </p>
          {a.story.length === 0 ? (
            <p className="text-sm text-ink-3">A quiet life, so far.</p>
          ) : (
            <ol className="relative space-y-3 border-l border-line pl-4">
              {a.story.map((s, i) => (
                <li key={i} className="text-sm">
                  <div className="font-mono text-[11px] text-ink-3">{formatEonDate(s.tick)}</div>
                  <div className="text-ink-2">
                    {describe({
                      id: i, tick: s.tick, kind: s.kind, imp: 2, settlement: null, data: s.data,
                      agent: s.agent, agentName: s.agentName, other: s.other, otherName: s.otherName,
                    } as FeedEvent)}
                  </div>
                </li>
              ))}
            </ol>
          )}
        </div>
      </div>
    </div>
  );
}
