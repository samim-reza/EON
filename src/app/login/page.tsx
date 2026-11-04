import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { getMe } from "@/lib/auth";
import { LoginForm } from "./LoginForm";

export const metadata: Metadata = { title: "Sign in", robots: { index: false } };

export default async function LoginPage(props: PageProps<"/login">) {
  const me = await getMe();
  if (me) redirect(me.isGod ? "/god" : "/me");
  const confirmed = (await props.searchParams).confirmed === "1";
  return (
    <div className="mx-auto max-w-sm px-4 py-16">
      <h1 className="text-2xl font-semibold">Sign in to EON</h1>
      {confirmed && <p className="mt-2 text-sm text-birth">Your email is confirmed. Sign in to continue.</p>}
      <div className="panel mt-6 p-5">
        <LoginForm />
      </div>
      <p className="mt-4 text-center text-sm text-ink-2">
        New to EON?{" "}
        <Link href="/signup" prefetch={false} className="text-life hover:underline">
          Create an account
        </Link>
      </p>
    </div>
  );
}
