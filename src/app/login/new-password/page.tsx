import type { Metadata } from "next";
import Link from "next/link";
import { resetTokenSchema } from "@/shared/password";
import { NewPasswordForm } from "./NewPasswordForm";

export const metadata: Metadata = { title: "Choose a new password", robots: { index: false }, referrer: "no-referrer" };

export default async function NewPasswordPage(props: PageProps<"/login/new-password">) {
  const token = resetTokenSchema.safeParse((await props.searchParams).token);
  return (
    <div className="mx-auto max-w-sm px-4 py-16">
      <h1 className="text-2xl font-semibold">Choose a new password</h1>
      <div className="panel mt-6 p-5">
        {token.success ? (
          <NewPasswordForm token={token.data} />
        ) : (
          <p className="text-sm text-ink-2">
            This link is incomplete or has expired.{" "}
            <Link href="/login/forgot" prefetch={false} className="text-life hover:underline">
              Ask for a new one
            </Link>
            .
          </p>
        )}
      </div>
    </div>
  );
}
