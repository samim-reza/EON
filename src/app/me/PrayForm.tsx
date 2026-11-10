"use client";

import { useActionState } from "react";
import { pray, type LifeState } from "./actions";

const NEEDS: [string, string][] = [
  ["thanks", "Give thanks"], ["health", "Pray for health"], ["food", "Pray for food"], ["child", "Pray for a child"],
  ["safety", "Pray for safety"], ["peace", "Pray for peace"],
];

export function PrayForm({ suggested }: { suggested?: string }) {
  const [state, action, pending] = useActionState<LifeState, FormData>(pray, { error: null });
  return (
    <form action={action} className="flex flex-wrap items-center gap-2">
      <select name="need" defaultValue={suggested ?? "thanks"} className="input w-auto">
        {NEEDS.map(([id, label]) => (
          <option key={id} value={id}>{label}</option>
        ))}
      </select>
      <button className="btn btn-ghost text-sm" disabled={pending}>{pending ? "Praying…" : "Pray"}</button>
      {state.error && <p className="w-full text-sm text-death">{state.error}</p>}
    </form>
  );
}
