import Link from "next/link";
import { PLACE_NAMES } from "@/shared/progress";
import type { FeedEvent } from "@/shared/types";
import { formatEonDate } from "@/shared/time";

const COLORS: Record<string, string> = {
  birth: "text-birth",
  death: "text-death",
  union: "text-love",
  wedding: "text-love",
  pregnant: "text-love",
  diagnosis: "text-sick",
  outbreak: "text-sick",
  genesis: "text-god",
  founders_arrive: "text-god",
  founder_created: "text-god",
  miracle_heal: "text-god",
  founded: "text-life",
  became_town: "text-life",
  became_city: "text-life",
  weather: "text-sick",
  harvest: "text-god",
  discovery: "text-god",
  built: "text-life",
  prayer_answered: "text-god",
  friends: "text-love",
  quarrel: "text-sick",
  fight: "text-death",
  theft: "text-sick",
  judged: "text-god",
  reconciled: "text-love",
};

const ICONS: Record<string, string> = {
  birth: "✦", death: "✝", union: "♥", wedding: "◈", pregnant: "◌", diagnosis: "⚕", outbreak: "☣",
  genesis: "☀", founders_arrive: "☀", founder_created: "☀", miracle_heal: "✧", founded: "⌂", became_town: "⌂", became_city: "⌂",
  weather: "☁", harvest: "❧", discovery: "✺", built: "⌂", moved: "→", prayer: "☾", prayer_answered: "✧", spoke: "❝", voice: "✎",
  friends: "♡", quarrel: "✕", fight: "⚔", theft: "⊘", judged: "⚖", reconciled: "✽",
};

function A({ id, name }: { id: number | null; name: string | null }) {
  if (!id || !name) return <span className="text-ink-2">someone</span>;
  return (
    <Link href={`/agents/${id}`} prefetch={false} className="font-medium text-ink hover:text-life hover:underline">
      {name}
    </Link>
  );
}

const PRAYERS: Record<string, string> = { health: "for healing", food: "for food", child: "for a child", safety: "for safety", peace: "for peace" };

/** "them" when the event does not say who; the feed never guesses a person's sex. */
function pronounObj(e: FeedEvent) {
  const sex = (e.data as { sex?: string }).sex;
  return sex === "F" ? "her" : sex === "M" ? "him" : "them";
}

function weatherStory(d: Record<string, string | number | boolean | undefined>, place: React.ReactNode) {
  const at = place ? <> {place}</> : null;
  switch (d.kind) {
    case "blizzard":
      return <>A blizzard buried{at ?? " the land"} in snow</>;
    case "flood":
      return <>Days of heavy rain flooded{at ?? " the lowlands"} as the river rose</>;
    case "heatwave":
      return <>A heatwave scorched{at ?? " the land"}: {String(d.high)}°C</>;
    case "cold_snap":
      return <>Bitter cold gripped{at ?? " the land"}: {String(d.low)}°C</>;
    case "drought":
      return <>Drought took hold{place ? <> in {place}</> : null} as the soil dried out</>;
    case "surge":
      return <>A storm and a spring tide drove the sea into{at ?? " the coast"}</>;
    case "sandstorm":
      return <>A sandstorm swept through{at ?? " the desert"}</>;
    case "storm":
      return <>A thunderstorm broke over{at ?? " the land"}</>;
    case "first_snow":
      return <>The first snow of the year fell{place ? <> on {place}</> : null}</>;
    default:
      return <>The weather turned{place ? <> in {place}</> : null}</>;
  }
}

