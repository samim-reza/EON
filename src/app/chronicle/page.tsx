import type { Metadata } from "next";
import { EventLine } from "@/components/EventLine";
import { pub } from "@/lib/pub";
import { AGES } from "@/shared/progress";
import { formatEonDate } from "@/shared/time";
import type { AnnalEntry, FeedEvent, Progress } from "@/shared/types";

export const revalidate = 60;
export const metadata: Metadata = {
  title: "History",
  description: "The history of EON: every year so far, and the moments that are kept forever.",
};

const HEADLINES: Record<string, string> = {
  blizzard: "The year of the great blizzard",
  flood: "The year of the flood",
  surge: "The year the sea came ashore",
  heatwave: "The year of the heatwave",
  cold_snap: "The year of the bitter cold",
  drought: "The year of the drought",
  sandstorm: "The year of the sandstorm",
  storm: "The year of the storms",
  first_snow: "A year of first snow",
};

function headline(a: AnnalEntry) {
  const h = a.headline;
  if (!h) return "A quiet year";
  const place = h.place ? ` in ${h.place}` : "";
  switch (h.kind) {
    case "weather":
      return `${HEADLINES[String(h.data.kind)] ?? "A year of hard weather"}${place}`;
    case "harvest":
      return h.data.good ? `A bumper harvest${place}` : `The harvest failed${place}`;
    case "outbreak":
      return `${String(h.data.disease)} broke out${place}`;
    case "founded":
      return `${String(h.data.name)} was founded`;
    case "became_town":
      return `${String(h.data.name)} grew into a town`;
    case "became_city":
      return `${String(h.data.name)} became a city`;
    default:
      return "A quiet year";
  }
}

function Year({ a }: { a: AnnalEntry }) {
  const facts: [string, number][] = [
    ["born", a.births],
    ["died", a.deaths],
    ["married", a.weddings],
    ["outbreaks", a.outbreaks],
  ];
  return (
    <li className="py-3">
      <div className="flex flex-wrap items-baseline justify-between gap-x-4">
        <h3 className="font-medium">
          Year {a.year}: <span className="text-ink-2">{headline(a)}</span>
        </h3>
        <span className="text-xs tabular-nums text-ink-3">
          {a.population} alive · {a.settlements} {a.settlements === 1 ? "settlement" : "settlements"}
        </span>
      </div>
      <p className="mt-1 text-xs text-ink-3">
        {facts.map(([label, count]) => `${count} ${label}`).join(" · ")}
        {a.good_harvests + a.bad_harvests > 0 ? ` · ${a.good_harvests} bumper, ${a.bad_harvests} failed harvests` : ""}
      </p>
      {a.high != null && a.low != null && (
        <p className="text-xs text-ink-3">
          Hottest {Math.round(a.high)}°C{a.high_at ? ` in ${a.high_at}` : ""} · coldest {Math.round(a.low)}°C{a.low_at ? ` in ${a.low_at}` : ""}
        </p>
      )}
    </li>
  );
}

function RoadOfProgress({ progress }: { progress: Progress }) {
  const found = progress.discoveries.filter((d) => d.tick !== null);
  const ahead = progress.discoveries.filter((d) => d.tick === null);
  const next = ahead[0];
  const before = found.length ? Math.max(...found.map((d) => d.cost)) : 0;
  const share = next ? Math.min(100, Math.max(0, ((progress.knowledge - before) / (next.cost - before)) * 100)) : 100;
  const age = found.length ? Math.max(...found.map((d) => d.age)) : 1;
  return (
    <>
      <h2 className="mt-8 text-lg font-semibold">The road of progress</h2>
      <p className="mt-1 text-sm text-ink-2">
        People start with nothing and work everything out for themselves. They are in <span className="text-god">{AGES[age - 1]}</span>.
      </p>
      <div className="panel mt-3 p-5">
        {next && (
          <div className="mb-4">
            <div className="flex justify-between text-xs text-ink-3">
              <span>Next: {next.name}</span>
              <span>{found.length} of {progress.discoveries.length} discoveries</span>
            </div>
            <div className="mt-1 h-1.5 overflow-hidden rounded bg-line/60">
              <div className="h-full bg-god" style={{ width: `${share}%` }} />
            </div>
          </div>
        )}
        {found.length === 0 ? (
          <p className="py-2 text-center text-sm text-ink-3">Nothing has been discovered yet.</p>
        ) : (
          <ul className="divide-y divide-line/60 text-sm">
            {found.map((d) => (
              <li key={d.id} className="flex justify-between gap-4 py-2">
                <span className="text-ink-2">
                  <span className="font-medium text-ink">{d.name}:</span> {d.by ?? "Someone"} {d.story}
                  {d.place ? ` in ${d.place}` : ""}
                </span>
                <span className="shrink-0 font-mono text-[11px] text-ink-3">{formatEonDate(d.tick!)}</span>
              </li>
            ))}
          </ul>
        )}
        {ahead.length > 1 && <p className="mt-3 text-xs text-ink-3">Still to come: {ahead.slice(1, 5).map((d) => d.name).join(", ")}, and {Math.max(0, ahead.length - 5)} more.</p>}
      </div>
    </>
  );
}

export default async function HistoryPage() {
  const [rows, annals, progress] = await Promise.all([pub.chronicle(200).catch(() => []), pub.annals().catch(() => []), pub.progress().catch(() => null)]);
  return (
    <div className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="text-2xl font-semibold">The history of EON</h1>
      <p className="mt-1 text-sm text-ink-2">Everything that shaped this world. Unlike the live feed, this is kept forever.</p>

      {progress && <RoadOfProgress progress={progress} />}

      <h2 className="mt-8 text-lg font-semibold">Year by year</h2>
      <div className="panel mt-3 px-5 py-2">
        {annals.length === 0 ? (
          <p className="py-6 text-center text-sm text-ink-3">The first year of EON is still being written.</p>
        ) : (
          <ul className="divide-y divide-line/60">
            {annals.map((a) => (
              <Year key={a.year} a={a} />
            ))}
          </ul>
        )}
      </div>

      <h2 className="mt-8 text-lg font-semibold">Moments that made history</h2>
      <p className="mt-1 text-sm text-ink-2">Foundings, milestones, and the first time anything ever happened.</p>
      <div className="panel mt-3 p-5">
        {rows.length === 0 ? (
          <p className="py-6 text-center text-sm text-ink-3">History has not begun.</p>
        ) : (
          <ul className="divide-y divide-line/60">
            {rows.map((r) => (
              <EventLine key={r.id} e={{ ...(r as FeedEvent), imp: 3, settlement: null }} />
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
