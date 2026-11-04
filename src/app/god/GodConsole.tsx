"use client";

import Link from "next/link";
import { useActionState, useTransition } from "react";
import { formatEonDate } from "@/shared/time";
import { changePassword, createFounder, genesis, heal, setPaused, setWorld, smite, type ActionResult } from "./actions";

export type GodState = {
  world: {
    tick: number; paused: boolean; genesis_at: string | null; seed: string; last_tick_ms: number; genesis_end_tick: number;
    capacity_k: number; fertility_mult: number; mortality_mult: number; disease_mult: number; crime_mult: number;
    temp_shift: number; rain_mult: number;
    female_ratio: number; autopilot: boolean;
  };
  population: number;
  dead: number;
  pregnant: number;
  sick: number;
  settlements: { id: number; name: string; kind: string; pop: number }[];
  pyramid: { band: number; F: number; M: number }[];
  dbBytes: number;
  audit: { id: number; at: string; actor: string; action: string; target: string | null; tick: number; hash: string }[];
};

const init: ActionResult = { ok: false, error: null };

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
        <span className={`tag ${w.tick < w.genesis_end_tick ? "text-god" : ""}`}>
          {w.tick < w.genesis_end_tick ? `Genesis era until ${formatEonDate(w.genesis_end_tick)}` : "Genesis era over"}
        </span>
        <button
          className={`btn ${w.paused ? "btn-life" : "btn-ghost"} ml-auto`}
          disabled={pausing}
          onClick={() => startPause(async () => void (await setPaused(!w.paused)))}
        >
          {w.paused ? "Resume time" : "Pause time"}
        </button>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
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
          <Slider name="temp_shift" label="World temperature" value={w.temp_shift} min={-20} max={20} step={0.5} hint="°C added everywhere: 0 = natural" />
          <Slider name="rain_mult" label="Rainfall" value={w.rain_mult} min={0} max={4} step={0.05} hint="1 = natural, 0 = endless drought" />
          <Slider name="female_ratio" label="Share of girls at birth" value={w.female_ratio} min={0.3} max={0.7} step={0.01} hint="0.5 = even" />
          <Slider name="capacity_k" label="Land capacity (K)" value={w.capacity_k} min={50} max={200000} step={50} hint="population settles ≈ 1.7 × K" />
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" name="autopilot" defaultChecked={w.autopilot} /> Autopilot (sends founders during Genesis, acts when you are away)
          </label>
          <Result s={balance} />
          <button className="btn btn-god w-full" disabled={balancing}>
            {balancing ? "Rebalancing…" : "Apply"}
          </button>
        </form>
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
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
      </div>

      <div className="panel p-5">
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
