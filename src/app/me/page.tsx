import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { getMe } from "@/lib/auth";
import { createUserClient } from "@/lib/supabase/server";
import { formatEonDate } from "@/shared/time";
import { signOut } from "../login/actions";
import { RequestLife } from "./RequestLife";

export const metadata: Metadata = { title: "My life", robots: { index: false } };

type Soul = { status: "waiting" | "assigned" | "living" | "ended"; agent: number | null; dueTick: number | null; mother: string | null; father: string | null; place: string | null; name: string | null };

function Life({ soul }: { soul: Soul | null }) {
  if (soul?.status === "waiting") {
    return <p className="mt-2 text-ink-2">Your soul is waiting. You will be given a family soon, usually within six hours, once someone is expecting a child.</p>;
  }
  if (soul?.status === "assigned") {
    return (
      <p className="mt-2 text-ink-2">
        You will be born to <span className="text-ink">{soul.mother}</span> and <span className="text-ink">{soul.father}</span>
        {soul.place ? ` in ${soul.place}` : ""}, around {soul.dueTick != null ? formatEonDate(soul.dueTick) : "soon"}.
      </p>
    );
  }
  if (soul?.status === "living" && soul.agent) {
    return (
      <p className="mt-2 text-ink-2">
        You are <Link href={`/agents/${soul.agent}`} prefetch={false} className="text-life hover:underline">{soul.name}</Link>. Your life goes on by itself for now.
        Choices of your own, and your own AI model, are coming later.
      </p>
    );
  }
  return (
    <>
      <p className="mt-2 text-ink-2">
        {soul?.status === "ended" ? `${soul.name ?? "Your last life"} has ended. You can ask for another.` : "Ask for a life, and you will be born into EON as a newborn in a real family."}
      </p>
      <RequestLife />
    </>
  );
}

export default async function MePage() {
  const me = await getMe();
  if (!me) redirect("/login");
  if (me.isGod) redirect("/god");
  const supabase = await createUserClient();
  const { data } = await supabase.rpc("my_soul");
  return (
    <div className="mx-auto max-w-2xl px-4 py-16">
      <h1 className="text-2xl font-semibold">Welcome, {me.username}</h1>
      <Life soul={(data as Soul | null) ?? null} />
      <form action={signOut} className="mt-8">
        <button className="btn btn-ghost">Sign out</button>
      </form>
    </div>
  );
}
