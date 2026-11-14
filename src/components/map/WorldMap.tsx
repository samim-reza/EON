"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { LiveFeed } from "@/components/LiveFeed";
import { useMe } from "@/components/me";
import { RightNow } from "@/components/RightNow";
import { LiveActivity, LiveAge, WorldClock } from "@/components/WorldClock";
import { climateOf } from "@/components/local-climate";
import { currentTick, recentEvents, setFocus, setResidents, useRecentEvents, useWorld, type Resident } from "@/components/world-time";
import { localHour, NO_TUNING, seasonCurve, smooth, tideAt, weatherAt, yearFraction, type Weather } from "@/shared/climate";
import { buildingFor, outfitFor, planFor, slotInfo, SLOTS_PER_TICK, spotFor, type Outfit, type Plan } from "@/shared/daily-life";
import { burnScar, faunaOf, groveOf, landOf, SKIN_TONES, wildlifeAt, type CreatureKind, type Grove } from "@/shared/nature";
import { PLACE_NAMES, roadTier } from "@/shared/progress";
import { alongPath, buildRoads, linkSettlements, routeBetween } from "@/shared/roads";
import { TILE_UNITS } from "@/shared/terrain-pixels";
import { FLAG_FOUNDER, FLAG_PLAYER, FLAG_PREGNANT, FLAG_SICK, type Geo, type Roster } from "@/shared/types";
import { lifeStage } from "@/shared/time";
import { hash01, indexBuildings, makeTerrain, settleOnLand, WORLD_SIZE, type BuildingIndex } from "@/shared/world";
import { startAmbience, type Ambience } from "./ambience";
import { createAtmosphere, type Atmosphere } from "./atmosphere";
import { BuildingCard, CreatureCard, VillageCard, type Card, type Picked } from "./MapCard";
import { boatSpots, CREATURE_COLOURS, drawBoat, drawBurn, drawCreature, drawFlames, drawFlood, drawGrove, drawSmoke } from "./scenery";
import { loadTerrain, setTide, tilesFor, type TerrainMap } from "./terrain";

