import type { Metadata } from "next";
import Link from "next/link";
import { ForgotForm } from "./ForgotForm";

export const metadata: Metadata = { title: "Forgot password", robots: { index: false } };

export default function ForgotPage() {
  return (
    <div className="mx-auto max-w-sm px-4 py-16">
      <h1 className="text-2xl font-semibold">Forgot your password?</h1>
      <p className="mt-2 text-sm text-ink-2">Enter the email you signed up with and we’ll send you a link to choose a new one.</p>
      <div className="panel mt-6 p-5">
        <ForgotForm />
      </div>
      <p className="mt-4 text-center text-sm text-ink-2">
        <Link href="/login" prefetch={false} className="text-life hover:underline">
          Back to sign in
        </Link>
      </p>
    </div>
  );
}
