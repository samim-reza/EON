"use client";

import { useEffect, useState } from "react";
import { BIOME_NAMES, localHour, moonAt, sunElevation, sunTimes, tideLabel, WEATHER_LABELS, type WeatherKind } from "@/shared/climate";
import { outfitFor, planFor, slotInfo, SLOTS_PER_TICK } from "@/shared/daily-life";
import { eonClock, formatAgeExact, formatEonDate, realDuration } from "@/shared/time";
import type { NowState } from "@/shared/types";
import { coastalAt, weatherHere } from "./local-climate";
import { SkyDial } from "./SkyDial";
import { currentTick, useFocus, useWorld, type Focus } from "./world-time";

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

const GLYPH: Record<WeatherKind, string> = {
  clear: "☀", partly: "⛅", cloudy: "☁", overcast: "☁", fog: "≋", drizzle: "☂", rain: "☂", downpour: "☂",
  thunderstorm: "⚡", sleet: "☂", snow: "❄", blizzard: "❄", sandstorm: "≈",
};

const pad = (n: number) => String(n).padStart(2, "0");

function hhmm(hour: number) {
  const minutes = Math.round(hour * 60) % 1440;
  return `${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}`;
}

/** Sky and weather for a place at a moment. */
function skyAt(now: NowState, place: Focus, tf: number) {
  const seed = Number(now.seed);
  const { climate, weather } = weatherHere(now, place.x, place.y, tf);
  const sun = sunElevation(tf, climate.lat, place.x);
  const times = sunTimes(tf, climate.lat);
  const hour = localHour(tf, place.x);
  const moon = moonAt(seed, tf, climate.lat, place.x);
  return {
    climate, weather, sun, times, moon,
    sunProgress: (hour - times.rise) / Math.max(0.1, times.set - times.rise),
    moonProgress: ((hour - moon.phase * 24 + 42) % 24) / 12,
  };
}

function weatherLine(sky: ReturnType<typeof skyAt>) {
  const night = sky.sun < -2;
  const label = WEATHER_LABELS[sky.weather.kind];
  return `${sky.weather.kind === "clear" && night ? "☾" : GLYPH[sky.weather.kind]} ${label === "Clear" && night ? "Clear night" : label}`;
}

export function WorldClock({ initial = null }: { initial?: NowState | null }) {
  const { now } = useWorld(initial);
  const tick = useTick();
  const focus = useFocus();
  if (!now) return null;
  if (!now.genesis) return <div className="panel px-3 py-2 font-mono text-sm text-ink-3">The void, before time</div>;
  const tf = tick ?? now.tick;
  const c = eonClock(tf);
  const sky = focus && tick !== null ? skyAt(now, focus, tf) : null;
  const sunLine = sky ? (sky.times.polar === "day" ? "Midnight sun" : sky.times.polar === "night" ? "Polar night" : `☀ ${hhmm(sky.times.rise)}–${hhmm(sky.times.set)}`) : null;
  return (
    <div className="panel w-44 overflow-hidden text-right backdrop-blur-sm sm:w-52" aria-label={`World time: Year ${c.year}, ${c.monthName} ${c.day}, ${c.time}`}>
      {sky && <SkyDial sun={sky.sun} sunProgress={sky.sunProgress} moon={sky.moon} moonProgress={sky.moonProgress} weather={sky.weather} />}
      <div className="px-3 py-2">
        <div className="flex items-baseline justify-between">
          <span className="text-lg font-medium tabular-nums text-ink">{sky ? `${Math.round(sky.weather.temp)}°` : ""}</span>
          <span className="font-mono text-2xl font-semibold leading-none tabular-nums">{c.time}</span>
        </div>
        <div className="mt-1 text-xs text-ink-2">
          Year {c.year} · {c.monthName} {c.day}
        </div>
        <div className="text-[11px] text-ink-3">
          {c.season} · {now.paused ? <span className="text-god">time is paused</span> : c.phaseName}
        </div>
        {sky && focus && (
          <>
            <div className="mt-1 truncate text-xs text-ink-2">
              {weatherLine(sky)} · {focus.name}
            </div>
            <div className="hidden truncate text-[11px] text-ink-3 sm:block">
              {sunLine} · {sky.moon.name}
            </div>
            {coastalAt(Number(now.seed), focus.x, focus.y) && (
              <div className="hidden truncate text-[11px] text-ink-3 sm:block">{tideLabel(Number(now.seed), tf, focus.x)}</div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

/** Weather and the day's routine for one person, right now. */
export function LiveActivity({ person, place, showWeather = false }: { person: { id: number; job: string; birth: number }; place: Focus; showWeather?: boolean }) {
  const { now } = useWorld();
  const tick = useTick();
  if (!now || tick === null) return null;
  const { climate, weather } = weatherHere(now, place.x, place.y, tick);
  const info = slotInfo(Math.floor(tick * SLOTS_PER_TICK), place.x);
  const who = { id: person.id, job: person.job, ageYears: (tick - person.birth) / 1440 };
  const plan = planFor(who, info.hour, info.day, info.month, weather);
  return (
    <>
      {plan.doing}, wearing {outfitFor(who, plan, weather, climate.biome).wearing}
      {showWeather && (
        <>
          {" "}· {WEATHER_LABELS[weather.kind].toLowerCase()}, {Math.round(weather.temp)}°C in the {BIOME_NAMES[climate.biome]}
        </>
      )}
    </>
  );
}

/** A pregnancy lasts about 17 real hours, so show how much of the wait is left. */
export function LiveDue({ dueTick }: { dueTick: number }) {
  const tick = useTick();
  const left = tick === null ? null : dueTick - tick;
  return <>baby due {formatEonDate(dueTick)}{left === null ? "" : left > 0 ? `, in ${realDuration(left)}` : ", any moment now"}</>;
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
