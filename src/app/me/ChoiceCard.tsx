"use client";

import { useActionState } from "react";
import { situation, timeLeft, type Choice } from "@/shared/choices";
import { choose, type LifeState } from "./actions";

export function ChoiceCard({ c, now, canChoose }: { c: Choice; now: number; canChoose: boolean }) {
  const [state, action, pending] = useActionState<LifeState, FormData>(choose, { error: null });
  return (
    <div className="panel p-4">
      <p className="text-ink">{situation(c)}</p>
      {canChoose ? (
        <div className="mt-3 flex flex-wrap gap-2">
          {c.options.map((o) => (
            <form key={o.id} action={action}>
              <input type="hidden" name="choice" value={c.id} />
              <input type="hidden" name="option" value={o.id} />
              <button className="btn btn-life text-sm" disabled={pending}>
                {o.label}
              </button>
            </form>
          ))}
        </div>
      ) : (
        <p className="mt-2 text-sm text-ink-3">Without a mind of their own, habit will decide this.</p>
      )}
      <p className="mt-2 text-xs text-ink-3">
        {c.status === "asked"
          ? "Their own mind is thinking it over. You can still choose."
          : `You have ${timeLeft(c.dueTick - now)} to choose. After that, their own mind decides.`}
      </p>
      {state.error && <p className="mt-2 text-sm text-death">{state.error}</p>}
    </div>
  );
}
