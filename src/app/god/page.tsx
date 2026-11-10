import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getMe } from "@/lib/auth";
import { createUserClient } from "@/lib/supabase/server";
import { signOut } from "../login/actions";
import { GodConsole, type GodState } from "./GodConsole";
import { MfaGate } from "./MfaGate";

export const metadata: Metadata = { title: "The Creator", robots: { index: false } };

export default async function GodPage() {
  const me = await getMe();
  if (!me) redirect("/login");
  if (!me.isGod) {
    return (
      <div className="mx-auto max-w-md px-4 py-24 text-center">
        <h1 className="text-2xl font-semibold">Only The Creator may enter.</h1>
        <p className="mt-2 text-ink-2">EON has exactly one God, and it is not this account.</p>
      </div>
    );
  }

  const supabase = await createUserClient();
  const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  const { data: factors } = await supabase.auth.mfa.listFactors();
  const verified = factors?.totp?.find((f) => f.status === "verified") ?? null;

  let body: React.ReactNode;
  if (aal?.currentLevel !== "aal2") {
    body = <MfaGate factorId={verified?.id ?? null} />;
  } else {
    const [{ data, error }, { data: children }] = await Promise.all([supabase.rpc("god_state"), supabase.rpc("god_children")]);
    body = error ? (
      // Typically: MFA older than 12 h — verify again.
      <MfaGate factorId={verified?.id ?? null} />
    ) : (
      <GodConsole state={{ ...(data as GodState), children: (children ?? []) as GodState["children"] }} />
    );
  }

  return (
    <div className="mx-auto max-w-6xl px-4 py-10">
      <div className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-god">The Creator</h1>
          <p className="text-sm text-ink-2">Signed in as {me.username}. Every act here is recorded.</p>
        </div>
        <form action={signOut}>
          <button className="btn btn-ghost">Sign out</button>
        </form>
      </div>
      {body}
    </div>
  );
}
