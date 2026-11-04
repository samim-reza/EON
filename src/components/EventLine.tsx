import Link from "next/link";
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
};

const ICONS: Record<string, string> = {
  birth: "✦", death: "✝", union: "♥", wedding: "◈", pregnant: "◌", diagnosis: "⚕", outbreak: "☣",
  genesis: "☀", founders_arrive: "☀", founder_created: "☀", miracle_heal: "✧", founded: "⌂", became_town: "⌂", became_city: "⌂",
};

function A({ id, name }: { id: number | null; name: string | null }) {
  if (!id || !name) return <span className="text-ink-2">someone</span>;
  return (
    <Link href={`/agents/${id}`} className="font-medium text-ink hover:text-life hover:underline">
      {name}
    </Link>
  );
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
    case "founded":
      return <>The village of <span className="text-life">{String(d.name)}</span> was founded</>;
    case "became_town":
      return <>{String(d.name)} grew into a town</>;
    case "became_city":
      return <>{String(d.name)} became a city</>;
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
      <span className="flex-1 text-ink-2">{describe(e)}</span>
      {showDate && <span className="shrink-0 font-mono text-[11px] text-ink-3">{formatEonDate(e.tick)}</span>}
    </li>
  );
}
