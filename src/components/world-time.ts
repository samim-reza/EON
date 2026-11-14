"use client";

import { useEffect, useState, useSyncExternalStore } from "react";
import { advanceAnchor, tickAt, type TickAnchor } from "@/shared/time";
import type { FeedEvent, NowState } from "@/shared/types";

const POLL_MS = 30_000;
const MAX_BACKOFF_MS = 5 * 60_000;
const STALE_MS = 15_000;

type Snapshot = { now: NowState | null; anchor: TickAnchor | null; failing: boolean };

/**
 * One poller for the whole tab. Map, clock, stats and ages all read this store, so a page full of
 * live widgets costs one request every 30 s. It stops in hidden tabs, backs off when the server
 * has trouble, and jitters so that viewers don't all arrive in the same instant.
 */
let snapshot: Snapshot = { now: null, anchor: null, failing: false };
let timer: ReturnType<typeof setTimeout> | undefined;
let failures = 0;
let lastPoll = -Infinity;
const listeners = new Set<() => void>();

function publish(next: Snapshot) {
  snapshot = next;
  listeners.forEach((listener) => listener());
}

function schedule() {
  clearTimeout(timer);
  if (!listeners.size) return;
  const delay = Math.min(MAX_BACKOFF_MS, POLL_MS * 2 ** failures);
  timer = setTimeout(poll, delay * (0.9 + Math.random() * 0.2));
}

async function poll() {
  if (document.visibilityState === "visible") {
    lastPoll = performance.now();
    try {
      const response = await fetch("/api/pub/now");
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const now: NowState = await response.json();
      failures = 0;
      publish({ now, anchor: advanceAnchor(snapshot.anchor, now.tick, performance.now(), now.paused), failing: false });
    } catch {
      failures += 1;
      publish({ ...snapshot, failing: true });
    }
  }
  schedule();
}

function onVisibility() {
  if (document.visibilityState === "visible" && performance.now() - lastPoll > STALE_MS) void poll();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  if (listeners.size === 1) {
    document.addEventListener("visibilitychange", onVisibility);
    if (performance.now() - lastPoll > STALE_MS) void poll();
    else schedule();
  }
  return () => {
    listeners.delete(listener);
    if (!listeners.size) {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibility);
    }
  };
}

const getSnapshot = () => snapshot;

/** Latest world state, starting from what the server rendered. */
export function useWorld(initial: NowState | null = null) {
  const [fallback] = useState(initial);
  const state = useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
  return { now: state.now ?? fallback, failing: state.failing };
}

/** Smooth world time for animation loops: reads the clock without any React render. */
export function currentTick(): number | null {
  const { now, anchor } = snapshot;
  return now && anchor ? tickAt(anchor, performance.now(), now.paused) : null;
}

/** `biome`, `land` and `pop` come with a village on the map, so the panel beside it can describe its country. */
export type Focus = { id?: number; name: string; x: number; y: number; biome?: string; land?: number[]; pop?: number };

let focus: Focus | null = null;
const focusListeners = new Set<() => void>();

/** The place the map is showing, so the clock can report the weather there. */
export function setFocus(next: Focus) {
  if (focus?.name === next.name && focus.land === next.land) return;
  focus = next;
  focusListeners.forEach((listener) => listener());
}

function subscribeFocus(listener: () => void) {
  focusListeners.add(listener);
  return () => {
    focusListeners.delete(listener);
  };
}

export const useFocus = () => useSyncExternalStore(subscribeFocus, () => focus, () => null);

export type Resident = { id: number; name: string; job: string; birth: number; home: number | null };

let residents: ReadonlyMap<number, Resident[]> = new Map();
const residentListeners = new Set<() => void>();

/** Everyone the map knows about, by settlement. Pages with a map share it instead of fetching again. */
export function setResidents(next: ReadonlyMap<number, Resident[]>) {
  residents = next;
  residentListeners.forEach((listener) => listener());
}

function subscribeResidents(listener: () => void) {
  residentListeners.add(listener);
  return () => {
    residentListeners.delete(listener);
  };
}

export const useResidents = () => useSyncExternalStore(subscribeResidents, () => residents, () => residents);

/** Re-reads world time once a second. An EON minute lasts 1/6 of a real second, so the clock visibly runs. */
export function useTick(): number | null {
  useWorld(); // Subscribing is what starts the shared poller; a page may have no other live widget.
  const [tick, setTick] = useState<number | null>(null);
  useEffect(() => {
    const update = () => setTick(currentTick());
    const first = setTimeout(update, 0);
    const id = setInterval(update, 1000);
    return () => {
      clearTimeout(first);
      clearInterval(id);
    };
  }, []);
  return tick;
}

let recent: readonly FeedEvent[] = [];
const recentListeners = new Set<() => void>();

/** The newest events, shared by the feed that fetched them, so the map can show a fire or a flood without asking again. */
export function setRecentEvents(next: readonly FeedEvent[]) {
  recent = next;
  recentListeners.forEach((listener) => listener());
}

export const recentEvents = () => recent;

function subscribeRecent(listener: () => void) {
  recentListeners.add(listener);
  return () => {
    recentListeners.delete(listener);
  };
}

export const useRecentEvents = () => useSyncExternalStore(subscribeRecent, recentEvents, recentEvents);
