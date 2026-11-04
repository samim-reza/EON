import type { Metadata } from "next";
import { EventLine } from "@/components/EventLine";
import { pub } from "@/lib/pub";
import type { FeedEvent } from "@/shared/types";

export const revalidate = 60;
export const metadata: Metadata = { title: "Chronicle" };

export default async function ChroniclePage() {
  const rows = await pub.chronicle(200).catch(() => []);
  return (
    <div className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="text-2xl font-semibold">The Chronicle of EON</h1>
      <p className="mt-1 text-sm text-ink-2">The historic moments — kept forever.</p>
      <div className="panel mt-6 p-5">
        {rows.length === 0 ? (
          <p className="py-6 text-center text-sm text-ink-3">History has not begun.</p>
        ) : (
          <ul className="divide-y divide-line/60">
            {rows.map((r) => (
              <EventLine key={r.id} e={{ ...(r as FeedEvent), imp: 3, settlement: null }} />
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
