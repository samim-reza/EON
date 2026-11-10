import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { EventLine } from "@/components/EventLine";
import { getMe } from "@/lib/auth";
import { createUserClient } from "@/lib/supabase/server";
import { BY, outcome, timeLeft } from "@/shared/choices";
import { PROVIDERS } from "@/shared/providers";
import { stageOf } from "@/shared/soul-mind";
import { formatEonDate } from "@/shared/time";
import { signOut } from "../login/actions";
import { ChoiceCard } from "./ChoiceCard";
import { ConnectAI } from "./ConnectAI";
import { PrayForm } from "./PrayForm";
import { RequestLife } from "./RequestLife";
import type { Life } from "./types";

export const metadata: Metadata = { title: "My life", robots: { index: false } };

const first = (name?: string | null) => (name ?? "Your person").split(" ")[0];
const PRAYED: Record<string, string> = {
  health: "for health", food: "for food", child: "for a child", safety: "for safety", peace: "for peace", thanks: "in thanks",
};

function Waiting({ life }: { life: Life }) {
  if (life.status === "waiting") {
    return (
      <p className="mt-2 text-ink-2">
        Your soul is waiting for a family. The moment a child under three has no soul, you become them.{" "}
        {life.expecting > 0
          ? `Otherwise, ${life.expecting} ${life.expecting === 1 ? "family is" : "families are"} expecting a child right now, and a waiting soul is given one about six hours after asking.`
          : "Otherwise you will be given the next baby on the way."}{" "}
        You will get an email the moment your life begins.
      </p>
    );
  }
  return (
    <p className="mt-2 text-ink-2">
      You will be born to <span className="text-ink">{life.mother}</span> and <span className="text-ink">{life.father}</span>
      {life.place ? ` in ${life.place}` : ""}
      {life.dueTick != null ? `, in about ${timeLeft(life.dueTick - life.tick)}` : ""}. You will get an email the moment you are born.
    </p>
  );
}

function Mind({ life }: { life: Life }) {
  const name = first(life.name);
  if (life.mind === "world" && life.trialUntil != null) {
    return (
      <p className="mt-3 text-sm text-ink-2">
        <span className="text-god">EON is {name}&apos;s mind</span> for {timeLeft(life.trialUntil - life.tick)} more. After that,{" "}
        {name} needs your own AI to keep thinking and choosing.
      </p>
    );
  }
  if (life.mind === "own" && life.key) {
    return (
      <p className="mt-3 text-sm text-ink-2">
        {name} thinks with your <span className="text-ink">{PROVIDERS[life.key.provider].label}</span> key (····{life.key.last4}).
        {life.key.status !== "ok" ? " It is not answering right now, so habit decides until it does." : ""}
      </p>
    );
  }
  return (
    <p className="mt-3 text-sm text-sick">
      Without a mind, {name} lives by habit, and you can only watch. Connect your AI below to wake their mind again.
    </p>
  );
}

