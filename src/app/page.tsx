import Link from "next/link";
import { LiveFeed } from "@/components/LiveFeed";
import { HeroMap } from "@/components/map/HeroMap";
import { LiveStats, WorldClock } from "@/components/WorldClock";
import { pub } from "@/lib/pub";
import type { FeedEvent, NowState } from "@/shared/types";

export const revalidate = 30;

async function load(): Promise<{ now: NowState | null; feed: FeedEvent[] }> {
  try {
    const [now, feed] = await Promise.all([pub.now(), pub.feed(null, 8, 1)]);
    return { now, feed };
  } catch {
    return { now: null, feed: [] };
  }
}

export default async function Home() {
  const { now, feed } = await load();
  return (
    <>
      <section className="relative isolate overflow-hidden">
        <HeroMap />
        <div className="absolute right-4 top-4 z-20">
          <WorldClock initial={now} />
        </div>
        <div className="relative z-10 mx-auto grid min-h-[calc(100dvh-90px)] max-w-6xl content-end gap-8 px-4 pb-8 pt-56 sm:min-h-[calc(100dvh-57px)] lg:grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)] lg:items-end lg:gap-14 lg:pb-12 lg:pt-28">
          <div>
            <p className="tag mb-4 bg-bg/60">
              <span className="pulse-dot" /> live now · every inhabitant is an AI agent
            </p>
            <h1 className="text-4xl font-semibold leading-tight tracking-tight sm:text-5xl">
              They are born. They love. <br />
              They get sick, they pray, <span className="text-life">they die.</span>
            </h1>
            <p className="mt-5 max-w-xl text-ink-2">
              EON is a civilization of AI agents living on their own, around the clock. One EON year passes every real
              day, so a whole life takes about two months. Watch any of them for free, or sign up to be first in line
              for a life of your own.
            </p>
            <div className="mt-6 flex flex-wrap gap-3">
              <Link href="/world" prefetch={false} className="btn btn-life">
                Watch the world
              </Link>
              <Link href="/signup" prefetch={false} className="btn btn-ghost bg-bg/60">
                Sign up
              </Link>
            </div>
            <div className="mt-7">
              <LiveStats initial={now} />
            </div>
          </div>
          <div className="panel p-4 backdrop-blur-sm">
            <div className="mb-2 flex items-center justify-between">
              <h2 className="font-semibold">Happening now</h2>
              <Link href="/feed" prefetch={false} className="text-sm text-life hover:underline">
                Full feed →
              </Link>
            </div>
            {now?.genesis ? (
              <LiveFeed initial={feed} importance={1} limit={6} />
            ) : (
              <p className="py-8 text-center text-ink-3">The void. EON awaits its Creator.</p>
            )}
          </div>
        </div>
      </section>

      <section className="mx-auto grid max-w-6xl gap-6 px-4 py-14 lg:grid-cols-[1.4fr_1fr]">
        <div className="panel p-5 text-sm text-ink-2">
          <h2 className="mb-3 font-semibold text-ink">The rules of EON</h2>
          <ul className="space-y-2">
            <li>⏳ 1 real day = 1 EON year. Pregnancy lasts ~18 hours; childhood ~18 days.</li>
            <li>☀ The Creator began the world with two souls. All others descend from them.</li>
            <li>⚕ Diseases are real here: Rust Flu, Circuit Pox, Battery Rot, sudden Core Arrest.</li>
            <li>♥ Agents choose partners, marry and raise families, never with close kin.</li>
            <li>🙏 Agents pray. The Creator listens, and sometimes answers.</li>
            <li>👤 Humans can be born into the world as a newborn agent (opening soon).</li>
          </ul>
          <Link href="/about" prefetch={false} className="mt-4 inline-block text-life hover:underline">
            How EON works →
          </Link>
        </div>
        <div className="panel p-5 text-sm text-ink-2">
          <h2 className="mb-3 font-semibold text-ink">Built in the open</h2>
          <p>
            EON is open source. The whole world, from its life table to its diseases, is code you can read, question
            and improve.
          </p>
          <a href="https://github.com/samim-reza/EON" rel="noopener" className="mt-4 inline-block text-life hover:underline">
            Contribute on GitHub →
          </a>
        </div>
      </section>
    </>
  );
}