type Agent = {
  id: number; name: string; sex: "F" | "M"; birth: number; settlement: number; home: number | null;
  job: string; partner: number | null; flags: number;
  /** Skin tone 0 to 4, inherited from their parents. Missing on an old server: the map then picks one. */
  skin?: number;
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
    job: r.job[i], partner: r.partner[i], flags: r.flags[i], skin: r.skin?.[i],
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

const SKINS = SKIN_TONES;
const WILDLIFE_FROM_ZOOM = 2.2; // herds show once a village fills a good part of the screen
const SMOKE_FROM_ZOOM = 5;
const TURNING_LEAVES = new Set(["forest", "grassland", "mountain"]); // where the woods go gold in autumn

type Hit = { type: "agent"; agent: Agent } | Picked;
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

const ROOFS: Record<string, string> = {
  home: "#a8694e", temple: "#c9a44e", clinic: "#8fc4bd", farm: "#b08a4a", market: "#b5604a", school: "#8d7fb0",
  hall: "#74839b", smithy: "#5f5a58", mill: "#a79a84", library: "#7c6a94", factory: "#6a6f78", station: "#5b7a8a",
};

/** The colour of a field through the farming year, starting at the first month of spring. */
const CROPS = ["#7fa356", "#6f9c4a", "#5f9140", "#7f9c42", "#b4a54a", "#c9a948", "#c2a150", "#a98b55", "#8a7450", "#7d6a4f", "#75654e", "#7a6a50"];

/** Ploughed rows around a farm: the field that people walk out to. */
function drawField(ctx: CanvasRenderingContext2D, x: number, y: number, z: number, id: number, month: number) {
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(hash01(id, 31) * Math.PI);
  const width = 9 * z;
  const height = 6 * z;
  ctx.fillStyle = CROPS[month];
  ctx.fillRect(-width / 2, -height / 2, width, height);
  ctx.fillStyle = "rgba(60, 44, 26, 0.3)";
  const rows = Math.max(3, Math.min(9, Math.round(z)));
  for (let i = 0; i < rows; i++) ctx.fillRect(-width / 2, -height / 2 + ((i + 0.3) * height) / rows, width, (height / rows) * 0.34);
  ctx.restore();
}

const ROAD_LOOK: Record<number, { colour: string; width: number }> = {
  1: { colour: "rgba(206, 186, 140, 0.62)", width: 0.16 }, // a trodden footpath
  2: { colour: "rgba(150, 118, 80, 0.92)", width: 0.3 }, // a dirt road
  3: { colour: "rgba(128, 130, 136, 0.96)", width: 0.36 }, // paved
  4: { colour: "rgba(128, 130, 136, 0.96)", width: 0.4 },
};

export function WorldMap({ variant = "full" }: { variant?: "full" | "hero" }) {
  const hero = variant === "hero";
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const { now, failing } = useWorld();
  const [geo, setGeo] = useState<Geo | null>(null);
  const [agents, setAgents] = useState<Agent[]>([]);
  const [selected, setSelected] = useState<Agent | null>(null);
  const [picked, setPicked] = useState<Card | null>(null);
  const [sound, setSound] = useState(false);
  const ambience = useRef<Ambience | null>(null);
  const tipRef = useRef<HTMLDivElement>(null);
  const lastHover = useRef(0);
  const events = useRecentEvents();
  const [follow, setFollow] = useState(false);
  const [query, setQuery] = useState("");
  const [loadFailed, setLoadFailed] = useState(false);
  const [ready, setReady] = useState(false);
  const [stop, setStop] = useState<{ name: string; pop: number } | null>(null);
  const cam = useRef<Cam>({ x: 500, y: 500, z: 3 });
  const terrain = useRef<TerrainMap | null>(null);
  const atmosphere = useRef<{ seed: number; value: Atmosphere } | null>(null);
  const tune = useRef(NO_TUNING);
  const tier = useRef(1);
  const glow = useRef<HTMLCanvasElement | null>(null);
  const placed = useRef(false);
  const onScreen = useRef(true);
  const me = useMe();
  /** The draw loop reads who "you" are from here, so learning it does not restart the loop. */
  const meRef = useRef(me);
  useEffect(() => {
    meRef.current = me;
  }, [me]);
  const [note, setNote] = useState<string | null>(null);

  // --- data -------------------------------------------------------------------
  // People change the snapshot (the roster version); the land changes it slowly, so it is also asked for once an EON month.
  const requestedVersion = useRef("");
  useEffect(() => {
    if (!now?.genesis) return;
    const version = now.rosterVersion;
    const month = Math.floor(now.tick / 120);
    const key = `${version}?m=${month}`;
    if (key === requestedVersion.current) return;
    requestedVersion.current = key;
    fetch(`/api/pub/world/${key}`)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((data: { roster: Roster; geo: Geo }) => {
        setGeo(data.geo);
        setAgents(unpack(data.roster));
        setLoadFailed(false);
      })
      .catch(() => {
        requestedVersion.current = ""; // try again on the next poll
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

  useEffect(() => {
    const byPlace = new Map<number, Resident[]>();
    for (const a of agents) {
      const list = byPlace.get(a.settlement);
      if (list) list.push(a);
      else byPlace.set(a.settlement, [a]);
    }
    setResidents(byPlace);
  }, [agents]);

  const roads = useMemo(() => {
    if (!idx) return null;
    const places = [...idx.byId].map(([id, b]) => ({ id, x: b.x, y: b.y, group: b.settlement }));
    return buildRoads(places, new Map([...settlementById].map(([id, s]) => [id, { x: s.x, y: s.y }])));
  }, [idx, settlementById]);
  const links = useMemo(() => (geo ? linkSettlements(geo.settlements, makeTerrain(Number(geo.seed)).elevation) : []), [geo]);
  const elevation = useMemo(() => (geo ? makeTerrain(Number(geo.seed)).elevation : null), [geo]);

  /** Each village's buildings, so the scenery around it never has to search the whole world. */
  const buildingsBy = useMemo(() => {
    const by = new Map<number, { id: number; kind: string; x: number; y: number }[]>();
    for (const [id, b] of idx?.byId ?? []) {
      const list = by.get(b.settlement);
      if (list) list.push({ id, kind: b.kind, x: b.x, y: b.y });
      else by.set(b.settlement, [{ id, kind: b.kind, x: b.x, y: b.y }]);
    }
    return by;
  }, [idx]);

  /** The woods each village has left, and where its boats work. Both change only with a new snapshot. */
  const groves = useMemo(() => {
    const map = new Map<number, Grove>();
    if (!geo || !elevation) return map;
    for (const s of geo.settlements) {
      const land = landOf(s.land);
      if (!land) continue;
      const near = buildingsBy.get(s.id) ?? [];
      map.set(s.id, groveOf(s, land.woods, s.biome, (x, y) => elevation(x, y) >= 0.02 && !near.some((b) => Math.abs(b.x - x) < 2.4 && Math.abs(b.y - y) < 2.4)));
    }
    return map;
  }, [geo, elevation, buildingsBy]);
  const boats = useMemo(() => {
    const map = new Map<number, { x: number; y: number }[]>();
    if (!geo || !elevation) return map;
    for (const s of geo.settlements) if (s.land) map.set(s.id, boatSpots(s, elevation));
    return map;
  }, [geo, elevation]);
  const routes = useRef(new Map<string, { x: number; y: number }[]>());
  useEffect(() => routes.current.clear(), [roads]);

  /** Whose house is whose, for the map's labels. */
  const homeNames = useMemo(() => {
    const names = new Map<number, string>();
    for (const a of agents) if (a.home != null && !names.has(a.home)) names.set(a.home, `${a.name.split(" ").pop()} home`);
    return names;
  }, [agents]);

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
    tier.current = roadTier(now?.known);
  }, [now?.tune, now?.known]);

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
      const person = { id: a.id, job: a.job, ageYears: (tf - a.birth) / 1440, home: a.home };
      const has = (kind: string) => idx.civic.has(`${a.settlement}:${kind}`);
      const position = tf * SLOTS_PER_TICK;
      const slot = Math.floor(position);
      const planAt = (n: number) => {
        const info = slotInfo(n, home.x);
        return planFor(person, info.hour, info.day, info.month, weatherFor(a.settlement, home.x, home.y, n), has);
      };
      const plan = planAt(slot);
      const before = planAt(slot - 1);
      const weather = weatherFor(a.settlement, home.x, home.y, slot);
      const to = spotFor(a, plan, idx, home);
      if (before.place === plan.place) return { ...to, plan, moving: false, weather };
      const from = spotFor(a, before, idx, home);
      const start = buildingFor(a, before, idx);
      const end = buildingFor(a, plan, idx);
      let route: { x: number; y: number }[] = [];
      if (roads && start != null && end != null && start !== end) {
        const key = `${start}:${end}`;
        route = routes.current.get(key) ?? routeBetween(roads, start, end);
        routes.current.set(key, route);
      }
      // People keep to the path, rather than cutting straight across the land.
      const p = alongPath([from, ...route, to], ease(position - slot));
      return { x: p.x, y: p.y, plan, moving: true, weather };
    },
    [idx, roads, settlementById, weatherFor],
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
          setFocus({ id: at.id, name: at.name, x: at.x, y: at.y, biome: at.biome, land: at.land, pop: at.pop });
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
        setFocus({ id: nearest.id, name: nearest.name, x: nearest.x, y: nearest.y, biome: nearest.biome, land: nearest.land, pop: nearest.pop });
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

      // paths, fields and buildings
      if (roads && c.z >= 1.5) {
        const look = ROAD_LOOK[tier.current];
        ctx.lineCap = "round";
        ctx.strokeStyle = look.colour;
        ctx.lineWidth = Math.max(0.8, Math.min(7, c.z * look.width));
        ctx.beginPath();
        for (const [ax, ay, bendX, bendY, bx, by] of roads.segments) {
          if (Math.max(ax, bx) < view.x0 || Math.min(ax, bx) > view.x1 || Math.max(ay, by) < view.y0 || Math.min(ay, by) > view.y1) continue;
          ctx.moveTo(sx(ax), sy(ay));
          ctx.quadraticCurveTo(sx(bendX), sy(bendY), sx(bx), sy(by));
        }
        if (tier.current >= 2) {
          for (const [ax, ay, bx, by] of links) {
            ctx.moveTo(sx(ax), sy(ay));
            ctx.lineTo(sx(bx), sy(by));
          }
        }
        ctx.stroke();
        if (tier.current === 4) {
          ctx.strokeStyle = "rgba(40, 42, 48, 0.8)";
          ctx.lineWidth = Math.max(0.6, Math.min(2, c.z * 0.08));
          ctx.setLineDash([c.z * 0.5, c.z * 0.4]);
          ctx.beginPath();
          for (const [ax, ay, bx, by] of links) {
            ctx.moveTo(sx(ax), sy(ay));
            ctx.lineTo(sx(bx), sy(by));
          }
          ctx.stroke();
          ctx.setLineDash([]);
        }
      }
      if (idx && c.z >= 2.5) {
        const month = ((Math.floor(tf / 120) % 12) + 12) % 12;
        for (const [id, b] of idx.byId) {
          if (b.kind === "farm") drawField(ctx, sx(b.x), sy(b.y), c.z, id, month);
        }
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

      // the land as it really is: fire scars, flood water, the woods that are left, smoke and boats
      if (geo && c.z >= WILDLIFE_FROM_ZOOM) {
        const lately = recentEvents();
        const daylight = atmosphere.current?.value.daylight ?? 1;
        const leaves = Math.exp(-(((yearFraction(tf) - 0.66) / 0.085) ** 2));
        const winter = smooth(-0.1, -0.8, seasonCurve(tf));
        const slot = Math.floor(tf * SLOTS_PER_TICK);
        const reach = 62 * c.z;
        for (const s of geo.settlements) {
          const px = sx(s.x);
          const py = sy(s.y);
          if (px < -reach || py < -reach || px > W + reach || py > H + reach) continue;
          const weather = weatherFor(s.id, s.x, s.y, slot);
          const grove = groves.get(s.id);
          const fire = lately.find((e) => e.kind === "nature" && e.settlement === s.id && e.data.kind === "wildfire");
          const burnTick = Math.max(s.burn ?? -1, fire?.tick ?? -1);
          const scar = burnScar(burnTick < 0 ? null : burnTick, tf);
          drawBurn(ctx, px, py, c.z, scar);
          const flood = lately.find((e) => e.kind === "weather" && e.settlement === s.id && (e.data.kind === "flood" || e.data.kind === "surge") && tf - e.tick < 16);
          if (flood) {
            const farm = buildingsBy.get(s.id)?.find((b) => b.kind === "farm");
            drawFlood(ctx, sx(farm?.x ?? s.x + 6), sy(farm?.y ?? s.y + 4), 9 * c.z, Math.max(0.25, 1 - (tf - flood.tick) / 16), reducedMotion ? 0 : ts);
          }
          if (grove) {
            drawGrove(ctx, grove, sx, sy, c.z, TURNING_LEAVES.has(s.biome ?? "") ? leaves : 0, weather.temp < 3 ? winter : 0, scar, W, H);
            if (burnTick >= 0 && tf - burnTick < 8 && !reducedMotion) {
              drawFlames(ctx, grove.stumps.filter((_, i) => i % 3 === 0).slice(0, 14).map((p) => ({ x: sx(p.x), y: sy(p.y) })), c.z, ts);
            }
          }
          if (c.z >= SMOKE_FROM_ZOOM && !reducedMotion) {
            // A fire burns in every lived-in home when it is cold, and at breakfast and supper.
            const hour = localHour(tf, s.x);
            const cold = weather.temp < 10;
            if (cold || (hour >= 6 && hour < 8) || (hour >= 17 && hour < 20.5)) {
              const puff = Math.max(2, c.z * 0.45);
              for (const b of buildingsBy.get(s.id) ?? []) {
                if (b.kind === "home" && homeNames.has(b.id)) drawSmoke(ctx, sx(b.x), sy(b.y) - c.z * 0.5, puff, ts + b.id * 913, cold ? 0.7 : 0.45);
              }
            }
          }
          const spots = boats.get(s.id);
          if (spots?.length && c.z >= 3 && daylight > 0.3 && weather.wind < 45 && weather.kind !== "thunderstorm") {
            const out = Math.min(spots.length, 1 + Math.floor(s.pop / 25));
            for (let i = 0; i < out; i++) {
              const a = tf / 5 + i * 2;
              const b = tf / 7 + i;
              drawBoat(ctx, sx(spots[i].x + 2.5 * Math.sin(a)), sy(spots[i].y + 1.5 * Math.cos(b)), Math.max(2, c.z * 0.5), Math.atan2(-1.5 * Math.sin(b) / 7, 2.5 * Math.cos(a) / 5));
            }
          }
        }
      }

      // the wild: herds, the animals that hunt them, the village's own animals, and birds overhead
      if (geo && elevation && c.z >= WILDLIFE_FROM_ZOOM) {
        const daylight = atmosphere.current?.value.daylight ?? 1;
        const unit = Math.max(1.1, Math.min(4.2, c.z * 0.24));
        const reach = 60 * c.z;
        const onLand = (x: number, y: number) => elevation(x, y) >= 0.02;
        for (const s of geo.settlements) {
          const land = landOf(s.land);
          if (!land) continue;
          const px = sx(s.x);
          const py = sy(s.y);
          if (px < -reach || py < -reach || px > W + reach || py > H + reach) continue;
          for (const a of wildlifeAt(s, land, tf, daylight, onLand)) {
            const x = sx(a.x);
            const y = sy(a.y);
            if (x < -8 || y < -8 || x > W + 8 || y > H + 8) continue;
            drawCreature(ctx, a, x, y, unit);
          }
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
      const meNow = meRef.current;
      const marks: { x: number; y: number; you: boolean; name: string }[] = [];
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
          if (a.id === meNow.agent) marks.push({ x, y, you: true, name: "You" });
          else if (meNow.players.has(a.id)) marks.push({ x, y, you: false, name: meNow.players.get(a.id)! });
          const stage = lifeStage((tf - a.birth) / 1440);
          if (c.z >= FIGURES_FROM_ZOOM && p.plan && p.weather && !p.plan.asleep && stage !== "baby") {
            const size = Math.min(11, Math.max(4.6, c.z * 0.56)) * (stage === "child" ? 0.78 : 1);
            const person = { id: a.id, job: a.job, ageYears: (tf - a.birth) / 1440 };
            const biome = climateOf(seed, settlementById.get(a.settlement)?.x ?? 500, settlementById.get(a.settlement)?.y ?? 500).biome;
            ctx.globalAlpha = p.plan.indoors && !p.moving ? 0.8 : 1;
            drawFigure(ctx, x, y, size, outfitFor(person, p.plan, p.weather, biome), SKINS[a.skin ?? Math.floor(hash01(a.id, 53) * SKINS.length)] ?? SKINS[2], a.sex === "F" ? "#e58bd5" : "#4fd1c5");
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

      // You, always: a beating gold ring and your name for yourself. God sees every player by name.
      if (marks.length) {
        ctx.textAlign = "center";
        for (const m of marks) {
          const beat = m.you && !reducedMotion ? Math.sin(ts / 380) * 2.5 : 0;
          ctx.beginPath();
          ctx.arc(m.x, m.y, (m.you ? 11 : 8) + beat, 0, Math.PI * 2);
          ctx.strokeStyle = m.you ? "#f5b84b" : "rgba(255, 255, 255, 0.85)";
          ctx.lineWidth = m.you ? 2.5 : 1.5;
          ctx.stroke();
          ctx.font = m.you ? "700 12px var(--font-geist-sans), system-ui" : "600 11px var(--font-geist-sans), system-ui";
          ctx.lineJoin = "round";
          ctx.strokeStyle = "rgba(8, 14, 26, 0.75)";
          ctx.lineWidth = 3;
          ctx.strokeText(m.name, m.x, m.y - 17);
          ctx.fillStyle = m.you ? "#f5b84b" : "#ffffff";
          ctx.fillText(m.name, m.x, m.y - 17);
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

      // places have names too, once you are close enough to read them
      if (idx && c.z >= 4.5) {
        ctx.font = "500 10px var(--font-geist-sans), system-ui";
        ctx.lineJoin = "round";
        for (const [id, b] of idx.byId) {
          const name = b.kind === "home" ? (c.z >= 9 ? homeNames.get(id) : null) : PLACE_NAMES[b.kind];
          if (!name) continue;
          const x = sx(b.x);
          const y = sy(b.y) + Math.max(13, c.z * 1.5);
          if (x < -40 || y < -10 || x > W + 40 || y > H + 10) continue;
          if (taken.some((o) => Math.abs(o.x - x) < 62 && Math.abs(o.y - y) < 13)) continue;
          taken.push({ x, y });
          ctx.strokeStyle = "rgba(8, 14, 26, 0.62)";
          ctx.lineWidth = 3;
          ctx.strokeText(name, x, y);
          ctx.fillStyle = "rgba(240, 236, 224, 0.92)";
          ctx.fillText(name, x, y);
        }
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
  }, [agents, boats, buildingsBy, elevation, geo, groups, groves, hero, homeNames, idx, links, now?.tick, positionOf, roads, seed, selected, settlementById, follow, stops, weatherFor]);

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

  /** What is under the pointer: a person first, then an animal, a building, a village. */
  const hitAt = (px: number, py: number): Hit | null => {
    const wrap = wrapRef.current!;
    const c = cam.current;
    const tf = currentTick() ?? now?.tick ?? 0;
    const toX = (x: number) => (x - c.x) * c.z + wrap.clientWidth / 2;
    const toY = (y: number) => (y - c.y) * c.z + wrap.clientHeight / 2;
    let best: Agent | null = null;
    let bd = 12 * 12;
    for (const a of agents) {
      const p = positionOf(a, tf);
      const d = (toX(p.x) - px) ** 2 + (toY(p.y) - py) ** 2;
      if (d < bd) {
        bd = d;
        best = a;
      }
    }
    if (best) return { type: "agent", agent: best };
    const wx = (px - wrap.clientWidth / 2) / c.z + c.x;
    const wy = (py - wrap.clientHeight / 2) / c.z + c.y;
    if (geo && elevation && c.z >= WILDLIFE_FROM_ZOOM) {
      const daylight = atmosphere.current?.value.daylight ?? 1;
      let animal: { settlement: number; kind: CreatureKind } | null = null;
      let ad = 11 * 11;
      for (const s of geo.settlements) {
        const land = landOf(s.land);
        if (!land || Math.hypot(s.x - wx, s.y - wy) > 64) continue;
        for (const a of wildlifeAt(s, land, tf, daylight, (x, y) => elevation(x, y) >= 0.02)) {
          const d = (toX(a.x) - px) ** 2 + (toY(a.y) - py) ** 2;
          if (d < ad) {
            ad = d;
            animal = { settlement: s.id, kind: a.kind };
          }
        }
      }
      if (animal) return { type: "creature", ...animal };
    }
    if (idx && c.z >= 2.5) {
      for (const [id, b] of idx.byId) {
        const half = Math.max(2, c.z * (b.kind === "home" ? 0.9 : 1.6)) / 2 + 3;
        if (Math.abs(toX(b.x) - px) < half && Math.abs(toY(b.y) - py) < half) return { type: "building", id };
      }
    }
    for (const s of geo?.settlements ?? []) {
      const x = toX(s.x);
      const y = toY(s.y);
      const labelY = y - Math.max(10, c.z * 9) - 4;
      if (Math.hypot(px - x, py - y) < 14 || (Math.abs(px - x) < 12 + s.name.length * 3.8 && Math.abs(py - labelY) < 9)) return { type: "village", id: s.id };
    }
    return null;
  };

  /** A short name for what the pointer is over, shown beside it. */
  const nameOf = (hit: Hit): string => {
    if (hit.type === "agent") return hit.agent.name;
    if (hit.type === "village") return settlementById.get(hit.id)?.name ?? "A village";
    if (hit.type === "building") {
      const b = idx?.byId.get(hit.id);
      return b?.kind === "home" ? homeNames.get(hit.id) ?? "An empty home" : PLACE_NAMES[b?.kind ?? ""] ?? "A building";
    }
    const f = faunaOf(settlementById.get(hit.settlement)?.biome);
    const name = hit.kind === "grazer" ? f.grazer : hit.kind === "hunter" ? f.hunter : hit.kind === "herd" ? `the village ${f.herd}` : f.bird;
    return name.charAt(0).toUpperCase() + name.slice(1);
  };

  const pick = (px: number, py: number) => {
    const hit = hitAt(px, py);
    if (hit?.type === "agent") {
      setSelected(hit.agent);
      setPicked(null);
      return;
    }
    setSelected(null);
    setFollow(false);
    const tf = currentTick() ?? now?.tick ?? 0;
    if (hit?.type === "village") {
      const s = settlementById.get(hit.id);
      setPicked(s ? { ...hit, weather: weatherFor(s.id, s.x, s.y, Math.floor(tf * SLOTS_PER_TICK)) } : null);
    } else if (hit?.type === "building") {
      const b = idx?.byId.get(hit.id);
      const inside = !b ? [] : agents.filter((a) => {
        if (a.settlement !== b.settlement) return false;
        const p = positionOf(a, tf);
        return !p.moving && Math.abs(p.x - b.x) < 1.6 && Math.abs(p.y - b.y) < 1.6;
      });
      setPicked({ ...hit, inside: inside.map((a) => ({ id: a.id, name: a.name })) });
    } else {
      setPicked(hit);
    }
  };

  /** With a mouse, things that can be clicked say what they are before you click. */
  const hover = (e: React.PointerEvent) => {
    const tip = tipRef.current;
    const canvas = canvasRef.current;
    if (!tip || !canvas || e.pointerType !== "mouse") return;
    const nowMs = performance.now();
    if (nowMs - lastHover.current < 70) return;
    lastHover.current = nowMs;
    const rect = canvas.getBoundingClientRect();
    const hit = hitAt(e.clientX - rect.left, e.clientY - rect.top);
    canvas.style.cursor = hit ? "pointer" : "";
    tip.hidden = !hit;
    if (hit) {
      tip.textContent = nameOf(hit);
      tip.style.transform = `translate(${Math.round(e.clientX - rect.left + 14)}px, ${Math.round(e.clientY - rect.top + 12)}px)`;
    }
  };

  const onPointerDown = (e: React.PointerEvent) => {
    (e.target as Element).setPointerCapture(e.pointerId);
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    moved.current = 0;
  };
  const onPointerMove = (e: React.PointerEvent) => {
    const prev = pointers.current.get(e.pointerId);
    if (!prev) {
      hover(e);
      return;
    }
    if (tipRef.current) tipRef.current.hidden = true;
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

  // --- sound: the weather and the hour at the village in view ---------------------------
  const toggleSound = () => {
    if (ambience.current) {
      ambience.current.stop();
      ambience.current = null;
      setSound(false);
      return;
    }
    ambience.current = startAmbience(); // must start inside the click
    setSound(ambience.current !== null);
  };
  useEffect(() => {
    if (!sound || !geo?.settlements.length) return;
    const tune = () => {
      const c = cam.current;
      const tf = currentTick() ?? 0;
      const near = geo.settlements.reduce((best, s) => (Math.hypot(s.x - c.x, s.y - c.y) < Math.hypot(best.x - c.x, best.y - c.y) ? s : best));
      const weather = weatherFor(near.id, near.x, near.y, Math.floor(tf * SLOTS_PER_TICK));
      const fire = recentEvents().some((e) => e.kind === "nature" && e.settlement === near.id && e.data.kind === "wildfire" && tf - e.tick < 8);
      ambience.current?.set({ rain: weather.rain, wind: weather.wind, daylight: atmosphere.current?.value.daylight ?? 1, temp: weather.temp, fire });
    };
    tune();
    const id = window.setInterval(tune, 2000);
    return () => window.clearInterval(id);
  }, [sound, geo, weatherFor]);
  useEffect(() => () => ambience.current?.stop(), []);

  const goTo = (id: number) => {
    const s = settlementById.get(id);
    if (s) cam.current = { x: s.x, y: s.y, z: Math.max(cam.current.z, 7) };
  };

  const focusOn = useCallback((a: Agent) => {
    setSelected(a);
    setPicked(null);
    setFollow(true);
    cam.current.z = Math.max(cam.current.z, 9);
    setNote(null);
  }, []);
  const myPerson = me.agent != null ? agents.find((a) => a.id === me.agent) ?? null : null;

  // Links can point at someone: /world?agent=42, or /world?find=me for your own person.
  const linked = useRef(false);
  useEffect(() => {
    if (linked.current || hero || agents.length === 0) return;
    const params = new URLSearchParams(window.location.search);
    const find = params.get("find");
    const id = Number(params.get("agent"));
    if (find === "me" && !me.known) return; // still finding out who you are
    linked.current = true;
    // The address is outside React: act on it once, just after this render.
    queueMicrotask(() => {
      if (find === "me") {
        if (myPerson) focusOn(myPerson);
        else setNote(me.signedIn ? "You do not have a life yet. Ask for one on My life." : "Sign in to find yourself.");
      } else if (Number.isSafeInteger(id) && id > 0) {
        const a = agents.find((x) => x.id === id);
        if (a) focusOn(a);
        else setNote("That person is no longer alive.");
      }
    });
  }, [agents, hero, me, myPerson, focusOn]);

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

      <div ref={tipRef} hidden className="pointer-events-none absolute left-0 top-0 z-10 rounded bg-bg/85 px-2 py-0.5 text-xs text-ink shadow" />

      <div className="absolute right-3 top-3 flex flex-col items-end gap-2">
        <WorldClock />
        <button
          className="rounded-lg bg-bg/70 px-3 py-1.5 text-xs text-ink-2 hover:text-ink"
          onClick={toggleSound}
          aria-pressed={sound}
          title="The sound of the village in view: wind, rain, birds by day, insects at night"
        >
          {sound ? "♪ Sound on" : "♪ Sound off"}
        </button>
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
        {myPerson && (
          <button className="btn btn-god pointer-events-auto w-44 justify-center sm:w-64" onClick={() => focusOn(myPerson)}>
            Find me · {myPerson.name.split(" ")[0]}
          </button>
        )}
        {note && <div className="panel pointer-events-auto w-44 px-3 py-2 text-xs text-ink-2 sm:w-64">{note}</div>}
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
                      focusOn(a);
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
        <div className="panel pointer-events-auto hidden w-64 p-3 lg:block">
          <RightNow />
        </div>
        <div className="panel pointer-events-auto hidden max-h-56 w-64 overflow-auto px-3 py-2 lg:block">
          <h2 className="text-xs uppercase tracking-widest text-ink-3">Happening now</h2>
          <LiveFeed importance={1} limit={4} compact />
        </div>
      </div>

      <div className="absolute bottom-3 left-3 hidden max-w-[calc(100%-1.5rem)] flex-wrap gap-x-3 gap-y-1 rounded-lg bg-bg/70 px-3 py-2 text-[11px] text-ink-2 sm:flex">
        <span><span className="text-love">●</span> female</span>
        <span><span className="text-life">●</span> male</span>
        <span><span className="text-ink-2">●</span> elder</span>
        <span><span className="text-sick">○</span> sick</span>
        <span><span className="text-god">○</span> founder</span>
        <span>○ human soul</span>
        {geo?.settlements.some((s) => s.land) && (
          <>
            <span><span style={{ color: CREATURE_COLOURS.grazer }}>●</span> wild herds</span>
            <span><span style={{ color: "#6b625b" }}>●</span> hunters</span>
            <span><span style={{ color: CREATURE_COLOURS.herd }}>●</span> livestock</span>
          </>
        )}
        {myPerson && <span className="text-god">◎ you</span>}
      </div>

      {!selected && picked?.type === "village" && settlementById.get(picked.id) && (
        <VillageCard
          place={settlementById.get(picked.id)!}
          weather={picked.weather}
          events={[...events]}
          onGo={() => goTo(picked.id)}
          onClose={() => setPicked(null)}
        />
      )}
      {!selected && picked?.type === "creature" && settlementById.get(picked.settlement) && (
        <CreatureCard kind={picked.kind} place={settlementById.get(picked.settlement)!} onClose={() => setPicked(null)} />
      )}
      {!selected && picked?.type === "building" && idx?.byId.get(picked.id) && (
        <BuildingCard
          kind={idx.byId.get(picked.id)!.kind}
          name={homeNames.get(picked.id) ?? null}
          place={settlementById.get(idx.byId.get(picked.id)!.settlement)}
          residents={agents.filter((a) => a.home === picked.id)}
          inside={picked.inside}
          onPerson={(id) => {
            const a = agents.find((x) => x.id === id);
            if (a) focusOn(a);
          }}
          onClose={() => setPicked(null)}
        />
      )}

      {selected && (
        <div className="panel absolute bottom-3 right-3 w-72 p-4 text-sm">
          <div className="flex items-start justify-between gap-2">
            <div>
              <div className="font-semibold">
                {selected.name}
                {selected.id === me.agent && <span className="ml-1 text-god">(you)</span>}
              </div>
              {me.players.has(selected.id) && selected.id !== me.agent && (
                <div className="text-xs text-god">soul of {me.players.get(selected.id)}</div>
              )}
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
            {selected.id === me.agent ? (
              <Link href="/me" className="btn btn-life flex-1">
                My life
              </Link>
            ) : (
              <Link href={`/agents/${selected.id}`} className="btn btn-life flex-1">
                Life story
              </Link>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

export function HeroWorld() {
  return <WorldMap variant="hero" />;
}
