"use client";

import { useEffect, useState } from "react";
import { decodeNav, NAV_COOKIE } from "@/shared/nav-cookie";

/** `known` is false until we know: a signed-in visitor's person arrives a moment after the page. */
export type Me = { known: boolean; signedIn: boolean; agent: number | null; isGod: boolean; players: Map<number, string> };

const UNKNOWN: Me = { known: false, signedIn: false, agent: null, isGod: false, players: new Map() };
const KEY = "eon.me";
const FRESH_MS = 60_000;

type Stored = { at: number; agent: number | null; isGod: boolean; players: { agent: number; username: string }[] };

function signedIn(): boolean {
  const m = document.cookie.match(new RegExp(`(?:^|;\\s*)${NAV_COOKIE}=([^;]*)`));
  return decodeNav(m?.[1]) !== null;
}

const toMe = (s: Stored): Me => ({ known: true, signedIn: true, agent: s.agent, isGod: s.isGod, players: new Map(s.players.map((p) => [p.agent, p.username])) });

let pending: Promise<Stored | null> | null = null;

/** Asks the server once a minute at most, and never for visitors who are not signed in. */
async function load(): Promise<Stored | null> {
  try {
    const cached = JSON.parse(sessionStorage.getItem(KEY) ?? "null") as Stored | null;
    if (cached && Date.now() - cached.at < FRESH_MS) return cached;
  } catch {
    // storage can be unavailable; just ask
  }
  pending ??= fetch("/api/me", { credentials: "same-origin" })
    .then((r) => (r.ok ? r.json() : null))
    .then((d: Omit<Stored, "at"> | null) => {
      if (!d) return null;
      const s = { ...d, at: Date.now() };
      try {
        sessionStorage.setItem(KEY, JSON.stringify(s));
      } catch {
        // fine without storage
      }
      return s;
    })
    .catch(() => null)
    .finally(() => {
      pending = null;
    });
  return pending;
}

/** Forget what we know, e.g. right after a life begins or ends. */
export function forgetMe() {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    // nothing to forget
  }
}

/** The person the signed-in visitor lives as (and, for God, every player's person). */
export function useMe(): Me {
  const [me, setMe] = useState<Me>(UNKNOWN);
  useEffect(() => {
    let live = true;
    if (!signedIn()) {
      queueMicrotask(() => live && setMe({ ...UNKNOWN, known: true }));
      return () => {
        live = false;
      };
    }
    load().then((s) => {
      if (live) setMe(s ? toMe(s) : { ...UNKNOWN, known: true, signedIn: true });
    });
    return () => {
      live = false;
    };
  }, []);
  return me;
}
