"use client";

import { useEffect, useRef, useState } from "react";
import type { FeedEvent } from "@/shared/types";
import { EventLine } from "./EventLine";

type Props = { initial: FeedEvent[]; importance?: 1 | 2 | 3; pageable?: boolean; limit?: number };

/** Newest-first event stream. Head is refreshed from the CDN every 30 s while visible. */
export function LiveFeed({ initial, importance = 2, pageable = false, limit }: Props) {
  const [events, setEvents] = useState(initial);
  const [loadingMore, setLoadingMore] = useState(false);
  const [done, setDone] = useState(false);
  const seen = useRef(new Set(initial.map((e) => e.id)));

  useEffect(() => {
    const refresh = async () => {
      if (document.visibilityState !== "visible") return;
      try {
        const r = await fetch(`/api/pub/feed?imp=${importance}`);
        if (!r.ok) return;
        const fresh: FeedEvent[] = await r.json();
        const add = fresh.filter((e) => !seen.current.has(e.id));
        if (add.length) {
          add.forEach((e) => seen.current.add(e.id));
          setEvents((prev) => [...add, ...prev].slice(0, limit ?? 400));
        }
      } catch {
        /* ignore */
      }
    };
    const id = setInterval(refresh, 30_000);
    return () => clearInterval(id);
  }, [importance, limit]);

  const more = async () => {
    const last = events[events.length - 1];
    if (!last) return;
    setLoadingMore(true);
    try {
      const r = await fetch(`/api/pub/feed?imp=${importance}&before=${last.tick}`);
      const older: FeedEvent[] = r.ok ? await r.json() : [];
      const add = older.filter((e) => !seen.current.has(e.id));
      add.forEach((e) => seen.current.add(e.id));
      if (!add.length) setDone(true);
      setEvents((prev) => [...prev, ...add]);
    } finally {
      setLoadingMore(false);
    }
  };

  if (!events.length) return <p className="py-6 text-center text-sm text-ink-3">Nothing has happened yet.</p>;
  return (
    <div>
      <ul className="divide-y divide-line/60">
        {(limit ? events.slice(0, limit) : events).map((e) => (
          <EventLine key={e.id} e={e} />
        ))}
      </ul>
      {pageable && !done && (
        <button onClick={more} disabled={loadingMore} className="btn btn-ghost mt-4 w-full">
          {loadingMore ? "Loading…" : "Older events"}
        </button>
      )}
    </div>
  );
}