function Living({ life }: { life: Life }) {
  const p = life.person!;
  const age = Math.floor((life.tick - p.birthTick) / 1440);
  const name = first(life.name);
  const open = (life.choices ?? []).filter((c) => c.status === "open" || c.status === "asked");
  const decided = (life.choices ?? []).filter((c) => c.status === "settled" && !c.outcome?.waiting).slice(0, 6);
  const canChoose = life.mind !== "none";
  const kin = [
    p.mother && <Link key="m" href={`/agents/${p.mother.id}`} prefetch={false} className="hover:text-ink">mother {p.mother.name}{p.mother.alive === false ? " (died)" : ""}</Link>,
    p.father && <Link key="f" href={`/agents/${p.father.id}`} prefetch={false} className="hover:text-ink">father {p.father.name}{p.father.alive === false ? " (died)" : ""}</Link>,
    p.partner && <Link key="p" href={`/agents/${p.partner.id}`} prefetch={false} className="hover:text-ink">partner {p.partner.name}</Link>,
    ...p.children.map((c) => <Link key={c.id} href={`/agents/${c.id}`} prefetch={false} className="hover:text-ink">child {c.name}{c.alive === false ? " (died)" : ""}</Link>),
  ].filter(Boolean);
  return (
    <>
      <section className="panel mt-6 p-5">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-xl font-semibold">
            You are{" "}
            <Link href={`/agents/${p.id}`} prefetch={false} className="text-life hover:underline">{life.name}</Link>
          </h2>
          <span className="text-sm text-ink-3">
            {age === 0 ? "newborn" : `${age} ${age === 1 ? "year" : "years"} old`}, {stageOf(age).replace(/^an? /, "")}
            {p.place ? ` in ${p.place}` : ""}
          </span>
        </div>
        <p className="mt-1 text-sm text-ink-2">
          {["baby", "child"].includes(p.work) ? "Not working yet" : `Works as a ${p.work}`}
          {" · "}{p.health < 30 ? "very ill" : p.health < 60 ? "unwell" : "in good health"}
          {" · "}{p.happiness < 35 ? "unhappy" : p.happiness < 65 ? "getting by" : "content"}
          {p.calling ? ` · learned to be a ${p.calling}` : ""}
        </p>
        {kin.length > 0 && <p className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-sm text-ink-2">{kin}</p>}
        <Mind life={life} />
      </section>

      <section className="mt-8">
        <h2 className="text-lg font-semibold">Choices</h2>
        {open.length === 0 ? (
          <p className="mt-1 text-sm text-ink-3">
            Nothing to decide right now. While {name} grows up there is one choice a year (one a real day); later, work, love,
            children, quarrels and temptation.
          </p>
        ) : (
          <div className="mt-3 space-y-3">
            {open.map((c) => <ChoiceCard key={c.id} c={c} now={life.tick} canChoose={canChoose} />)}
          </div>
        )}
      </section>

      {decided.length > 0 && (
        <section className="mt-8">
          <h2 className="text-lg font-semibold">What you decided</h2>
          <ul className="mt-2 space-y-3 text-sm">
            {decided.map((c) => (
              <li key={c.id}>
                <span className="text-ink">{outcome(c)}</span>{" "}
                {c.by && <span className="text-xs text-ink-3">({BY[c.by]})</span>}
                {c.thought && <span className="mt-0.5 block italic text-ink-2">&ldquo;{c.thought}&rdquo;</span>}
              </li>
            ))}
          </ul>
        </section>
      )}

      {(life.thoughts ?? []).length > 0 && (
        <section className="mt-8">
          <h2 className="text-lg font-semibold">{name}&apos;s thoughts</h2>
          <p className="text-xs text-ink-3">Only you and the Creator can read these.</p>
          <ul className="mt-2 space-y-2 text-sm">
            {life.thoughts!.map((t, i) => (
              <li key={i} className="flex gap-3">
                <span className="w-24 shrink-0 font-mono text-[11px] text-ink-3">{formatEonDate(t.tick)}</span>
                <span className="italic text-ink-2">{t.body}</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="mt-8">
        <h2 className="text-lg font-semibold">Prayer</h2>
        {life.mind !== "none" && age >= 4 && !p.openPrayer ? (
          <div className="mt-2"><PrayForm suggested={p.need} /></div>
        ) : (
          <p className="mt-1 text-sm text-ink-3">
            {age < 4 ? `${name} is too young to pray yet.` : p.openPrayer ? "Your last prayer has not been answered yet." : "Connect your AI to pray again."}
          </p>
        )}
        {(life.prayers ?? []).length > 0 && (
          <ul className="mt-3 space-y-2 text-sm">
            {life.prayers!.map((pr, i) => (
              <li key={i}>
                <span className="text-ink-2">You prayed {PRAYED[pr.need] ?? ""}</span>
                <span className={pr.status === "granted" ? "text-god" : "text-ink-3"}>
                  {pr.status === "open" ? " · waiting" : pr.status === "granted" ? " · answered" : " · not this time"}
                </span>
                {pr.words && <span className="mt-0.5 block italic text-ink-2">&ldquo;{pr.words}&rdquo;</span>}
              </li>
            ))}
          </ul>
        )}
      </section>

      {(life.happened ?? []).length > 0 && (
        <section className="mt-8">
          <h2 className="text-lg font-semibold">What happened</h2>
          <ul className="mt-1 divide-y divide-line/60">
            {life.happened!.map((e) => <EventLine key={`${e.tick}-${e.id}`} e={e} />)}
          </ul>
        </section>
      )}
    </>
  );
}

export default async function MePage() {
  const me = await getMe();
  if (!me) redirect("/login");
  if (me.isGod) redirect("/god");
  const supabase = await createUserClient();
  const { data } = await supabase.rpc("my_life");
  const life = data as Life | null;
  const status = life?.status;
  return (
    <div className="mx-auto max-w-3xl px-4 py-12">
      <h1 className="text-2xl font-semibold">Welcome, {me.username}</h1>
      {!life ? (
        <p className="mt-2 text-ink-2">Your life could not be loaded right now. Try again in a moment.</p>
      ) : status === "living" && life.person ? (
        <Living life={life} />
      ) : status === "waiting" || status === "assigned" ? (
        <Waiting life={life} />
      ) : (
        <>
          <p className="mt-2 text-ink-2">
            {status === "ended"
              ? `${life.name ?? "Your last life"} has ended. You can ask for another.`
              : "Ask for a life. If a child under three in EON has no soul yet, you become them at once; otherwise you are born as the next baby."}
          </p>
          <p className="mt-2 text-sm text-ink-3">
            {life.freeDays
              ? "For the first three days of your first life, counted from when it begins, EON gives your person a mind of its own. After that, they need your own AI."
              : life.key
                ? "Your person will think with your own AI."
                : "Your free days are used. Connect your own AI below, then ask."}
          </p>
          <RequestLife />
        </>
      )}
      {life && <ConnectAI current={life.key} />}
      <form action={signOut} className="mt-8">
        <button className="btn btn-ghost">Sign out</button>
      </form>
    </div>
  );
}
