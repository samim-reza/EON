"use client";

import { useActionState, useState, useTransition } from "react";
import { mfaEnroll, mfaVerify, type ActionResult } from "./actions";

/** TOTP enrollment (first time) or verification (each session) before God powers unlock. */
export function MfaGate({ factorId: existingFactor }: { factorId: string | null }) {
  const [enroll, setEnroll] = useState<{ factorId: string; qr: string; secret: string } | null>(null);
  const [enrollError, setEnrollError] = useState<string | null>(null);
  const [starting, startTransition] = useTransition();
  const [state, verify, verifying] = useActionState<ActionResult, FormData>(mfaVerify, { ok: false, error: null });
  const factorId = existingFactor ?? enroll?.factorId ?? null;

  const begin = () =>
    startTransition(async () => {
      const r = await mfaEnroll();
      if (r.ok) setEnroll(r.data as { factorId: string; qr: string; secret: string });
      else setEnrollError(r.error);
    });

  return (
    <div className="panel mx-auto max-w-md p-6">
      <h2 className="text-lg font-semibold text-god">Prove you are The Creator</h2>
      {!factorId ? (
        <>
          <p className="mt-2 text-sm text-ink-2">
            God powers require a second factor. Set up an authenticator app (Google Authenticator, Authy, 1Password…)
            once; after that you&apos;ll enter a 6-digit code at least every 12 hours.
          </p>
          <button onClick={begin} disabled={starting} className="btn btn-god mt-4 w-full">
            {starting ? "Preparing…" : "Set up authenticator"}
          </button>
          {enrollError && <p className="mt-2 text-sm text-death">{enrollError}</p>}
        </>
      ) : (
        <>
          {enroll && (
            <div className="mt-3 space-y-2 text-sm text-ink-2">
              <p>Scan this code with your authenticator app:</p>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={enroll.qr} alt="Authenticator QR code" className="mx-auto h-48 w-48 rounded bg-white p-2" />
              <p className="break-all text-center font-mono text-xs text-ink-3">or enter: {enroll.secret}</p>
            </div>
          )}
          <form action={verify} className="mt-4 space-y-3">
            <input type="hidden" name="factorId" value={factorId} />
            <input
              name="code"
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="\d{6}"
              maxLength={6}
              required
              placeholder="6-digit code"
              className="input text-center font-mono text-lg tracking-[0.4em]"
            />
            {state.error && <p className="text-sm text-death">{state.error}</p>}
            <button className="btn btn-god w-full" disabled={verifying}>
              {verifying ? "Verifying…" : "Verify"}
            </button>
          </form>
        </>
      )}
    </div>
  );
}
