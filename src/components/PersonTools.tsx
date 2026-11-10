"use client";

import Link from "next/link";
import { useActionState } from "react";
import { heal, sendSign, smite, type ActionResult } from "@/app/god/actions";
import { useMe } from "./me";

const init: ActionResult = { ok: false, error: null };

/**
 * On a person's page: "this is you" for a player looking at their own person, and the Creator's
 * hand for God (the database still checks God and a fresh second factor on every act).
 */
export function PersonTools({ id, name, alive }: { id: number; name: string; alive: boolean }) {
  const me = useMe();
  const [healed, healAction, healing] = useActionState(heal, init);
  const [signed, signAction, signing] = useActionState(sendSign, init);
  const [smitten, smiteAction, smiting] = useActionState(smite, init);

  if (me.agent === id) {
    return (
      <div className="mt-5 flex flex-wrap items-center gap-3 rounded-lg border border-god/50 bg-god/10 px-4 py-3 text-sm">
        <span className="font-semibold text-god">This is you.</span>
        <Link href="/me" prefetch={false} className="text-ink hover:underline">My life</Link>
        <Link href="/world?find=me" prefetch={false} className="text-ink hover:underline">Find me on the map</Link>
      </div>
    );
  }
  if (!me.isGod || !alive) return null;
  const soul = me.players.get(id);
  const results = [healed, signed, smitten];
  return (
    <div className="panel mt-5 space-y-2 p-4 text-sm">
      <div className="flex flex-wrap items-baseline gap-3">
        <span className="font-semibold text-god">The Creator</span>
        {soul && <span className="text-ink-2">soul of {soul}</span>}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <form action={healAction}>
          <input type="hidden" name="agent" value={id} />
          <button className="btn btn-ghost text-xs" disabled={healing}>Heal</button>
        </form>
        <form action={signAction} className="flex gap-1">
          <input type="hidden" name="agent" value={id} />
          <input name="text" placeholder="Send a dream" className="input h-8 w-52 text-xs" maxLength={200} />
          <button className="btn btn-ghost text-xs" disabled={signing}>Send</button>
        </form>
        <form action={smiteAction} onSubmit={(e) => { if (!window.confirm(`Take ${name}'s life? It cannot be undone.`)) e.preventDefault(); }}>
          <input type="hidden" name="agent" value={id} />
          <input type="hidden" name="cause" value="Divine Will" />
          <button className="btn btn-ghost text-xs text-death" disabled={smiting}>Take this life</button>
        </form>
      </div>
      {results.map((r, i) =>
        r.error ? <p key={i} className="text-death">{r.error}</p> : r.ok ? <p key={i} className="text-birth">Done.</p> : null,
      )}
    </div>
  );
}
