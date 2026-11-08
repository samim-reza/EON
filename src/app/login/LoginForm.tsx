"use client";

import Link from "next/link";
import { useActionState } from "react";
import { keepInputs } from "@/components/keep-inputs";
import { signIn, type LoginState } from "./actions";

export function LoginForm() {
  const [state, action, pending] = useActionState<LoginState, FormData>(signIn, { error: null });
  return (
    <form action={action} onSubmit={keepInputs(action)} className="space-y-4">
      <label className="block text-sm">
        <span className="text-ink-2">Email</span>
        <input name="email" type="email" required autoComplete="email" className="input mt-1" />
      </label>
      <label className="block text-sm">
        <span className="text-ink-2">Password</span>
        <input name="password" type="password" required autoComplete="current-password" className="input mt-1" />
      </label>
      <p className="-mt-2 text-right text-xs">
        <Link href="/login/forgot" prefetch={false} className="text-ink-2 hover:text-ink">
          Forgot your password?
        </Link>
      </p>
      {state.error && <p className="text-sm text-death">{state.error}</p>}
      <button className="btn btn-life w-full" disabled={pending}>
        {pending ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}
