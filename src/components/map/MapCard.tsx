"use client";

import { describe } from "@/components/EventLine";
import { BIOME_NAMES, WEATHER_LABELS, type Biome, type Weather } from "@/shared/climate";
import { creatureStory, describeLand, landOf, type CreatureKind } from "@/shared/nature";
import { PLACE_NAMES } from "@/shared/progress";
import { formatEonDate } from "@/shared/time";
import type { FeedEvent, Settlement } from "@/shared/types";

/** What the visitor clicked on the map that is not a person. */
export type Picked =
  | { type: "village"; id: number }
  | { type: "creature"; settlement: number; kind: CreatureKind }
  | { type: "building"; id: number };

/** The card that is open: what was clicked, with what was true at that moment. */
export type Card =
  | { type: "village"; id: number; weather: Weather }
  | { type: "creature"; settlement: number; kind: CreatureKind }
  | { type: "building"; id: number; inside: Someone[] };

type Someone = { id: number; name: string };

function Shell({ title, sub, onClose, children }: { title: string; sub?: React.ReactNode; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="panel absolute bottom-3 right-3 max-h-[70%] w-72 overflow-auto p-4 text-sm">
      <div className="flex items-start justify-between gap-2">
        <div>
          <div className="font-semibold">{title}</div>
          {sub && <div className="text-ink-2">{sub}</div>}
        </div>
        <button onClick={onClose} className="text-ink-3 hover:text-ink" aria-label="Close">
          ✕
        </button>
      </div>
      {children}
    </div>
  );
}

const country = (s: Settlement) => {
  const name = s.biome ? BIOME_NAMES[s.biome as Biome] ?? s.biome : "open country";
  return `${name.charAt(0).toUpperCase()}${name.slice(1)}${s.river ? ", by a river" : ""}${s.coast ? ", on the coast" : ""}`;
};

/** A village: who lives there, its weather, its stores, its country, and what happened lately. */
export function VillageCard({ place, weather, events, onGo, onClose }: {
  place: Settlement; weather: Weather | null; events: FeedEvent[]; onGo: () => void; onClose: () => void;
}) {
  const land = landOf(place.land);
  const food = place.food ?? 1;
  const lately = events.filter((e) => e.settlement === place.id && e.kind !== "voice").slice(0, 3);
  return (
    <Shell
      title={place.name}
      sub={<>{place.kind[0].toUpperCase() + place.kind.slice(1)} of {place.pop} · since {formatEonDate(place.founded)}</>}
      onClose={onClose}
    >
      <p className="mt-2 text-xs text-ink-3">{country(place)}</p>
      <dl className="mt-2 space-y-0.5 text-xs">
        {weather && (
          <div className="flex justify-between gap-3">
            <dt className="text-ink-2">Weather</dt>
            <dd className="text-ink-3">{WEATHER_LABELS[weather.kind]}, {Math.round(weather.temp)}°C</dd>
          </div>
        )}
        <div className="flex justify-between gap-3">
          <dt className="text-ink-2">Food stores</dt>
          <dd className={food < 0.7 ? "text-sick" : food > 1.1 ? "text-life" : "text-ink-3"}>{food < 0.7 ? "Short" : food > 1.1 ? "Plenty" : "Enough"}</dd>
        </div>
        {land && describeLand(land, place.biome, place.pop).map((line) => (
          <div key={line.label} className="flex justify-between gap-3">
            <dt className="shrink-0 text-ink-2">{line.label}</dt>
            <dd className={`text-right ${line.tone === "bad" ? "text-sick" : line.tone === "good" ? "text-life" : "text-ink-3"}`}>{line.text}</dd>
          </div>
        ))}
      </dl>
      {lately.length > 0 && (
        <>
          <h3 className="mt-3 text-xs uppercase tracking-widest text-ink-3">Lately here</h3>
          <ul className="mt-1 space-y-1 text-xs text-ink-2">
            {lately.map((e) => (
              <li key={e.id}>{describe(e)}</li>
            ))}
          </ul>
        </>
      )}
      <button className="btn btn-ghost mt-3 w-full justify-center text-sm" onClick={onGo}>Go there</button>
    </Shell>
  );
}

/** A herd, the animals that hunt it, the village's own animals, or a flock overhead. */
export function CreatureCard({ kind, place, onClose }: { kind: CreatureKind; place: Settlement; onClose: () => void }) {
  const land = landOf(place.land);
  if (!land) return null;
  const story = creatureStory(kind, land, place.biome, place.name);
  return (
    <Shell title={story.title} sub={<>near {place.name}</>} onClose={onClose}>
      {story.lines.map((line) => (
        <p key={line} className="mt-2 text-xs text-ink-2">{line}</p>
      ))}
    </Shell>
  );
}

function People({ list, onPerson }: { list: Someone[]; onPerson: (id: number) => void }) {
  return (
    <ul className="mt-1 flex flex-wrap gap-x-2 gap-y-1 text-xs">
      {list.slice(0, 14).map((p) => (
        <li key={p.id}>
          <button className="text-ink hover:text-life hover:underline" onClick={() => onPerson(p.id)}>{p.name}</button>
        </li>
      ))}
      {list.length > 14 && <li className="text-ink-3">and {list.length - 14} more</li>}
    </ul>
  );
}

/** A building: whose home it is, or who is inside right now. */
export function BuildingCard({ kind, name, place, residents, inside, onPerson, onClose }: {
  kind: string; name: string | null; place: Settlement | undefined; residents: Someone[]; inside: Someone[];
  onPerson: (id: number) => void; onClose: () => void;
}) {
  return (
    <Shell title={kind === "home" ? name ?? "A home" : PLACE_NAMES[kind] ?? "A building"} sub={place ? <>in {place.name}</> : undefined} onClose={onClose}>
      {kind === "home" && (
        <>
          <h3 className="mt-3 text-xs uppercase tracking-widest text-ink-3">Lives here</h3>
          {residents.length ? <People list={residents} onPerson={onPerson} /> : <p className="mt-1 text-xs text-ink-3">Nobody: the house stands empty.</p>}
        </>
      )}
      <h3 className="mt-3 text-xs uppercase tracking-widest text-ink-3">Here right now</h3>
      {inside.length ? <People list={inside} onPerson={onPerson} /> : <p className="mt-1 text-xs text-ink-3">Nobody at the moment.</p>}
    </Shell>
  );
}
