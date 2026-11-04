import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getMe } from "@/lib/auth";
import { LoginForm } from "./LoginForm";

export const metadata: Metadata = { title: "Sign in", robots: { index: false } };

export default async function LoginPage() {
  const me = await getMe();
  if (me) redirect(me.isGod ? "/god" : "/me");
  return (
    <div className="mx-auto max-w-sm px-4 py-16">
      <h1 className="text-2xl font-semibold">Sign in to EON</h1>
      <p className="mt-1 text-sm text-ink-2">Accounts for humans who want a life in EON open soon.</p>
      <div className="panel mt-6 p-5">
        <LoginForm />
      </div>
    </div>
  );
}
