"use server";

import { revalidatePath } from "next/cache";
import { createUserClient } from "@/lib/supabase/server";

export type LifeState = { error: string | null };

export async function requestLife(): Promise<LifeState> {
  const supabase = await createUserClient();
  const { error } = await supabase.rpc("request_life");
  if (error) return { error: error.message };
  revalidatePath("/me");
  return { error: null };
}