export function describe(e: FeedEvent) {
  const d = e.data as Record<string, string | number | boolean | undefined>;
  const a = <A id={e.agent} name={e.agentName} />;
  const o = <A id={e.other} name={e.otherName} />;
  const place = e.settlementName ? <span className="text-ink-2">{e.settlementName}</span> : null;
  switch (e.kind) {
    case "birth":
      return <>{a} was born to {o}{d.twins ? " — a twin" : ""}</>;
    case "death":
      return <>{a} died of <span className="text-death">{String(d.cause)}</span> at age {Math.floor(Number(d.age))}</>;
    case "union":
      return <>{a} and {o} became partners</>;
    case "wedding":
      return <>{a} married {o}</>;
    case "pregnant":
      return <>{a} is expecting a child with {o}</>;
    case "diagnosis":
      return <>{a} was diagnosed with <span className="text-sick">{String(d.disease)}</span></>;
    case "outbreak":
      return <><span className="text-sick">{String(d.disease)}</span> broke out{place ? <> in {place}</> : null}</>;
    case "genesis":
      return <>In the beginning, The Creator made {a} and {o} in {String(d.village)}</>;
    case "founders_arrive":
      return <>The Creator sent {a} and {o} into the world{place ? <> at {place}</> : null}</>;
    case "founder_created":
      return <>The Creator made {a}</>;
    case "miracle_heal":
      return <>The Creator healed {a}</>;
    case "weather":
      return <>{weatherStory(d, place)}</>;
    case "discovery":
      return <>{a} {String(d.story)}</>;
    case "voice":
      return d.type === "news"
        ? <><span className="text-god">The news:</span> <span className="text-ink">{String(d.text)}</span></>
        : <>{a} wrote: <span className="italic text-ink">{String(d.text)}</span></>;
    case "prayer":
      return <>{a} prayed {PRAYERS[String(d.need)] ?? "to The Creator"}</>;
    case "prayer_answered":
      return <>The Creator answered {a}&apos;s prayer {PRAYERS[String(d.need)] ?? ""}</>;
    case "spoke":
      return <>{a} said: <span className="text-ink">&ldquo;{String(d.said)}&rdquo;</span></>;
    case "built":
      return <>{place ?? "A village"} built a new {(PLACE_NAMES[String(d.building)] ?? "building").toLowerCase()}</>;
    case "moved":
      return <>{a} moved to {place ?? "a new home"}</>;
    case "harvest":
      return <>{d.good ? <>A bumper harvest filled the stores{place ? <> of {place}</> : null}</> : <>The harvest failed{place ? <> in {place}</> : null}: food will be dear this year</>}</>;
    case "founded":
      return <>The village of <span className="text-life">{String(d.name)}</span> was founded</>;
    case "became_town":
      return <>{String(d.name)} grew into a town</>;
    case "became_city":
      return <>{String(d.name)} became a city</>;
    case "friends":
      return <>{a} and {o} became friends</>;
    case "quarrel":
      return <>{a} and {o} fell out over {String(d.about ?? "harsh words")}</>;
    case "fight":
      return <>{a} and {o} came to blows over {String(d.about ?? "an old grudge")}</>;
    case "theft":
      return <>Someone stole {String(d.stolen)} credits from {a}</>;
    case "judged":
      return <>{a} was caught stealing from {o}, and the {d.by === "law" ? "court" : "elders"} made {pronounObj(e)} give it back</>;
    case "reconciled":
      return <>{a} and {o} made peace</>;
    default:
      return <>{a} — {e.kind.replace(/_/g, " ")}</>;
  }
}

export function EventLine({ e, showDate = true }: { e: FeedEvent; showDate?: boolean }) {
  return (
    <li className="flex gap-3 py-2 text-sm leading-snug">
      <span className={`w-4 shrink-0 text-center ${COLORS[e.kind] ?? "text-ink-3"}`} aria-hidden>
        {ICONS[e.kind] ?? "·"}
      </span>
      <span className="flex-1 text-ink-2">
        {describe(e)}
        {e.data.first ? <span className="text-god"> · a first for EON</span> : null}
        {e.data.voice ? <span className="mt-1 block italic text-ink">{String(e.data.voice)}</span> : null}
      </span>
      {showDate && <span className="shrink-0 font-mono text-[11px] text-ink-3">{formatEonDate(e.tick)}</span>}
    </li>
  );
}
