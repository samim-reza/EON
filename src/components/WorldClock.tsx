"use client";

import { useEffect, useState } from "react";
import { eonClock, formatAgeExact } from "@/shared/time";
import type { NowState } from "@/shared/types";
import { currentTick, useWorld } from "./world-time";

/** Re-reads world time once a second. An EON minute lasts 1/6 of a real second, so the clock visibly runs. */
function useTick(): number | null {
  useWorld(); // Subscribing is what starts the shared poller; a page may have no other live widget.
  const [tick, setTick] = useState<number | null>(null);
  useEffect(() => {
    const update = () => setTick(currentTick());
    const first = setTimeout(update, 0);
    const id = setInterval(update, 1000);
    return () => {
      clearTimeout(first);
      clearInterval(id);
    };
  }, []);
  return tick;
}

export function WorldClock({ initial = null }: { initial?: NowState | null }) {
  const { now } = useWorld(initial);
  const tick = useTick();
  if (!now) return null;
  if (!now.genesis) return <div className="panel px-3 py-2 font-mono text-sm text-ink-3">The void, before time</div>;
  const c = eonClock(tick ?? now.tick);
  return (
    <div className="panel px-3 py-2 text-right backdrop-blur-sm" aria-label={`World time: Year ${c.year}, ${c.monthName} ${c.day}, ${c.time}`}>
      <div className="font-mono text-2xl font-semibold leading-none tabular-nums">{c.time}</div>
      <div className="mt-1 text-xs text-ink-2">
        Year {c.year} · {c.monthName} {c.day}
      </div>
      <div className="text-[11px] text-ink-3">
        {c.season} · {now.paused ? <span className="text-god">time is paused</span> : c.phaseName}
      </div>
    </div>
  );
}

/** An agent's age, counting up live. `fallback` is what the server rendered. */
export function LiveAge({ birthTick, fallback = "" }: { birthTick: number; fallback?: string }) {
  const tick = useTick();
  return <>{tick === null ? fallback : formatAgeExact(tick - birthTick)}</>;
}

export function LiveStats({ initial }: { initial: NowState | null }) {
  const { now } = useWorld(initial);
  const s = now?.stats;
  const settlements = now?.settlements ?? 0;
  const stats: [string, number, string][] = [
    ["alive", s?.population ?? 0, "text-life"],
    [settlements === 1 ? "settlement" : "settlements", settlements, "text-ink"],
    ["expecting", s?.pregnant ?? 0, "text-love"],
    ["sick", s?.sick ?? 0, "text-sick"],
  ];
  return (
    <dl className="flex flex-wrap gap-x-7 gap-y-2">
      {stats.map(([label, value, tone]) => (
        <div key={label}>
          <dd className={`text-2xl font-semibold tabular-nums ${tone}`}>{value}</dd>
          <dt className="text-xs text-ink-3">{label}</dt>
        </div>
      ))}
    </dl>
  );
}
