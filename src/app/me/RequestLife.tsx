"use client";

import { useActionState } from "react";
import { requestLife, type LifeState } from "./actions";

export function RequestLife() {
  const [state, action, pending] = useActionState<LifeState>(requestLife, { error: null });
  return (
    <form action={action} className="mt-6">
      {state.error && <p className="mb-3 text-sm text-death">{state.error}</p>}
      <button className="btn btn-life" disabled={pending}>
        {pending ? "Asking…" : "Request a life"}
      </button>
    </form>
  );
}
