"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import type { AgentDetail, FeedEvent } from "@/shared/types";
import { EventLine } from "./EventLine";
import { toggleFollow, useFollowing } from "./follow";
import { LiveActivity, LiveAge } from "./WorldClock";

/**
 * The people this visitor follows: what each is doing right now, and what has lately happened to
 * them. Shown only once someone is followed, so the front page stays clean for a first visit.
 */
export function YourPeople() {
  const following = useFollowing();
  const [people, setPeople] = useState<Record<number, AgentDetail | null>>({});
  const [events, setEvents] = useState<FeedEvent[]>([]);
  const key = (following ?? []).map((p) => p.id).join(",");

  useEffect(() => {
    const ids = key ? key.split(",").map(Number).slice(0, 12) : [];
    if (!ids.length) return;
    let live = true;
    const load = async () => {
      if (document.visibilityState !== "visible") return;
      const [details, feed] = await Promise.all([
        Promise.all(
          ids.map(async (id) => {
            try {
              const r = await fetch(`/api/pub/agent/${id}`);
              return [id, r.ok ? ((await r.json()) as AgentDetail) : null] as const;
            } catch {
              return [id, null] as const;
            }
          }),
        ),
        fetch("/api/pub/feed?imp=1")
          .then((r) => (r.ok ? (r.json() as Promise<FeedEvent[]>) : []))
          .catch(() => [] as FeedEvent[]),
      ]);
      if (!live) return;
      setPeople(Object.fromEntries(details));
      const mine = new Set(ids);
      setEvents(feed.filter((e) => (e.agent !== null && mine.has(e.agent)) || (e.other !== null && mine.has(e.other))).slice(0, 6));
    };
    void load();
    const timer = setInterval(load, 60_000);
    return () => {
      live = false;
      clearInterval(timer);
    };
  }, [key]);

  if (!following || following.length === 0) return null;
  return (
    <section className="mx-auto max-w-6xl px-4 pt-14">
      <div className="panel p-5">
        <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="font-semibold">Your people</h2>
          <span className="text-xs text-ink-3">Followed in this browser · no account needed</span>
        </div>
        <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {following.map((p) => {
            const a = people[p.id];
            return (
              <li key={p.id} className="rounded-lg border border-line/60 p-3 text-sm">
                <div className="flex items-start justify-between gap-2">
                  <Link href={`/agents/${p.id}`} prefetch={false} className="font-medium text-ink hover:underline">
                    {a ? `${a.name} ${a.surname}` : p.name}
                  </Link>
                  <button type="button" onClick={() => toggleFollow(p)} className="text-xs text-ink-3 hover:text-ink" aria-label={`Stop following ${p.name}`}>
                    ✕
                  </button>
                </div>
                {a === null && <p className="mt-1 text-ink-3">Nothing is known about them right now.</p>}
                {a && a.alive && (
                  <>
                    <p className="mt-1 text-ink-2">
                      <LiveAge birthTick={a.birthTick} /> old · {a.occupation} in {a.settlement?.name ?? "the wilds"}
                      {a.pregnant ? " · expecting a child" : ""}
                    </p>
                    {a.settlement?.x != null && a.settlement.y != null && (
                      <p className="mt-1 text-xs text-ink-3">
                        <LiveActivity
                          person={{ id: a.id, job: a.occupation ?? "adult", birth: a.birthTick, home: a.homeId ?? null }}
                          place={{ name: a.settlement.name, x: a.settlement.x, y: a.settlement.y }}
                        />
                      </p>
                    )}
                  </>
                )}
                {a && !a.alive && (
                  <p className="mt-1 text-death">
                    Died of {a.cause} · <Link href={`/agents/${p.id}`} prefetch={false} className="underline">remember them</Link>
                  </p>
                )}
              </li>
            );
          })}
        </ul>
        {events.length > 0 && (
          <div className="mt-4 border-t border-line/60 pt-3">
            <div className="mb-1 text-xs uppercase tracking-wide text-ink-3">Lately</div>
            <ul className="divide-y divide-line/60">
              {events.map((e) => (
                <EventLine key={e.id} e={e} />
              ))}
            </ul>
          </div>
        )}
      </div>
    </section>
  );
}
