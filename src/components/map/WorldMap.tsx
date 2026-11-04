"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { LiveActivity, LiveAge, WorldClock } from "@/components/WorldClock";
import { climateOf } from "@/components/local-climate";
import { currentTick, setFocus, useWorld } from "@/components/world-time";
import { localHour, NO_TUNING, seasonCurve, smooth, tideAt, weatherAt, yearFraction, type Weather } from "@/shared/climate";
import { outfitFor, planFor, slotInfo, SLOTS_PER_TICK, spotFor, type Outfit, type Plan } from "@/shared/daily-life";
import { TILE_UNITS } from "@/shared/terrain-pixels";
import { FLAG_FOUNDER, FLAG_PLAYER, FLAG_PREGNANT, FLAG_SICK, type Geo, type Roster } from "@/shared/types";
import { lifeStage } from "@/shared/time";
import { hash01, indexBuildings, makeTerrain, settleOnLand, WORLD_SIZE, type BuildingIndex } from "@/shared/world";
import { createAtmosphere, type Atmosphere } from "./atmosphere";
import { loadTerrain, setTide, tilesFor, type TerrainMap } from "./terrain";

type Agent = {
  id: number; name: string; sex: "F" | "M"; birth: number; settlement: number; home: number | null;
  job: string; partner: number | null; flags: number;
};

type Cam = { x: number; y: number; z: number }; // world-space centre, pixels per world unit

/** Everyone in one settlement, with the radius they stay inside: off-screen towns skip all per-agent work. */
type Group = { x: number; y: number; radius: number; agents: Agent[] };

const HERO_HOLD_S = 26; // seconds at each settlement in the landing-page tour
const HERO_TRAVEL_S = 7; // of which the last few are spent travelling to the next one
const HERO_TERRAIN_RES = 1.5; // coarser than the full map: it sits behind text, and it loads faster
const TILES_FROM_ZOOM = 2.4; // the single map image is sharp enough below this
const HERO_NIGHT_LIFT = 0.1; // the landing page stays readable at midnight

function unpack(r: Roster): Agent[] {
  return r.id.map((id, i) => ({
    id, name: r.name[i], sex: r.sex[i], birth: r.birth[i], settlement: r.settlement[i], home: r.home[i],
    job: r.job[i], partner: r.partner[i], flags: r.flags[i],
  }));
}

const ease = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

/** A warm window glow, drawn once and stamped over every lit building. */
function makeGlow() {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 48;
  const ctx = canvas.getContext("2d")!;
  const glow = ctx.createRadialGradient(24, 24, 0, 24, 24, 24);
  glow.addColorStop(0, "rgba(255, 214, 140, 0.95)");
  glow.addColorStop(0.25, "rgba(255, 176, 92, 0.42)");
  glow.addColorStop(1, "rgba(255, 150, 60, 0)");
  ctx.fillStyle = glow;
  ctx.fillRect(0, 0, 48, 48);
  return canvas;
}

/** Homes light up at dusk and go dark as people go to bed. Lamps at public buildings burn all night. */
function windowLit(id: number, kind: string, hour: number) {
  if (kind !== "home") return true;
  return hour >= 15 ? hour < 21 + 2.6 * hash01(id, 3) : hour >= 4.8 + 2 * hash01(id, 3);
}

const SKINS = ["#f1d3b8", "#e0b48e", "#c68f63", "#9a6a45", "#6f4a31"];
const FIGURES_FROM_ZOOM = 6.5; // close enough to see what people are wearing

