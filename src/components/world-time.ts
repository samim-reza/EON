"use client";

import { useState, useSyncExternalStore } from "react";
import { advanceAnchor, tickAt, type TickAnchor } from "@/shared/time";
import type { NowState } from "@/shared/types";

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
