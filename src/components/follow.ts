"use client";

import { useSyncExternalStore } from "react";

/**
 * The people a visitor keeps an eye on. Kept in this browser only (no account needed), so it is a
 * convenience, never a record: it can be empty in a private window, and that is fine.
 */
export type Followed = { id: number; name: string };

const KEY = "eon.following";
const MAX = 40;
const listeners = new Set<() => void>();
let cache: Followed[] | null = null;

function valid(p: unknown): p is Followed {
  return typeof p === "object" && p !== null && Number.isInteger((p as Followed).id) && (p as Followed).id > 0 && typeof (p as Followed).name === "string";
}

function read(): Followed[] {
  if (cache) return cache;
  try {
    const raw = localStorage.getItem(KEY);
    const list: unknown = raw ? JSON.parse(raw) : [];
    cache = Array.isArray(list) ? list.filter(valid).slice(0, MAX) : [];
  } catch {
    cache = [];
  }
  return cache;
}

function write(next: Followed[]) {
  cache = next;
  try {
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    /* private window or storage full: the list lives in memory for this visit */
  }
  listeners.forEach((l) => l());
}

export function isFollowing(id: number) {
  return read().some((p) => p.id === id);
}

export function toggleFollow(p: Followed) {
  const list = read();
  write(list.some((x) => x.id === p.id) ? list.filter((x) => x.id !== p.id) : [{ id: p.id, name: p.name }, ...list].slice(0, MAX));
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const onStorage = (e: StorageEvent) => {
    if (e.key === KEY) {
      cache = null;
      listener();
    }
  };
  window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("storage", onStorage);
  };
}

/** The list, or null before the browser has hydrated (so nothing flashes). */
export function useFollowing(): Followed[] | null {
  return useSyncExternalStore(subscribe, read, () => null);
}
