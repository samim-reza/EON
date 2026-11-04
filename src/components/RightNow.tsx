"use client";

import { ticksToFullMoon } from "@/shared/climate";
import { planFor, slotInfo, SLOTS_PER_TICK } from "@/shared/daily-life";
import { ageName, knownBuildings } from "@/shared/progress";
import { realDuration, ticksToHarvest } from "@/shared/time";
import type { NowState } from "@/shared/types";
import { weatherHere } from "./local-climate";
import { skyAt, weatherLine } from "./WorldClock";
import { useFocus, useResidents, useTick, useWorld } from "./world-time";

const MAX_NAMED = 4; // beyond this, a place is described by what most people are doing

/** What is going on at this moment, and what is about to. It is all derived in the browser. */
export function RightNow({ initial = null, heading = true }: { initial?: NowState | null; heading?: boolean }) {
  const { now } = useWorld(initial);
  const tick = useTick();
  const focus = useFocus();
  const residents = useResidents();
  const place = focus ?? now?.places?.[0];
  if (!now?.genesis || !place || tick === null) return null;

  const sky = skyAt(now, place, tick);
  const { weather } = weatherHere(now, place.x, place.y, tick);
  const people = place.id === undefined ? [] : residents.get(place.id) ?? [];
  const info = slotInfo(Math.floor(tick * SLOTS_PER_TICK), place.x);
  const has = knownBuildings(now.known);
  const doing = people.map((p) => ({ p, doing: planFor({ id: p.id, job: p.job, ageYears: (tick - p.birth) / 1440, home: p.home }, info.hour, info.day, info.month, weather, has).doing }));
  const tally = new Map<string, number>();
  for (const d of doing) tally.set(d.doing, (tally.get(d.doing) ?? 0) + 1);

  // A new life always gets a line, however far off: it matters more than the moon.
  const baby = now.expecting?.[0];
  const calendar = [
    { label: "The harvest", left: ticksToHarvest(tick) },
    { label: "Full moon", left: ticksToFullMoon(Number(now.seed), tick) },
  ].sort((a, b) => a.left - b.left);
  const next = [...(baby ? [{ label: `${baby.name}'s baby`, left: baby.dueTick - tick }] : []), ...calendar].slice(0, 2).sort((a, b) => a.left - b.left);

  return (
    <div className="text-sm">
      {now.age !== undefined && <p className="mb-1 text-xs text-god">{ageName(now.age)}</p>}
      {heading && <h2 className="text-xs uppercase tracking-widest text-ink-3">Right now in {place.name}</h2>}
      <p className="mt-1 text-ink">
        {weatherLine(sky)}, {Math.round(weather.temp)}°C
      </p>
      {doing.length > 0 && doing.length <= MAX_NAMED && (
        <ul className="mt-1 space-y-0.5 text-xs text-ink-2">
          {doing.map(({ p, doing: what }) => (
            <li key={p.id}>
              <span className="text-ink">{p.name}</span> · {what.toLowerCase()}
            </li>
          ))}
        </ul>
      )}
      {doing.length > MAX_NAMED && (
        <ul className="mt-1 space-y-0.5 text-xs text-ink-2">
          {[...tally].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([what, count]) => (
            <li key={what}>
              <span className="tabular-nums text-ink">{count}</span> · {what.toLowerCase()}
            </li>
          ))}
        </ul>
      )}
      <h3 className="mt-2 text-xs uppercase tracking-widest text-ink-3">Coming up</h3>
      <ul className="mt-1 space-y-0.5 text-xs text-ink-2">
        {next.map((n) => (
          <li key={n.label} className="flex justify-between gap-2">
            <span>{n.label}</span>
            <span className="shrink-0 tabular-nums text-ink-3">{n.left > 0 ? `in ${realDuration(n.left)}` : "any moment"}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