/** A tiny dressed person, for close zoom. Their sex colour stays as a ring at their feet. */
function drawFigure(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, outfit: Outfit, skin: string, ring: string) {
  ctx.fillStyle = "rgba(0, 0, 0, 0.3)";
  ctx.beginPath();
  ctx.ellipse(x + r * 0.2, y + r * 1.02, r * 0.72, r * 0.26, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = ring;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.ellipse(x, y + r, r * 0.62, r * 0.22, 0, 0, Math.PI * 2);
  ctx.stroke();
  ctx.fillStyle = outfit.colour;
  ctx.beginPath();
  ctx.moveTo(x - r * 0.58, y + r);
  ctx.lineTo(x + r * 0.58, y + r);
  ctx.lineTo(x + r * 0.4, y - r * 0.28);
  ctx.lineTo(x - r * 0.4, y - r * 0.28);
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = skin;
  ctx.beginPath();
  ctx.arc(x, y - r * 0.68, r * 0.42, 0, Math.PI * 2);
  ctx.fill();
  if (outfit.headwear === "hood" || outfit.headwear === "wrap" || outfit.headwear === "wool") {
    ctx.fillStyle = outfit.headwear === "wool" ? "#8c3b3b" : outfit.colour;
    ctx.beginPath();
    ctx.arc(x, y - r * 0.72, r * 0.46, Math.PI, 0);
    ctx.fill();
  } else if (outfit.headwear === "straw") {
    ctx.fillStyle = "#d8bf6a";
    ctx.beginPath();
    ctx.ellipse(x, y - r * 0.92, r * 0.72, r * 0.2, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  if (outfit.umbrella) {
    ctx.fillStyle = "#b5473f";
    ctx.beginPath();
    ctx.arc(x, y - r * 1.15, r * 0.95, Math.PI, 0);
    ctx.fill();
  }
}

const ROOFS: Record<string, string> = { home: "#a8694e", temple: "#c9a44e", clinic: "#8fc4bd", farm: "#b08a4a", market: "#b5604a", school: "#8d7fb0" };

export function WorldMap({ variant = "full" }: { variant?: "full" | "hero" }) {
  const hero = variant === "hero";
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const { now, failing } = useWorld();
  const [geo, setGeo] = useState<Geo | null>(null);
  const [agents, setAgents] = useState<Agent[]>([]);
  const [selected, setSelected] = useState<Agent | null>(null);
  const [follow, setFollow] = useState(false);
  const [query, setQuery] = useState("");
  const [loadFailed, setLoadFailed] = useState(false);
  const [ready, setReady] = useState(false);
  const [stop, setStop] = useState<{ name: string; pop: number } | null>(null);
  const cam = useRef<Cam>({ x: 500, y: 500, z: 3 });
  const terrain = useRef<TerrainMap | null>(null);
  const atmosphere = useRef<{ seed: number; value: Atmosphere } | null>(null);
  const tune = useRef(NO_TUNING);
  const glow = useRef<HTMLCanvasElement | null>(null);
  const placed = useRef(false);
  const onScreen = useRef(true);

  // --- data -------------------------------------------------------------------
  const requestedVersion = useRef<number>(-1);
  useEffect(() => {
    if (!now?.genesis || now.rosterVersion === requestedVersion.current) return;
    const version = now.rosterVersion;
    requestedVersion.current = version;
    fetch(`/api/pub/world/${version}`)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((data: { roster: Roster; geo: Geo }) => {
        setGeo(data.geo);
        setAgents(unpack(data.roster));
        setLoadFailed(false);
      })
      .catch(() => {
        requestedVersion.current = -1; // try again on the next poll
        setLoadFailed(true);
      });
  }, [now]);

  const idx: BuildingIndex | null = useMemo(
    () => (geo ? indexBuildings(settleOnLand(geo.buildings, geo.settlements, makeTerrain(Number(geo.seed)))) : null),
    [geo],
  );
  const settlementById = useMemo(() => new Map((geo?.settlements ?? []).map((s) => [s.id, s])), [geo]);

  const groups = useMemo<Group[]>(() => {
    const members = new Map<number, Agent[]>();
    for (const a of agents) {
      const list = members.get(a.settlement);
      if (list) list.push(a);
      else members.set(a.settlement, [a]);
    }
    const radius = new Map<number, number>();
    for (const b of idx?.byId.values() ?? []) {
      const s = settlementById.get(b.settlement);
      if (s) radius.set(b.settlement, Math.max(radius.get(b.settlement) ?? 0, Math.hypot(b.x - s.x, b.y - s.y)));
    }
    return [...members].map(([id, list]) => {
      const s = settlementById.get(id);
      return s ? { x: s.x, y: s.y, radius: (radius.get(id) ?? 0) + 8, agents: list } : { x: 500, y: 500, radius: WORLD_SIZE, agents: list };
    });
  }, [agents, idx, settlementById]);

  const stops = useMemo(() => [...(geo?.settlements ?? [])].sort((a, b) => b.pop - a.pop).slice(0, 6), [geo]);

  useEffect(() => {
    if (!geo) return;
    let live = true;
    const seed = Number(geo.seed);
    if (atmosphere.current?.seed !== seed) atmosphere.current = { seed, value: createAtmosphere(seed) };
    void loadTerrain(seed, hero ? HERO_TERRAIN_RES : 1).then((map) => {
      if (!live) return;
      terrain.current = map;
      setReady(true);
    });
    if (!placed.current && geo.settlements.length) {
      const s = geo.settlements[0];
      cam.current = { x: s.x, y: s.y, z: 7 };
      placed.current = true;
    }
    return () => {
      live = false;
    };
  }, [geo, hero]);

  useEffect(() => {
    tune.current = now?.tune ?? NO_TUNING;
  }, [now?.tune]);

  // The landing page must not spend the battery of someone reading further down.
  useEffect(() => {
    const wrap = wrapRef.current;
    if (!hero || !wrap) return;
    const observer = new IntersectionObserver(([entry]) => {
      onScreen.current = entry.isIntersecting;
    });
    observer.observe(wrap);
    return () => observer.disconnect();
  }, [hero]);

  // --- rendering ------------------------------------------------------------------
  const seed = geo ? Number(geo.seed) : 0;
  const weatherCache = useRef(new Map<number, Weather>());

  /** A settlement's weather on a half-hour slot: everyone there checks the same sky, once. */
  const weatherFor = useCallback(
    (settlement: number, x: number, y: number, slot: number) => {
      const key = slot * 4096 + settlement;
      const cache = weatherCache.current;
      let weather = cache.get(key);
      if (!weather) {
        weather = weatherAt(seed, climateOf(seed, x, y), x, y, slot / SLOTS_PER_TICK, tune.current);
        if (cache.size > 1500) cache.clear();
        cache.set(key, weather);
      }
      return weather;
    },
    [seed],
  );

  const positionOf = useCallback(
    (a: Agent, tf: number): { x: number; y: number; plan: Plan | null; moving: boolean; weather: Weather | null } => {
      if (!idx) return { x: 0, y: 0, plan: null, moving: false, weather: null };
      const s = settlementById.get(a.settlement);
      const home = s ? { x: s.x, y: s.y } : { x: 500, y: 500 };
      const person = { id: a.id, job: a.job, ageYears: (tf - a.birth) / 1440 };
      const position = tf * SLOTS_PER_TICK;
      const slot = Math.floor(position);
      const planAt = (n: number) => {
        const info = slotInfo(n, home.x);
        return planFor(person, info.hour, info.day, info.month, weatherFor(a.settlement, home.x, home.y, n));
      };
      const plan = planAt(slot);
      const before = planAt(slot - 1);
      const weather = weatherFor(a.settlement, home.x, home.y, slot);
      const to = spotFor(a, plan, idx, home);
      if (before.place === plan.place) return { ...to, plan, moving: false, weather };
      const from = spotFor(a, before, idx, home);
      const k = ease(position - slot);
      return { x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k, plan, moving: true, weather };
    },
    [idx, settlementById, weatherFor],
  );

  useEffect(() => {
    const canvas = canvasRef.current;
    const wrap = wrapRef.current;
    if (!canvas || !wrap) return;
    const ctx = canvas.getContext("2d")!;
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let raf = 0;
    let last = 0;
    let shownStop = "";
    let lastFocusCheck = 0;
    glow.current ??= makeGlow();
    const draw = (ts: number) => {
      raf = requestAnimationFrame(draw);
      if (ts - last < (hero ? 50 : 33) || !onScreen.current) return; // 20 fps behind the headline, 30 on the map
      const elapsed = Math.min(100, ts - last);
      last = ts;
      const dpr = Math.min(hero ? 1.5 : 2, window.devicePixelRatio || 1);
      const W = wrap.clientWidth;
      const H = wrap.clientHeight;
      const cw = Math.round(W * dpr);
      const ch = Math.round(H * dpr);
      if (canvas.width !== cw || canvas.height !== ch) {
        canvas.width = cw;
        canvas.height = ch;
        canvas.style.width = `${W}px`;
        canvas.style.height = `${H}px`;
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const tf = currentTick() ?? now?.tick ?? 0;
      const c = cam.current;
      if (follow && selected) {
        const p = positionOf(selected, tf);
        c.x += (p.x - c.x) * 0.15;
        c.y += (p.y - c.y) * 0.15;
      }
      const wide = W >= 1024;
      if (hero && stops.length) {
        const secs = reducedMotion ? 0 : ts / 1000;
        const seg = Math.floor(secs / HERO_HOLD_S);
        const from = stops[seg % stops.length];
        const to = stops[(seg + 1) % stops.length];
        const k = ease(Math.max(0, (secs % HERO_HOLD_S - (HERO_HOLD_S - HERO_TRAVEL_S)) / HERO_TRAVEL_S));
        const far = Math.min(1, Math.hypot(to.x - from.x, to.y - from.y) / 150);
        c.x = from.x + (to.x - from.x) * k + Math.cos(secs / 19) * 4;
        c.y = from.y + (to.y - from.y) * k + Math.sin(secs / 27) * 3;
        c.z = (wide ? 7.5 : 6.8) * (1 - 0.6 * far * Math.sin(Math.PI * k)) + Math.sin(secs / 31) * 0.3;
        const at = k < 0.5 ? from : to;
        const label = `${at.id}:${at.pop}`;
        if (label !== shownStop) {
          shownStop = label;
          setStop({ name: at.name, pop: at.pop });
          setFocus({ name: at.name, x: at.x, y: at.y });
        }
      }
      // The hero keeps the village clear of the headline and of the feed.
      const focusX = W * (hero ? (wide ? 0.6 : 0.3) : 0.5); // on phones, the space left of the clock
      const focusY = hero ? (wide ? H * 0.36 : 130) : H * 0.5; // on phones, the strip above the headline
      const sx = (x: number) => (x - c.x) * c.z + focusX;
      const sy = (y: number) => (y - c.y) * c.z + focusY;

      ctx.fillStyle = "rgb(8, 22, 46)"; // the open ocean, which is also the colour at the edge of the map
      ctx.fillRect(0, 0, W, H);
      const view = { x0: c.x - focusX / c.z, y0: c.y - focusY / c.z, x1: c.x + (W - focusX) / c.z, y1: c.y + (H - focusY) / c.z };
      if (!hero && ts - lastFocusCheck > 700 && geo?.settlements.length) {
        lastFocusCheck = ts;
        const nearest = geo.settlements.reduce((best, s) => (Math.hypot(s.x - c.x, s.y - c.y) < Math.hypot(best.x - c.x, best.y - c.y) ? s : best));
        setFocus({ name: nearest.name, x: nearest.x, y: nearest.y });
      }
      if (terrain.current) {
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = "high";
        ctx.drawImage(terrain.current.base, sx(0), sy(0), WORLD_SIZE * c.z, WORLD_SIZE * c.z);
        if (c.z >= TILES_FROM_ZOOM && geo) {
          const span = TILE_UNITS * c.z + 0.6; // a hair of overlap hides the seams
          const sea = 128 + 88 * tideAt(Number(geo.seed), tf, c.x); // the same sea level across the view
          let tideDone = false; // one tile a frame, so a long coast never causes a stutter
          for (const { x, y, tile } of tilesFor(Number(geo.seed), view.x0, view.y0, view.x1, view.y1)) {
            if (!tideDone) tideDone = setTide(tile, sea);
            ctx.globalAlpha = reducedMotion ? 1 : Math.min(1, (performance.now() - tile.born) / 350);
            ctx.drawImage(tile.canvas, sx(x * TILE_UNITS), sy(y * TILE_UNITS), span, span);
          }
          ctx.globalAlpha = 1;
        }
        // The year turns: leaves go gold, then snow settles from the cold places outward.
        const autumn = Math.exp(-(((yearFraction(tf) - 0.66) / 0.085) ** 2));
        if (autumn > 0.02) {
          ctx.globalAlpha = autumn;
          ctx.drawImage(terrain.current.autumn, sx(0), sy(0), WORLD_SIZE * c.z, WORLD_SIZE * c.z);
        }
        const snow = smooth(-0.1, -0.8, seasonCurve(tf));
        if (snow > 0.02) {
          ctx.globalAlpha = snow;
          ctx.drawImage(terrain.current.snow, sx(0), sy(0), WORLD_SIZE * c.z, WORLD_SIZE * c.z);
        }
        ctx.globalAlpha = 1;
      }

      // buildings
      if (idx && c.z >= 2.5) {
        for (const [, b] of idx.byId) {
          const x = sx(b.x);
          const y = sy(b.y);
          if (x < -10 || y < -10 || x > W + 10 || y > H + 10) continue;
          const s = Math.max(2, c.z * (b.kind === "home" ? 0.9 : 1.6));
          ctx.fillStyle = "rgba(0, 0, 0, 0.32)";
          ctx.fillRect(x - s / 2 + s * 0.2, y - s / 2 + s * 0.2, s, s);
          ctx.fillStyle = ROOFS[b.kind] ?? "#74839b";
          ctx.fillRect(x - s / 2, y - s / 2, s, s);
          ctx.fillStyle = "rgba(255, 255, 255, 0.2)";
          ctx.fillRect(x - s / 2, y - s / 2, s, s * 0.42); // the sunlit side of the roof
        }
      }

      // sky: clouds, the light of the hour, then what shines through the dark
      const sky = atmosphere.current?.value;
      if (sky) {
        sky.update(view, tf, c.z, tune.current, ts, hero ? HERO_NIGHT_LIFT : 0);
        sky.drawSky(ctx, sx, sy);
        const night = 1 - sky.daylight;
        if (idx && glow.current && night > 0.12 && c.z >= 1.4) {
          ctx.globalCompositeOperation = "lighter";
          for (const [id, b] of idx.byId) {
            const x = sx(b.x);
            const y = sy(b.y);
            if (x < -40 || y < -40 || x > W + 40 || y > H + 40) continue;
            if (!windowLit(id, b.kind, localHour(tf, b.x))) continue;
            const size = Math.min(44, c.z * (b.kind === "home" ? 2.6 : 4.2));
            ctx.globalAlpha = night * (0.62 + 0.38 * hash01(id, 5));
            ctx.drawImage(glow.current, x - size / 2, y - size / 2, size, size);
          }
          ctx.globalAlpha = 1;
          ctx.globalCompositeOperation = "source-over";
        }
      }

      // agents
      const r = Math.max(1.4, Math.min(5, c.z * 0.6));
      const labels: { x: number; y: number; name: string; d: number }[] = [];
      for (const g of groups) {
        const gx = sx(g.x);
        const gy = sy(g.y);
        const margin = g.radius * c.z + 10;
        if (gx < -margin || gy < -margin || gx > W + margin || gy > H + margin) continue;
        for (const a of g.agents) {
          const p = positionOf(a, tf);
          const x = sx(p.x);
          const y = sy(p.y);
          if (x < -5 || y < -5 || x > W + 5 || y > H + 5) continue;
          const stage = lifeStage((tf - a.birth) / 1440);
          if (c.z >= FIGURES_FROM_ZOOM && p.plan && p.weather && !p.plan.asleep && stage !== "baby") {
            const size = Math.min(11, Math.max(4.6, c.z * 0.56)) * (stage === "child" ? 0.78 : 1);
            const person = { id: a.id, job: a.job, ageYears: (tf - a.birth) / 1440 };
            const biome = climateOf(seed, settlementById.get(a.settlement)?.x ?? 500, settlementById.get(a.settlement)?.y ?? 500).biome;
            ctx.globalAlpha = p.plan.indoors && !p.moving ? 0.8 : 1;
            drawFigure(ctx, x, y, size, outfitFor(person, p.plan, p.weather, biome), SKINS[Math.floor(hash01(a.id, 53) * SKINS.length)], a.sex === "F" ? "#e58bd5" : "#4fd1c5");
            if (a.flags & (FLAG_SICK | FLAG_PREGNANT | FLAG_PLAYER | FLAG_FOUNDER)) {
              ctx.lineWidth = 1;
              ctx.strokeStyle = a.flags & FLAG_PLAYER ? "#ffffff" : a.flags & FLAG_SICK ? "#d9a441" : a.flags & FLAG_PREGNANT ? "#ffb3ec" : "#f5b84b";
              ctx.beginPath();
              ctx.arc(x, y, size * 1.5, 0, Math.PI * 2);
              ctx.stroke();
            }
            ctx.globalAlpha = 1;
            if (hero) labels.push({ x, y: y - size, name: a.name, d: (x - focusX) ** 2 + (y - focusY) ** 2 });
            continue;
          }
          ctx.globalAlpha = p.plan?.asleep ? 0.4 : p.plan?.indoors && !p.moving ? 0.72 : 1; // people indoors are dimmer
          ctx.beginPath();
          ctx.arc(x, y, stage === "baby" ? r * 0.6 : stage === "child" ? r * 0.8 : r, 0, Math.PI * 2);
          ctx.fillStyle = stage === "elder" ? "#c9d1dc" : a.sex === "F" ? "#e58bd5" : "#4fd1c5";
          ctx.fill();
          if (a.flags & (FLAG_SICK | FLAG_PREGNANT | FLAG_PLAYER | FLAG_FOUNDER) && c.z >= 2) {
            ctx.lineWidth = 1;
            ctx.strokeStyle = a.flags & FLAG_PLAYER ? "#ffffff" : a.flags & FLAG_SICK ? "#d9a441" : a.flags & FLAG_PREGNANT ? "#ffb3ec" : "#f5b84b";
            ctx.stroke();
          }
          ctx.globalAlpha = 1;
          if (hero) labels.push({ x, y, name: a.name, d: (x - focusX) ** 2 + (y - focusY) ** 2 });
        }
      }

      if (sky && !reducedMotion) {
        sky.drawPrecipitation(ctx, W, H, view, elapsed, c.z);
        sky.drawLightning(ctx, W, H, ts);
      }

      // settlements
      ctx.font = "600 12px var(--font-geist-sans), system-ui";
      ctx.textAlign = "center";
      const taken: { x: number; y: number }[] = [];
      for (const s of geo?.settlements ?? []) {
        const x = sx(s.x);
        const y = sy(s.y);
        if (c.z < 2.5) {
          ctx.beginPath();
          ctx.arc(x, y, 3 + Math.sqrt(s.pop) * 0.6, 0, Math.PI * 2);
          ctx.fillStyle = "rgba(79, 209, 197, 0.35)";
          ctx.fill();
          ctx.strokeStyle = "#4fd1c5";
          ctx.stroke();
        }
        ctx.fillStyle = "rgba(230, 236, 245, 0.9)";
        ctx.fillText(`${s.name} · ${s.pop}`, x, y - Math.max(10, c.z * 9));
        taken.push({ x, y: y - Math.max(10, c.z * 9) });
      }

      // people have names: the hero introduces a few of them
      if (labels.length) {
        ctx.font = "500 11px var(--font-geist-sans), system-ui";
        ctx.fillStyle = "rgba(230, 236, 245, 0.85)";
        const shown = taken.length;
        for (const l of labels.sort((a, b) => a.d - b.d)) {
          if (taken.length - shown === 5) break;
          const y = l.y - r - 5;
          if (taken.some((o) => Math.abs(o.x - l.x) < 74 && Math.abs(o.y - y) < 15)) continue; // no overlapping names
          taken.push({ x: l.x, y });
          ctx.fillText(l.name, l.x, y);
        }
      }

      // selection ring
      if (selected) {
        const p = positionOf(selected, tf);
        ctx.beginPath();
        ctx.arc(sx(p.x), sy(p.y), r + 5, 0, Math.PI * 2);
        ctx.strokeStyle = "#f5b84b";
        ctx.lineWidth = 2;
        ctx.stroke();
      }
    };
    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, [agents, geo, groups, hero, idx, now?.tick, positionOf, seed, selected, settlementById, follow, stops]);

  // --- interaction ------------------------------------------------------------------
  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const moved = useRef(0);
  const pinch = useRef<number | null>(null);

  const zoomAt = (factor: number, px: number, py: number) => {
    const wrap = wrapRef.current!;
    const c = cam.current;
    const W = wrap.clientWidth;
    const H = wrap.clientHeight;
    const wx = (px - W / 2) / c.z + c.x;
    const wy = (py - H / 2) / c.z + c.y;
    const z = Math.max(0.6, Math.min(40, c.z * factor));
    c.x = wx - (px - W / 2) / z;
    c.y = wy - (py - H / 2) / z;
    c.z = z;
  };

  useEffect(() => {
    const el = canvasRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      zoomAt(Math.exp(-e.deltaY * 0.0015), e.clientX - rect.left, e.clientY - rect.top);
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, []);

  const pick = (px: number, py: number) => {
    const wrap = wrapRef.current!;
    const c = cam.current;
    const tf = currentTick() ?? now?.tick ?? 0;
    let best: Agent | null = null;
    let bd = 12 * 12;
    for (const a of agents) {
      const p = positionOf(a, tf);
      const x = (p.x - c.x) * c.z + wrap.clientWidth / 2;
      const y = (p.y - c.y) * c.z + wrap.clientHeight / 2;
      const d = (x - px) ** 2 + (y - py) ** 2;
      if (d < bd) {
        bd = d;
        best = a;
      }
    }
    setSelected(best);
    if (!best) setFollow(false);
  };

  const onPointerDown = (e: React.PointerEvent) => {
    (e.target as Element).setPointerCapture(e.pointerId);
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    moved.current = 0;
  };
  const onPointerMove = (e: React.PointerEvent) => {
    const prev = pointers.current.get(e.pointerId);
    if (!prev) return;
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.current.size === 2) {
      const [a, b] = [...pointers.current.values()];
      const dist = Math.hypot(a.x - b.x, a.y - b.y);
      if (pinch.current) {
        const rect = canvasRef.current!.getBoundingClientRect();
        zoomAt(dist / pinch.current, (a.x + b.x) / 2 - rect.left, (a.y + b.y) / 2 - rect.top);
      }
      pinch.current = dist;
      moved.current += 10;
      return;
    }
    const dx = e.clientX - prev.x;
    const dy = e.clientY - prev.y;
    moved.current += Math.abs(dx) + Math.abs(dy);
    cam.current.x -= dx / cam.current.z;
    cam.current.y -= dy / cam.current.z;
    if (moved.current > 4) setFollow(false);
  };
  const onPointerUp = (e: React.PointerEvent) => {
    pointers.current.delete(e.pointerId);
    if (pointers.current.size < 2) pinch.current = null;
    if (moved.current < 5) {
      const rect = canvasRef.current!.getBoundingClientRect();
      pick(e.clientX - rect.left, e.clientY - rect.top);
    }
  };

  const matches = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (q.length < 2) return [];
    return agents.filter((a) => a.name.toLowerCase().includes(q)).slice(0, 8);
  }, [agents, query]);

  const error = loadFailed || failing ? "Lost contact with EON. Retrying…" : null;

  if (hero) {
    return (
      <div ref={wrapRef} aria-hidden className={`absolute inset-0 transition-opacity duration-1000 ${ready ? "opacity-100" : "opacity-0"}`}>
        <canvas ref={canvasRef} className="absolute inset-0" />
        <div className="hero-scrim absolute inset-0" />
        {stop && (
          <div className="tag absolute left-4 top-4 bg-bg/70">
            <span className="pulse-dot" /> Live · {stop.name} · {stop.pop === 1 ? "1 soul" : `${stop.pop} souls`}
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="relative h-[calc(100dvh-90px)] w-full overflow-hidden sm:h-[calc(100dvh-57px)]" ref={wrapRef}>
      <canvas
        ref={canvasRef}
        className="absolute inset-0 touch-none cursor-grab active:cursor-grabbing"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        aria-label="Map of EON"
        role="img"
      />

      <div className="absolute right-3 top-3">
        <WorldClock />
      </div>

      <div className="pointer-events-none absolute left-3 top-3 flex flex-col gap-2">
        <div className="panel pointer-events-auto px-3 py-2 text-sm">
          {now?.genesis ? (
            <span className="text-ink-2">
              {agents.length} alive · {geo?.settlements.length ?? 0} {geo?.settlements.length === 1 ? "settlement" : "settlements"}
            </span>
          ) : now ? (
            <span className="text-ink-3">The void: EON awaits its Creator.</span>
          ) : (
            <span className="text-ink-3">Connecting to EON…</span>
          )}
        </div>
        <div className="pointer-events-auto w-44 sm:w-64">
          <input
            className="input"
            placeholder="Find an agent…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Find an agent by name"
          />
          {matches.length > 0 && (
            <ul className="panel mt-1 max-h-64 overflow-auto py-1 text-sm">
              {matches.map((a) => (
                <li key={a.id}>
                  <button
                    className="w-full px-3 py-1.5 text-left hover:bg-bg-2"
                    onClick={() => {
                      setSelected(a);
                      setFollow(true);
                      cam.current.z = Math.max(cam.current.z, 8);
                      setQuery("");
                    }}
                  >
                    {a.name} <span className="text-ink-3">· {a.job}</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        {error && <div className="panel px-3 py-2 text-xs text-sick">{error}</div>}
      </div>

      <div className="absolute bottom-3 left-3 hidden gap-3 rounded-lg bg-bg/70 px-3 py-2 text-[11px] text-ink-2 sm:flex">
        <span><span className="text-love">●</span> female</span>
        <span><span className="text-life">●</span> male</span>
        <span><span className="text-ink-2">●</span> elder</span>
        <span><span className="text-sick">○</span> sick</span>
        <span><span className="text-god">○</span> founder</span>
        <span>○ human soul</span>
      </div>

      {selected && (
        <div className="panel absolute bottom-3 right-3 w-72 p-4 text-sm">
          <div className="flex items-start justify-between gap-2">
            <div>
              <div className="font-semibold">{selected.name}</div>
              <div className="text-ink-2">
                <LiveAge birthTick={selected.birth} /> · {selected.job} · {settlementById.get(selected.settlement)?.name}
              </div>
              {settlementById.get(selected.settlement) && (
                <div className="mt-1 text-xs text-ink-3">
                  <LiveActivity person={selected} place={settlementById.get(selected.settlement)!} />
                </div>
              )}
            </div>
            <button onClick={() => { setSelected(null); setFollow(false); }} className="text-ink-3 hover:text-ink" aria-label="Close">
              ✕
            </button>
          </div>
          <div className="mt-2 flex flex-wrap gap-1">
            {selected.flags & FLAG_FOUNDER ? <span className="tag text-god">founder</span> : null}
            {selected.flags & FLAG_PREGNANT ? <span className="tag text-love">expecting</span> : null}
            {selected.flags & FLAG_SICK ? <span className="tag text-sick">ill</span> : null}
            {selected.partner ? <span className="tag">partnered</span> : null}
          </div>
          <div className="mt-3 flex gap-2">
            <button className={`btn ${follow ? "btn-god" : "btn-ghost"} flex-1`} onClick={() => setFollow((f) => !f)}>
              {follow ? "Following" : "Follow"}
            </button>
            <Link href={`/agents/${selected.id}`} className="btn btn-life flex-1">
              Life story
            </Link>
          </div>
        </div>
      )}
    </div>
  );
}

export function HeroWorld() {
  return <WorldMap variant="hero" />;
}
