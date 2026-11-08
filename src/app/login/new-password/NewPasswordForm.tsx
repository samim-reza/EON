"use client";

import { useActionState } from "react";
import { keepInputs } from "@/components/keep-inputs";
import { setNewPassword, type NewPasswordState } from "../reset-actions";

export function NewPasswordForm({ token }: { token: string }) {
  const [state, action, pending] = useActionState<NewPasswordState, FormData>(setNewPassword, { error: null });
  return (
    <form action={action} onSubmit={keepInputs(action)} className="space-y-4">
      <input type="hidden" name="token" value={token} />
      <label className="block text-sm">
        <span className="text-ink-2">New password</span>
        <input name="password" type="password" required minLength={12} maxLength={72} autoComplete="new-password" className="input mt-1" />
        <span className="mt-1 block text-xs text-ink-3">At least 12 characters, with a letter and a digit.</span>
      </label>
      <label className="block text-sm">
        <span className="text-ink-2">Type it again</span>
        <input name="confirm" type="password" required minLength={12} maxLength={72} autoComplete="new-password" className="input mt-1" />
      </label>
      {state.error && <p className="text-sm text-death">{state.error}</p>}
      <button className="btn btn-life w-full" disabled={pending}>
        {pending ? "Saving…" : "Save new password"}
      </button>
    </form>
  );
}
