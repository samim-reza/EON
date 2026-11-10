import { createUserClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

/**
 * Who the signed-in visitor is in the world: the person they live as and, for God, every player's
 * person. Private and never cached. Pages only ask when the display cookie says someone is signed in.
 */
export async function GET() {
  const headers = { "Cache-Control": "private, no-store" };
  const supabase = await createUserClient();
  const { data: me } = await supabase.rpc("whoami");
  if (!me) return Response.json({ agent: null, isGod: false, players: [] }, { headers });
  let players: { agent: number; username: string }[] = [];
  if (me.is_god) {
    // Needs God's fresh second factor; without it the map simply shows no names.
    const { data } = await supabase.rpc("god_player_agents");
    players = (data ?? []) as typeof players;
  }
  return Response.json({ agent: (me.agent as number | null) ?? null, isGod: Boolean(me.is_god), players }, { headers });
}
