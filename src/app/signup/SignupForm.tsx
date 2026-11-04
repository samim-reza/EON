"use client";

import { useActionState } from "react";
import { keepInputs } from "@/components/keep-inputs";
import { signUp, type SignupState } from "./actions";

export function SignupForm() {
  const [state, action, pending] = useActionState<SignupState, FormData>(signUp, { error: null, sent: false });

  if (state.sent) {
    return (
      <div className="text-sm">
        <h2 className="font-semibold text-birth">Check your email</h2>
        <p className="mt-2 text-ink-2">We sent you a confirmation link. Open it to finish creating your account.</p>
      </div>
    );
  }
  return (
    <form action={action} onSubmit={keepInputs(action)} className="space-y-4">
      <label className="block text-sm">
        <span className="text-ink-2">Username</span>
        <input
          name="username"
          required
          minLength={3}
          maxLength={20}
          pattern="[a-zA-Z0-9_]+"
          title="Letters, digits and underscores"
          autoComplete="username"
          className="input mt-1"
        />
        <span className="mt-1 block text-xs text-ink-3">3–20 letters, digits or underscores.</span>
      </label>
      <label className="block text-sm">
        <span className="text-ink-2">Email</span>
        <input name="email" type="email" required autoComplete="email" className="input mt-1" />
      </label>
      <label className="block text-sm">
        <span className="text-ink-2">Password</span>
        <input name="password" type="password" required minLength={12} maxLength={72} autoComplete="new-password" className="input mt-1" />
        <span className="mt-1 block text-xs text-ink-3">At least 12 characters, with letters and digits.</span>
      </label>
      {/* Left empty by people; bots that fill every field reveal themselves. */}
      <div className="absolute -left-[9999px]" aria-hidden>
        <label>
          Website
          <input name="website" tabIndex={-1} autoComplete="off" />
        </label>
      </div>
      <label className="flex items-start gap-2 text-sm text-ink-2">
        <input name="age" type="checkbox" required className="mt-0.5" />
        <span>I am at least 13 years old.</span>
      </label>
      {state.error && <p className="text-sm text-death">{state.error}</p>}
      <button className="btn btn-life w-full" disabled={pending}>
        {pending ? "Creating your account…" : "Create account"}
      </button>
    </form>
  );
}
