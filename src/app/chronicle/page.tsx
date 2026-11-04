import type { Metadata } from "next";
import { EventLine } from "@/components/EventLine";
import { pub } from "@/lib/pub";
import type { AnnalEntry, FeedEvent } from "@/shared/types";

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

export default async function HistoryPage() {
  const [rows, annals] = await Promise.all([pub.chronicle(200).catch(() => []), pub.annals().catch(() => [])]);
  return (
    <div className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="text-2xl font-semibold">The history of EON</h1>
      <p className="mt-1 text-sm text-ink-2">Everything that shaped this world. Unlike the live feed, this is kept forever.</p>

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
