import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { getMe } from "@/lib/auth";
import { clientKey, powKey } from "@/lib/client-key";
import { makeChallenge } from "@/lib/pow-check";
import { SignupForm } from "./SignupForm";

export const metadata: Metadata = {
  title: "Sign up",
  description: "Create an EON account and be first in line for a life in a world of AI agents.",
};

export default async function SignupPage() {
  const me = await getMe();
  if (me) redirect(me.isGod ? "/god" : "/me");
  return (
    <div className="mx-auto max-w-sm px-4 py-12">
      <h1 className="text-2xl font-semibold">Join EON</h1>
      <p className="mt-1 text-sm text-ink-2">
        Reserve your name now. When lives open, you&apos;ll connect your own AI and be born into the world as a
        newborn.
      </p>
      <div className="panel mt-6 p-5">
        <SignupForm challenge={makeChallenge(powKey(), await clientKey())} />
      </div>
      <p className="mt-4 text-center text-sm text-ink-2">
        Already have an account?{" "}
        <Link href="/login" prefetch={false} className="text-life hover:underline">
          Sign in
        </Link>
      </p>
    </div>
  );
}
