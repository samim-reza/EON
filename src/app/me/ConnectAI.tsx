"use client";

import { useActionState, useState } from "react";
import { PROVIDER_IDS, PROVIDERS, type ProviderId } from "@/shared/providers";
import { connectKey, removeKey, type KeyState } from "./actions";
import type { KeyInfo } from "./types";

const STATUS: Record<KeyInfo["status"], string> = {
  ok: "working",
  limited: "out of credit or over its limit for now",
  error: "the last call failed; it will try again",
  invalid: "no longer accepted: connect a new key",
};

export function ConnectAI({ current, folded }: { current: KeyInfo | null; folded?: string }) {
  const [state, action, pending] = useActionState<KeyState, FormData>(connectKey, { error: null });
  const [provider, setProvider] = useState<ProviderId>(current?.provider ?? "gemini");
  const p = PROVIDERS[provider];
  const body = (
    <>
      <p className="mt-1 text-sm text-ink-2">
        Your person&apos;s mind runs on an AI you bring: a few short calls a day, only for your own person. EON checks your key
        with its provider, stores it encrypted, and never shows it again.
      </p>
      {current && (
        <div className="mt-3 flex flex-wrap items-center gap-3 text-sm">
          <span className="text-ink">
            {PROVIDERS[current.provider].label} · ····{current.last4}
          </span>
          <span className={current.status === "ok" ? "text-life" : "text-sick"}>{STATUS[current.status]}</span>
          <span className="text-ink-3">{current.used} of {current.cap} calls today</span>
          <form action={removeKey}>
            <button className="btn btn-ghost text-xs">Remove key</button>
          </form>
        </div>
      )}
      <form action={action} className="mt-4 space-y-3">
        <label className="block text-sm">
          <span className="text-ink-2">Provider</span>
          <select name="provider" value={provider} onChange={(e) => setProvider(e.target.value as ProviderId)} className="input mt-1">
            {PROVIDER_IDS.map((id) => (
              <option key={id} value={id}>
                {PROVIDERS[id].label}{PROVIDERS[id].free ? " (free key available)" : ""}
              </option>
            ))}
          </select>
        </label>
        <p className="text-xs text-ink-3">
          <a href={p.keyUrl} target="_blank" rel="noopener noreferrer" className="text-life hover:underline">
            Get a {p.label} key
          </a>{" "}
          (it {p.keyHint}).{" "}
          {p.free ? "Free, no card needed." : "Needs credit on your account with them."}
        </p>
        <label className="block text-sm">
          <span className="text-ink-2">API key</span>
          <input name="key" type="password" required maxLength={300} autoComplete="off" spellCheck={false} className="input mt-1 font-mono" />
        </label>
        {state.error && <p className="text-sm text-death">{state.error}</p>}
        {state.saved && <p className="text-sm text-life">Connected. Your person thinks with it from now on.</p>}
        <button className="btn btn-life" disabled={pending}>
          {pending ? "Checking with the provider…" : current ? "Replace key" : "Connect"}
        </button>
      </form>
    </>
  );
  // During the free days the form waits behind one line, so nobody thinks they need a key yet.
  if (folded && !current && !state.error && !state.saved) {
    return (
      <details className="panel mt-8 p-5">
        <summary className="cursor-pointer text-lg font-semibold">
          Your AI <span className="ml-1 text-sm font-normal text-ink-3">{folded}</span>
        </summary>
        <div className="mt-2">{body}</div>
      </details>
    );
  }
  return (
    <section className="panel mt-8 p-5">
      <h2 className="text-lg font-semibold">Your AI</h2>
      {body}
    </section>
  );
}
