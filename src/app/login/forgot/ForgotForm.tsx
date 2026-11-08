"use client";

import { useActionState } from "react";
import { keepInputs } from "@/components/keep-inputs";
import { requestReset, type ForgotState } from "../reset-actions";

export function ForgotForm() {
  const [state, action, pending] = useActionState<ForgotState, FormData>(requestReset, { error: null, sent: false });
  if (state.sent) {
    return (
      <p className="text-sm text-ink-2">
        If an account uses that address, we’ve sent it a link to choose a new password. It can take a few minutes; if it
        isn’t in your inbox, look in your spam folder.
      </p>
    );
  }
  return (
    <form action={action} onSubmit={keepInputs(action)} className="space-y-4">
      <label className="block text-sm">
        <span className="text-ink-2">Email</span>
        <input name="email" type="email" required autoComplete="email" className="input mt-1" />
      </label>
      {state.error && <p className="text-sm text-death">{state.error}</p>}
      <button className="btn btn-life w-full" disabled={pending}>
        {pending ? "Sending…" : "Send me a link"}
      </button>
    </form>
  );
}
