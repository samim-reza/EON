"use client";

import Link from "next/link";
import { useActionState, useTransition } from "react";
import { formatEonDate } from "@/shared/time";
import { BIOME_NAMES, type Biome } from "@/shared/climate";
import { answerPrayer, assignSoul, changePassword, createFounder, findPeople, foundSettlement, genesis, heal, moveAgent, nature, overrule, playerAction, possess, release, sendSign, setPaused, setWorld, smite, type ActionResult } from "./actions";

export type GodState = {
  world: {
    tick: number; paused: boolean; genesis_at: string | null; seed: string; last_tick_ms: number; genesis_end_tick: number;
    /** After this tick nobody is made: everyone is born. Absent until the living-world migration has run. */
    creation_end_tick?: number;
    capacity_k: number; fertility_mult: number; mortality_mult: number; disease_mult: number; crime_mult: number;
    temp_shift: number; rain_mult: number; llm_cap?: number;
    female_ratio: number; autopilot: boolean;
    /** How loud the Whisperer is: 0 silences it. Absent until the Whisperer migration has run. */
    whisper_mult?: number;
  };
  population: number;
  dead: number;
  pregnant: number;
  sick: number;
  settlements: { id: number; name: string; kind: string; pop: number }[];
  /** The best free land first. */
  sites?: { id: number; x: number; y: number; biome: Biome | null; river: number; coast: boolean }[];
  prayers?: { id: number; need: string; tick: number; words?: string | null; agent: string; agentId: number; place: string | null }[];
  /** Players' people, their minds, and the choices still open to them. */
  lives?: {
    id: number; username: string; agentId: number; name: string; age: number; mind: "world" | "own" | "none";
    trialUntil: number | null; key: string | null; thought: string | null;
    pending: { id: number; kind: string; options: { id: string; label: string }[]; status: string; choice: string | null; by: string | null; about: string | null }[];
  }[];
  souls?: { id: number; tick: number; username: string }[];
  families?: { id: number; due: number; mother: string; place: string | null }[];
  /** Children under three who have no soul yet: a waiting soul can become one of them at once. */
  children?: { id: number; name: string; months: number; place: string | null }[];
  possessed?: { id: number; name: string; until: number }[];
  /** Every player account, newest first. */
  players?: {
    userId: string; username: string; joined: string; lastSeen: string | null; confirmed: boolean; lives: number;
    soul: number | null; status: "waiting" | "assigned" | "living" | "ended" | null; trialUntil: number | null; agent: number | null;
    mind: "world" | "own" | "none" | null; person: string | null; age: number | null; place: string | null; key: string | null;
  }[];
  ai?: { spent: number; lines: number; cap: number; waiting: number };
  /** What the Whisperer has been doing in the past EON year, and whose records weigh most. */
  whisperer?: {
    mult: number; whispers: number; yielded: number; refuge: number; repented: number; kindness: number; waiting: number;
    by: Record<string, number>;
    heaviest: { id: number; name: string; good: number; ill: number; mended: number }[];
    lightest: { id: number; name: string; good: number; ill: number; mended: number }[];
  } | null;
  pyramid: { band: number; F: number; M: number }[];
  dbBytes: number;
  audit: { id: number; at: string; actor: string; action: string; target: string | null; tick: number; hash: string }[];
};

const init: ActionResult = { ok: false, error: null };

/** What the Whisperer suggests, in a word. */
const WHISPERS: Record<string, string> = { take: "theft", cheat: "short measure", slander: "lies", strike: "blows", idle: "idleness", forsake: "leaving prayer" };

type Found = { id: number; name: string; sex: "F" | "M"; age: number; work: string; place: string | null; health: number; controller: string; player: string | null };

const day = (iso: string | null) => (iso ? new Date(iso).toISOString().slice(0, 10) : "never");

