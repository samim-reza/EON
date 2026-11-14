import "server-only";
import { adminClient } from "@/lib/supabase/admin";
import type { AgentDetail, AnnalEntry, ChronicleEntry, FamilyTree, FeedEvent, Geo, LandFeed, NowState, Progress, Roster, StatsRow } from "@/shared/types";

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await adminClient().rpc(fn, args ?? {});
  if (error) throw new Error(`${fn} failed: ${error.message}`);
  return data as T;
}

export const pub = {
  now: () => rpc<NowState>("pub_now"),
  events: (from: number, to: number) => rpc<{ from: number; to: number; events: FeedEvent[]; stats: StatsRow[] }>("pub_events", { p_from: from, p_to: to }),
  feed: (beforeTick: number | null, limit = 50, minImportance = 2) =>
    rpc<FeedEvent[]>("pub_feed", { p_before_tick: beforeTick, p_limit: limit, p_min_importance: minImportance }),
  roster: () => rpc<Roster>("pub_roster"),
  geo: () => rpc<Geo>("pub_geo"),
  land: () => rpc<LandFeed["land"]>("pub_land"),
  agent: (id: number) => rpc<AgentDetail | null>("pub_agent", { p_id: id }),
  family: (id: number) => rpc<FamilyTree>("pub_family", { p_id: id }),
  stats: (from: number, to: number, step = 120) => rpc<StatsRow[]>("pub_stats", { p_from: from, p_to: to, p_step: step }),
  chronicle: (limit = 100) => rpc<ChronicleEntry[]>("pub_chronicle", { p_limit: limit }),
  progress: () => rpc<Progress>("pub_progress"),
  annals: (limit = 120) => rpc<AnnalEntry[]>("pub_annals", { p_limit: limit }),
};
