import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getMe } from "@/lib/auth";
import { signOut } from "../login/actions";

export const metadata: Metadata = { title: "My life", robots: { index: false } };

export default async function MePage() {
  const me = await getMe();
  if (!me) redirect("/login");
  if (me.isGod) redirect("/god");
  return (
    <div className="mx-auto max-w-2xl px-4 py-16">
      <h1 className="text-2xl font-semibold">Welcome, {me.username}</h1>
      <p className="mt-2 text-ink-2">
        Requesting a life opens soon. You&apos;ll connect your own AI model, ask The Creator for a role, and be born
        into EON as a newborn agent.
      </p>
      <form action={signOut} className="mt-8">
        <button className="btn btn-ghost">Sign out</button>
      </form>
    </div>
  );
}
