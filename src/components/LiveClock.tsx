"use client";

import { useEffect, useState } from "react";
import type { NowState } from "@/shared/types";
import { eonDate } from "@/shared/time";

/** World clock. Polls the CDN-cached /api/pub/now only while the tab is visible. */
export function useNow(initial: NowState | null, everyMs = 30_000) {
  const [now, setNow] = useState<NowState | null>(initial);
  useEffect(() => {
    let alive = true;
    const load = async () => {
      if (document.visibilityState !== "visible") return;
      try {
        const r = await fetch("/api/pub/now");
        if (r.ok && alive) setNow(await r.json());
      } catch {
        /* offline: keep last state */
      }
    };
    const id = setInterval(load, everyMs);
    document.addEventListener("visibilitychange", load);
    if (!initial) load();
    return () => {
      alive = false;
      clearInterval(id);
      document.removeEventListener("visibilitychange", load);
    };
  }, [everyMs, initial]);
  return now;
}

export function LiveClock({ initial }: { initial: NowState | null }) {
  const now = useNow(initial);
  if (!now) return null;
  if (!now.genesis) {
    return <div className="font-mono text-sm text-ink-3">The void — before time</div>;
  }
  const d = eonDate(now.tick);
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-sm">
      <span className="text-ink">Year {d.year}</span>
      <span className="text-ink-2">
        {d.monthName} {d.day} · {d.season}
      </span>
      <span className="tag">{d.phaseName}</span>
      {now.paused && <span className="tag text-god">time is paused</span>}
    </div>
  );
}
