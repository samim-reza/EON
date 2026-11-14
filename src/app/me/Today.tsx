"use client";

import { useActionState } from "react";
import { QUESTIONS } from "@/shared/soul-mind";
import { askMind, doDeed, type DeedState, type LifeState } from "./actions";

type Deed = { id: string; label: string; other?: number };

/** Deeds that take from the country around the village, or give back to it. */
const ON_THE_LAND = new Set(["forage", "fish", "hunt", "wood", "plant", "herd"]);

/** Things to do today, and questions to ask: a reason to come back between the big choices. */
export function Today({ name, deeds, left, asksLeft, asking }: { name: string; deeds: Deed[]; left: number; asksLeft: number; asking: boolean }) {
  const [done, act, acting] = useActionState<DeedState, FormData>(doDeed, { error: null });
  const [asked, ask, askingNow] = useActionState<LifeState, FormData>(askMind, { error: null });
  const land = deeds.filter((d) => ON_THE_LAND.has(d.id));
  return (
    <section className="mt-8">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-lg font-semibold">Today</h2>
        <span className="text-xs text-ink-3">{left} of 4 things left to do today</span>
      </div>
      {done.told && <p className="mt-2 rounded-lg border border-life/40 bg-life/10 px-3 py-2 text-sm text-ink">{done.told}</p>}
      {done.error && <p className="mt-2 text-sm text-death">{done.error}</p>}
      {left > 0 ? (
        <>
          {[
            { title: land.length ? "With people" : null, list: deeds.filter((d) => !ON_THE_LAND.has(d.id)) },
            { title: "On the land", list: land, note: "What you take comes out of the village's real herds, waters and woods. Planting puts trees back." },
          ].filter((group) => group.list.length > 0).map((group) => (
            <div key={group.title ?? "all"} className="mt-3">
              {group.title && <h3 className="text-xs uppercase tracking-widest text-ink-3">{group.title}</h3>}
              <div className="mt-2 flex flex-wrap gap-2">
                {group.list.map((d) => (
                  <form key={`${d.id}-${d.other ?? ""}`} action={act}>
                    <input type="hidden" name="deed" value={d.id} />
                    {d.other != null && <input type="hidden" name="other" value={d.other} />}
                    <button className="btn btn-ghost text-sm" disabled={acting}>{d.label}</button>
                  </form>
                ))}
              </div>
              {group.note && <p className="mt-2 text-xs text-ink-3">{group.note}</p>}
            </div>
          ))}
        </>
      ) : (
        <p className="mt-2 text-sm text-ink-3">{name} has done enough for one day. Come back tomorrow.</p>
      )}

      <div className="mt-5">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h3 className="text-sm font-semibold">Ask {name}</h3>
          <span className="text-xs text-ink-3">{asksLeft} of 3 questions left today</span>
        </div>
        {asking ? (
          <p className="mt-2 text-sm text-ink-2">{name} is thinking about your question. The answer appears under their thoughts in a minute or two.</p>
        ) : asksLeft > 0 ? (
          <div className="mt-2 flex flex-wrap gap-2">
            {Object.entries(QUESTIONS).map(([id, q]) => (
              <form key={id} action={ask}>
                <input type="hidden" name="question" value={id} />
                <button className="btn btn-ghost text-sm" disabled={askingNow}>{q}</button>
              </form>
            ))}
          </div>
        ) : (
          <p className="mt-2 text-sm text-ink-3">Let {name} be for now. You can ask again tomorrow.</p>
        )}
        {asked.error && <p className="mt-2 text-sm text-death">{asked.error}</p>}
      </div>
    </section>
  );
}