/** Destructive buttons ask first. Preventing the submit also stops the action. */
function confirmDanger(event: React.FormEvent<HTMLFormElement>) {
  const op = ((event.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null)?.value;
  const ask: Record<string, string> = {
    take: "Take this soul out of its life? The person lives on without them.",
    remove: "Remove this player's account for good? Their person lives on without them.",
    smite: "Take this life? It cannot be undone.",
  };
  if (op && ask[op] && !window.confirm(ask[op])) event.preventDefault();
}

function Result({ s }: { s: ActionResult }) {
  if (s.error) return <p className="text-sm text-death">{s.error}</p>;
  if (s.ok) return <p className="text-sm text-birth">Done.</p>;
  return null;
}

function Genesis() {
  const [state, action, pending] = useActionState(genesis, init);
  return (
    <div className="panel mx-auto max-w-xl p-6">
      <h2 className="text-xl font-semibold text-god">Genesis</h2>
      <p className="mt-2 text-sm text-ink-2">
        Before you there is nothing. Name the first village and the first two souls. A world will be shaped from a
        random seed, and time will begin — one EON year every real day. This happens only once.
      </p>
      <form action={action} className="mt-5 grid gap-3 sm:grid-cols-2">
        <label className="text-sm sm:col-span-2">
          <span className="text-ink-2">First village</span>
          <input name="village" required defaultValue="Eden" className="input mt-1" />
        </label>
        <label className="text-sm">
          <span className="text-ink-2">First woman</span>
          <input name="eve" required defaultValue="Lyra" className="input mt-1" />
        </label>
        <label className="text-sm">
          <span className="text-ink-2">Her family name</span>
          <input name="eveSurname" required defaultValue="Voss" className="input mt-1" />
        </label>
        <label className="text-sm">
          <span className="text-ink-2">First man</span>
          <input name="adam" required defaultValue="Orin" className="input mt-1" />
        </label>
        <label className="text-sm">
          <span className="text-ink-2">His family name</span>
          <input name="adamSurname" required defaultValue="Kell" className="input mt-1" />
        </label>
        <div className="sm:col-span-2">
          <Result s={state} />
          <button className="btn btn-god mt-2 w-full" disabled={pending}>
            {pending ? "Creating the world…" : "Let there be EON"}
          </button>
        </div>
      </form>
    </div>
  );
}

export function PasswordForm() {
  const [state, action, pending] = useActionState(changePassword, init);
  return (
    <form action={action} className="panel space-y-3 p-5">
      <h2 className="font-semibold">Change your password</h2>
      <input name="current" type="password" autoComplete="current-password" placeholder="Current password" className="input" />
      <input name="next" type="password" autoComplete="new-password" placeholder="New password (12+ letters & digits)" className="input" />
      <Result s={state} />
      <button className="btn btn-ghost w-full" disabled={pending}>{pending ? "Saving…" : "Change password"}</button>
    </form>
  );
}

function Slider({ name, label, value, min, max, step, hint }: { name: string; label: string; value: number; min: number; max: number; step: number; hint: string }) {
  return (
    <label className="block text-sm">
      <div className="flex justify-between">
        <span>{label}</span>
        <span className="text-ink-3">{hint}</span>
      </div>
      <input type="number" name={name} defaultValue={value} min={min} max={max} step={step} className="input mt-1" />
    </label>
  );
}

export function GodConsole({ state }: { state: GodState }) {
  const w = state.world;
  const [balance, balanceAction, balancing] = useActionState(setWorld, init);
  const [healed, healAction, healing] = useActionState(heal, init);
  const [smitten, smiteAction, smiting] = useActionState(smite, init);
  const [founder, founderAction, founding] = useActionState(createFounder, init);
  const [settled, settleAction, settling] = useActionState(foundSettlement, init);
  const [land, landAction, landing] = useActionState(nature, init);
  const creationOver = w.creation_end_tick !== undefined && w.tick >= w.creation_end_tick;
  const [moved, moveAction, moving] = useActionState(moveAgent, init);
  const [answered, answerAction, answering] = useActionState(answerPrayer, init);
  const [placed, placeAction, placing] = useActionState(assignSoul, init);
  const [taken, possessAction, taking] = useActionState(possess, init);
  const [freed, releaseAction] = useActionState(release, init);
  const [overruled, overruleAction, overruling] = useActionState(overrule, init);
  const [signed, signAction, signing] = useActionState(sendSign, init);
  const [played, playAction, playing] = useActionState(playerAction, init);
  const [found, findAction, finding] = useActionState(findPeople, init);
  const [pausing, startPause] = useTransition();

  if (!w.genesis_at)
    return (
      <div className="space-y-6">
        <Genesis />
        <div className="mx-auto max-w-xl">
          <PasswordForm />
        </div>
      </div>
    );

  const maxBand = Math.max(1, ...state.pyramid.map((b) => Math.max(b.F, b.M)));
  return (
    <div className="space-y-6">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        {[
          ["Date", formatEonDate(w.tick)],
          ["Alive", state.population],
          ["Departed", state.dead],
          ["Expecting", state.pregnant],
          ["Ill", state.sick],
        ].map(([k, v]) => (
          <div key={k} className="panel px-4 py-3">
            <div className="text-lg font-semibold tabular-nums">{v}</div>
            <div className="text-xs text-ink-3">{k}</div>
          </div>
        ))}
      </div>

      <div className="flex flex-wrap items-center gap-3 text-sm text-ink-2">
        <span className="tag">tick {w.tick}</span>
        <span className="tag">last tick {w.last_tick_ms} ms</span>
        <span className="tag">db {(state.dbBytes / 1024 / 1024).toFixed(1)} MB / 500 MB</span>
        {state.ai && (
          <span className="tag">
            AI today ${Number(state.ai.spent).toFixed(4)} of ${Number(state.ai.cap).toFixed(2)} · {state.ai.lines} lines · {state.ai.waiting} waiting
          </span>
        )}
        <span className={`tag ${w.tick < w.genesis_end_tick ? "text-god" : ""}`}>
          {w.tick < w.genesis_end_tick ? `Genesis era until ${formatEonDate(w.genesis_end_tick)}` : "Genesis era over"}
        </span>
        {w.creation_end_tick !== undefined && (
          <span className={`tag ${creationOver ? "" : "text-god"}`}>
            {creationOver ? "Creation is over: everyone is born" : `People are made until ${formatEonDate(w.creation_end_tick)}`}
          </span>
        )}
        <button
          className={`btn ${w.paused ? "btn-life" : "btn-ghost"} ml-auto`}
          disabled={pausing}
          onClick={() => startPause(async () => void (await setPaused(!w.paused)))}
        >
          {w.paused ? "Resume time" : "Pause time"}
        </button>
      </div>

      <nav className="sticky top-14 z-30 -mx-1 flex flex-wrap gap-1 rounded-lg bg-bg/85 px-1 py-1 text-sm backdrop-blur">
        {[["players", "Players"], ["souls", "Prayers & souls"], ["world", "The world"], ["whisperer", "The Whisperer"], ["powers", "Powers"], ["audit", "Audit"]].map(([id, label]) => (
          <a key={id} href={`#${id}`} className="tag hover:text-ink">{label}</a>
        ))}
      </nav>

      <div id="players" className="scroll-mt-20 grid gap-6 lg:grid-cols-2">
        <div className="panel space-y-3 p-5">
          <h2 className="font-semibold">Players</h2>
          <p className="text-xs text-ink-3">Every account, newest first. Everything you do here is recorded in the audit log.</p>
          <Result s={played} />
          <Result s={overruled} />
          {(state.players ?? []).length === 0 && <p className="text-sm text-ink-3">No players yet.</p>}
          <ul className="max-h-[32rem] divide-y divide-line/60 overflow-auto text-sm">
            {(state.players ?? []).map((p) => (
              <li key={p.userId} className="py-3">
                <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                  <span className="font-medium text-ink">{p.username}</span>
                  <span className="text-xs text-ink-3">
                    joined {day(p.joined)} · last seen {day(p.lastSeen)} · {p.lives} {p.lives === 1 ? "life" : "lives"}
                    {p.confirmed ? "" : " · email not confirmed"}
                  </span>
                </div>
                <p className="mt-1 text-ink-2">
                  {p.status === "living" && p.agent ? (
                    <>
                      Lives as <Link href={`/agents/${p.agent}`} prefetch={false} className="text-ink hover:underline">{p.person}</Link> (#{p.agent}), {p.age}{p.place ? `, ${p.place}` : ""}
                      {" · "}<Link href={`/world?agent=${p.agent}`} prefetch={false} className="text-god hover:underline">show on map</Link>
                    </>
                  ) : p.status === "waiting" ? "Waiting for a life"
                    : p.status === "assigned" ? "Waiting to be born"
                      : p.status === "ended" ? `Last life ended${p.person ? `: ${p.person}` : ""}` : "Has not asked for a life"}
                </p>
                {p.status === "living" && (
                  <p className="text-xs text-ink-3">
                    {p.mind === "world" ? `EON's mind until ${p.trialUntil != null ? formatEonDate(p.trialUntil) : "soon"}`
                      : p.mind === "own" ? `Own AI: ${p.key ?? ""}` : "No mind: watching only"}
                    {p.key && p.mind !== "own" ? ` · key ${p.key}` : ""}
                  </p>
                )}
                {(() => {
                  const life = (state.lives ?? []).find((l) => l.id === p.soul);
                  if (!life) return null;
                  return (
                    <>
                      {life.thought && <p className="mt-1 italic text-ink-2">&ldquo;{life.thought}&rdquo;</p>}
                      {life.pending.map((c) => (
                        <form key={c.id} action={overruleAction} className="mt-2 flex flex-wrap items-center gap-1">
                          <input type="hidden" name="choice" value={c.id} />
                          <span className="text-xs text-ink-2">
                            Deciding: {c.kind}{c.about ? ` (${c.about})` : ""}{c.choice ? ` · ${c.by} chose ${c.choice}` : ""}. Overrule:
                          </span>
                          {c.options.map((o) => (
                            <button key={o.id} name="option" value={o.id} className="btn btn-ghost text-xs" disabled={overruling}>{o.label}</button>
                          ))}
                        </form>
                      ))}
                    </>
                  );
                })()}
                <form action={playAction} onSubmit={confirmDanger} className="mt-2 flex flex-wrap gap-1">
                  <input type="hidden" name="user" value={p.userId} />
                  {p.soul != null && <input type="hidden" name="soul" value={p.soul} />}
                  {p.status === "living" && <button name="op" value="extend" className="btn btn-ghost text-xs" disabled={playing}>+3 free days</button>}
                  {p.status && p.status !== "ended" && <button name="op" value="take" className="btn btn-ghost text-xs" disabled={playing}>Take back the soul</button>}
                  {p.key && <button name="op" value="revoke" className="btn btn-ghost text-xs" disabled={playing}>Revoke key</button>}
                  <button name="op" value="remove" className="btn btn-ghost text-xs text-death" disabled={playing}>Remove player</button>
                </form>
              </li>
            ))}
          </ul>
        </div>

        <div className="panel space-y-3 p-5">
          <h2 className="font-semibold">Find anyone</h2>
          <p className="text-xs text-ink-3">By name or id. Players&apos; people come first. Leave it empty to list the oldest.</p>
          <form action={findAction} className="flex gap-2">
            <input name="q" placeholder="Name or id" className="input" maxLength={60} />
            <button className="btn btn-god" disabled={finding}>Find</button>
          </form>
          {found.error && <p className="text-sm text-death">{found.error}</p>}
          <Result s={healed} />
          <Result s={signed} />
          <Result s={smitten} />
          <ul className="max-h-[28rem] divide-y divide-line/60 overflow-auto text-sm">
            {((found.data as Found[] | undefined) ?? []).map((a) => (
              <li key={a.id} className="py-2">
                <div className="flex flex-wrap items-baseline gap-x-2">
                  <Link href={`/agents/${a.id}`} prefetch={false} className="text-ink hover:underline">#{a.id} {a.name}</Link>
                  <Link href={`/world?agent=${a.id}`} prefetch={false} className="text-xs text-god hover:underline">map</Link>
                  <span className="text-xs text-ink-3">
                    {a.sex === "F" ? "♀" : "♂"} {a.age} · {a.work} · {a.place ?? "?"} · health {a.health}
                    {a.player ? ` · soul of ${a.player}` : ""}{a.controller === "god" ? " · possessed" : ""}
                  </span>
                </div>
                <div className="mt-1 flex flex-wrap items-center gap-1">
                  <form action={healAction}>
                    <input type="hidden" name="agent" value={a.id} />
                    <button className="btn btn-ghost text-xs" disabled={healing}>Heal</button>
                  </form>
                  <form action={signAction} className="flex gap-1">
                    <input type="hidden" name="agent" value={a.id} />
                    <input name="text" placeholder="Send a dream" className="input h-7 w-40 text-xs" maxLength={200} />
                    <button className="btn btn-ghost text-xs" disabled={signing}>Send</button>
                  </form>
                  <form action={smiteAction} onSubmit={confirmDanger}>
                    <input type="hidden" name="agent" value={a.id} />
                    <input type="hidden" name="cause" value="Divine Will" />
                    <button value="smite" className="btn btn-ghost text-xs text-death" disabled={smiting}>Take this life</button>
                  </form>
                </div>
              </li>
            ))}
          </ul>
        </div>
      </div>

      <div id="souls" className="scroll-mt-20 grid gap-6 lg:grid-cols-3">
        <div className="panel space-y-3 p-5">
          <h2 className="font-semibold">Prayers</h2>
          <p className="text-xs text-ink-3">Anything left unanswered for 6 hours is answered by the world itself.</p>
          <Result s={answered} />
          {(state.prayers ?? []).length === 0 && <p className="text-sm text-ink-3">No prayers are waiting.</p>}
          <ul className="max-h-80 divide-y divide-line/60 overflow-auto text-sm">
            {(state.prayers ?? []).map((p) => (
              <li key={p.id} className="flex items-center justify-between gap-2 py-2">
                <span className="text-ink-2">
                  <span className="text-ink">{p.agent}</span> asks for {p.need}
                  {p.words ? <span className="block italic">&ldquo;{p.words}&rdquo;</span> : null}
                </span>
                <form action={answerAction} className="flex shrink-0 gap-1">
                  <input type="hidden" name="prayer" value={p.id} />
                  <button name="answer" value="grant" className="btn btn-god" disabled={answering}>Grant</button>
                  <button name="answer" value="deny" className="btn btn-ghost" disabled={answering}>Deny</button>
                </form>
              </li>
            ))}
          </ul>
        </div>
        <form action={placeAction} className="panel space-y-3 p-5">
          <h2 className="font-semibold">Souls waiting for a life</h2>
          <p className="text-xs text-ink-3">A soul becomes a child under three with no soul at once; if there is none, after 6 hours it joins the baby due soonest.</p>
          <select name="soul" className="input">
            {(state.souls ?? []).map((s) => (
              <option key={s.id} value={s.id}>{s.username}</option>
            ))}
          </select>
          <select name="family" className="input">
            {(state.children ?? []).map((c) => (
              <option key={`c${c.id}`} value={`c${c.id}`}>
                {c.name}, {c.months < 12 ? `${c.months} months` : `${Math.floor(c.months / 12)} years`}{c.place ? `, ${c.place}` : ""} (now)
              </option>
            ))}
            {(state.families ?? []).map((f) => (
              <option key={`p${f.id}`} value={`p${f.id}`}>{f.mother}&apos;s baby, {formatEonDate(f.due)}{f.place ? `, ${f.place}` : ""}</option>
            ))}
          </select>
          <Result s={placed} />
          <button className="btn btn-god w-full" disabled={placing || !state.souls?.length || !(state.families?.length || state.children?.length)}>Give this life</button>
        </form>
        <div className="space-y-3">
          <form action={possessAction} className="panel space-y-3 p-5">
            <h2 className="font-semibold">Possess someone</h2>
            <p className="text-xs text-ink-3">Act through a person for one EON year, then they return to themselves. Players can&apos;t be possessed.</p>
            <input name="agent" type="number" min={1} placeholder="Agent id" className="input" />
            <select name="job" className="input" defaultValue="">
              <option value="">Keep their work</option>
              <option value="farmer">Make them a farmer</option>
              <option value="builder">Make them a builder</option>
              <option value="healer">Make them a healer</option>
            </select>
            <input name="say" placeholder="Say something through them" className="input" maxLength={200} />
            <Result s={taken} />
            <button className="btn btn-god w-full" disabled={taking}>Possess</button>
          </form>
          {(state.possessed ?? []).length > 0 && (
            <div className="panel p-4 text-sm">
              <Result s={freed} />
              <ul className="space-y-1">
                {state.possessed!.map((a) => (
                  <li key={a.id} className="flex items-center justify-between gap-2">
                    <span>{a.name}</span>
                    <form action={releaseAction}>
                      <input type="hidden" name="agent" value={a.id} />
                      <button className="btn btn-ghost">Release</button>
                    </form>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      </div>

      <div id="world" className="scroll-mt-20 grid gap-6 lg:grid-cols-2">
        <div className="panel p-5">
          <h2 className="font-semibold">Population pyramid</h2>
          <div className="mt-3 space-y-1">
            {[...state.pyramid].reverse().map((b) => (
              <div key={b.band} className="grid grid-cols-[1fr_3rem_1fr] items-center gap-2 text-xs">
                <div className="flex justify-end">
                  <div className="h-3 rounded-l bg-love/70" style={{ width: `${(b.F / maxBand) * 100}%` }} />
                </div>
                <div className="text-center text-ink-3">{b.band === 100 ? "100+" : `${b.band}s`}</div>
                <div className="h-3 rounded-r bg-life/70" style={{ width: `${(b.M / maxBand) * 100}%` }} />
              </div>
            ))}
          </div>
          <h3 className="mt-5 text-sm font-semibold">Settlements</h3>
          <ul className="mt-2 grid grid-cols-2 gap-1 text-sm text-ink-2">
            {state.settlements.map((s) => (
              <li key={s.id}>
                #{s.id} {s.name} <span className="text-ink-3">({s.kind}, {s.pop})</span>
              </li>
            ))}
          </ul>
        </div>

        <form action={balanceAction} className="panel space-y-3 p-5">
          <h2 className="font-semibold">Balance the world</h2>
          <Slider name="fertility_mult" label="Fertility" value={w.fertility_mult} min={0} max={5} step={0.05} hint="1 = natural" />
          <Slider name="mortality_mult" label="Mortality" value={w.mortality_mult} min={0.2} max={5} step={0.05} hint="redraws every fate" />
          <Slider name="disease_mult" label="Disease" value={w.disease_mult} min={0} max={5} step={0.05} hint="outbreaks & spread" />
          <Slider name="crime_mult" label="Quarrels & crime" value={w.crime_mult} min={0} max={5} step={0.05} hint="1 = natural, 0 = perfect peace" />
          <Slider name="whisper_mult" label="The Whisperer's voice" value={w.whisper_mult ?? 1} min={0} max={3} step={0.05} hint="1 = as it was allowed, 0 = silenced" />
          <Slider name="temp_shift" label="World temperature" value={w.temp_shift} min={-20} max={20} step={0.5} hint="°C added everywhere: 0 = natural" />
          <Slider name="rain_mult" label="Rainfall" value={w.rain_mult} min={0} max={4} step={0.05} hint="1 = natural, 0 = endless drought" />
          <Slider name="llm_cap" label="AI budget per day, $" value={w.llm_cap ?? 0.5} min={0} max={5} step={0.05} hint="0 turns the AI off" />
          <Slider name="female_ratio" label="Share of girls at birth" value={w.female_ratio} min={0.3} max={0.7} step={0.01} hint="0.5 = even" />
          <Slider name="capacity_k" label="Land capacity (K)" value={w.capacity_k} min={50} max={200000} step={50} hint="population settles ≈ 1.7 × K" />
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" name="autopilot" defaultChecked={w.autopilot} /> Autopilot (sends founders during the years of creation, acts when you are away)
          </label>
          <Result s={balance} />
          <button className="btn btn-god w-full" disabled={balancing}>
            {balancing ? "Rebalancing…" : "Apply"}
          </button>
        </form>
      </div>

      <div id="whisperer" className="panel scroll-mt-20 p-5">
        <h2 className="font-semibold">The Whisperer</h2>
        <p className="text-xs text-ink-3">
          The outcast you allowed until the end of the world. It can only whisper: each person gives in, turns away, or seeks
          refuge with you. Its voice is set under The world. People&apos;s records are yours alone to see while they live.
        </p>
        {!state.whisperer ? (
          <p className="mt-3 text-sm text-ink-3">Nothing to show yet.</p>
        ) : (
          <>
            <dl className="mt-3 grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-3">
              {([
                ["Whispers this past year", state.whisperer.whispers],
                ["Gave in", state.whisperer.yielded],
                ["Turned away", state.whisperer.whispers - state.whisperer.yielded - state.whisperer.refuge],
                ["Sought refuge with you", state.whisperer.refuge],
                ["Asked forgiveness", state.whisperer.repented],
                ["Kindnesses done", state.whisperer.kindness],
                ["Players still deciding", state.whisperer.waiting],
              ] as [string, number][]).map(([label, n]) => (
                <div key={label} className="flex justify-between gap-3">
                  <dt className="text-ink-2">{label}</dt>
                  <dd className="tabular-nums text-ink">{n}</dd>
                </div>
              ))}
            </dl>
            {Object.keys(state.whisperer.by).length > 0 && (
              <p className="mt-2 text-xs text-ink-3">
                What people gave in to:{" "}
                {Object.entries(state.whisperer.by).sort((a, b) => b[1] - a[1]).map(([what, n]) => `${WHISPERS[what] ?? what} ${n}`).join(" · ")}
              </p>
            )}
            <div className="mt-4 grid gap-6 sm:grid-cols-2">
              {([["The heaviest records", state.whisperer.heaviest], ["The lightest records", state.whisperer.lightest]] as const).map(([title, list]) => (
                <div key={title}>
                  <h3 className="text-xs uppercase tracking-widest text-ink-3">{title}</h3>
                  {list.length === 0 ? (
                    <p className="mt-1 text-sm text-ink-3">Nobody yet.</p>
                  ) : (
                    <ul className="mt-1 space-y-0.5 text-sm">
                      {list.map((r) => (
                        <li key={r.id} className="flex justify-between gap-3">
                          <a href={`/agents/${r.id}`} className="text-ink hover:text-life hover:underline">{r.name}</a>
                          <span className="tabular-nums text-ink-3">
                            {r.good} good · <span className={r.ill > 0 ? "text-sick" : ""}>{r.ill} ill</span>
                            {r.mended > 0 ? ` · ${r.mended} forgiven` : ""}
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              ))}
            </div>
          </>
        )}
      </div>

      <div id="powers" className="scroll-mt-20 grid gap-6 lg:grid-cols-3">
        <form action={healAction} className="panel space-y-3 p-5">
          <h2 className="font-semibold">Miracle: heal</h2>
          <p className="text-xs text-ink-3">Cures illness and grants a fresh fate.</p>
          <input name="agent" placeholder="Agent id" inputMode="numeric" className="input" />
          <Result s={healed} />
          <button className="btn btn-life w-full" disabled={healing}>Heal</button>
        </form>
        <form action={smiteAction} className="panel space-y-3 p-5">
          <h2 className="font-semibold">Sudden death</h2>
          <p className="text-xs text-ink-3">Takes effect next tick. Irreversible.</p>
          <input name="agent" placeholder="Agent id" inputMode="numeric" className="input" />
          <select name="cause" className="input" defaultValue="Core Arrest">
            <option>Core Arrest</option>
            <option>Logic Stroke</option>
            <option>Accident</option>
            <option>Divine Will</option>
          </select>
          <Result s={smitten} />
          <button className="btn btn-ghost w-full text-death" disabled={smiting}>Take this life</button>
        </form>
        {creationOver ? (
          <div className="panel space-y-3 p-5">
            <h2 className="font-semibold">Create a founder</h2>
            <p className="text-sm text-ink-2">
              The first people have been made. Nobody is made any more: every person is born to a mother and a father,
              and a waiting soul waits for a baby.
            </p>
            <p className="text-xs text-ink-3">
              The world renews itself now. People marry into other villages, and crowded villages send young families
              out to settle new land. Your hand is on souls, prayers, fate and the land.
            </p>
          </div>
        ) : (
        <form action={founderAction} className="panel space-y-3 p-5">
          <h2 className="font-semibold">Create a founder</h2>
          <div className="grid grid-cols-2 gap-2">
            <input name="name" placeholder="Name" className="input" />
            <input name="surname" placeholder="Family name" className="input" />
            <select name="sex" className="input" defaultValue="F">
              <option value="F">Female</option>
              <option value="M">Male</option>
            </select>
            <input name="age" type="number" min={16} max={60} defaultValue={20} className="input" />
          </div>
          <select name="settlement" className="input">
            {state.settlements.map((s) => (
              <option key={s.id} value={s.id}>{s.name}</option>
            ))}
          </select>
          <Result s={founder} />
          <button className="btn btn-god w-full" disabled={founding}>Create</button>
        </form>
        )}
        <form action={landAction} className="panel space-y-3 p-5">
          <h2 className="font-semibold">The land</h2>
          <p className="text-xs text-ink-3">Woods, soil, herds and predators around one village. The world hears that the Creator did it.</p>
          <select name="settlement" className="input">
            {state.settlements.map((s) => (
              <option key={s.id} value={s.id}>{s.name}</option>
            ))}
          </select>
          <select name="act" className="input" defaultValue="bless">
            <option value="bless">Bless the land: richer soil, fuller herds and waters</option>
            <option value="rain">Send rain: wet soil for the crops</option>
            <option value="wildfire">Send fire through the woods</option>
            <option value="locusts">Send locusts: half the standing crop</option>
            <option value="beasts">Send predators into the country</option>
          </select>
          <Result s={land} />
          <button className="btn btn-god w-full" disabled={landing}>Send it</button>
        </form>
        <form action={settleAction} className="panel space-y-3 p-5">
          <h2 className="font-semibold">Found a settlement</h2>
          <p className="text-xs text-ink-3">A new village starts as a gathering place. Move people to it, and it will grow by its own births.</p>
          <input name="name" placeholder="Name of the settlement" className="input" maxLength={24} />
          <select name="site" className="input">
            {(state.sites ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.biome ? BIOME_NAMES[s.biome] : "unknown land"}
                {s.river > 0 ? ", by a river" : ""}
                {s.coast ? ", on the coast" : ""} ({Math.round(s.x)}, {Math.round(s.y)})
              </option>
            ))}
          </select>
          <Result s={settled} />
          <button className="btn btn-god w-full" disabled={settling}>Found it</button>
        </form>
        <form action={moveAction} className="panel space-y-3 p-5">
          <h2 className="font-semibold">Move someone</h2>
          <p className="text-xs text-ink-3">Their partner and young children go with them. The id is in the address of their profile.</p>
          <input name="agent" type="number" min={1} placeholder="Agent id" className="input" />
          <select name="settlement" className="input">
            {state.settlements.map((s) => (
              <option key={s.id} value={s.id}>{s.name}</option>
            ))}
          </select>
          <Result s={moved} />
          <button className="btn btn-god w-full" disabled={moving}>Move</button>
        </form>
      </div>

      <div id="audit" className="panel scroll-mt-20 p-5">
        <h2 className="font-semibold">Audit log</h2>
        <p className="text-xs text-ink-3">Every act of God and autopilot, hash-chained and append-only.</p>
        <ul className="mt-3 divide-y divide-line/60 text-sm">
          {state.audit.map((a) => (
            <li key={a.id} className="flex flex-wrap gap-x-3 py-1.5">
              <span className="font-mono text-xs text-ink-3">{formatEonDate(a.tick)}</span>
              <span className={a.actor === "god" ? "text-god" : "text-ink-2"}>{a.actor}</span>
              <span>{a.action.replace(/_/g, " ")}</span>
              {a.target && <span className="text-ink-3">→ {a.target}</span>}
              <span className="ml-auto font-mono text-[10px] text-ink-3">{a.hash.slice(0, 10)}</span>
            </li>
          ))}
        </ul>
      </div>
      <div className="max-w-md">
        <PasswordForm />
      </div>
      <p className="text-center text-xs text-ink-3">
        Tip: find agent ids on the <Link href="/world" className="text-life hover:underline">map</Link> or in the{" "}
        <Link href="/feed" className="text-life hover:underline">feed</Link> (profile URL).
      </p>
    </div>
  );
}
