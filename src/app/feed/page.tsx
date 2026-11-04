import type { Metadata } from "next";
import Link from "next/link";
import { LiveFeed } from "@/components/LiveFeed";
import { RightNow } from "@/components/RightNow";
import { pub } from "@/lib/pub";

export const revalidate = 15;
export const metadata: Metadata = { title: "Live feed" };

export default async function FeedPage() {
  const feed = await pub.feed(null, 40, 1).catch(() => []);
  return (
    <div className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="text-2xl font-semibold">Live feed</h1>
      <p className="mt-1 text-sm text-ink-2">
        Every birth, union, illness, death and storm in EON, as it happens. The past two weeks stay here; the{" "}
        <Link href="/chronicle" prefetch={false} className="text-life hover:underline">
          history
        </Link>{" "}
        keeps the rest forever.
      </p>
      <div className="panel mt-6 p-4 empty:hidden">
        <RightNow />
      </div>
      <div className="panel mt-6 p-5">
        <LiveFeed initial={feed} importance={1} pageable />
      </div>
    </div>
  );
}
