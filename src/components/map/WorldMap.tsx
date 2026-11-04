"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { FLAG_FOUNDER, FLAG_PLAYER, FLAG_PREGNANT, FLAG_SICK, type Geo, type NowState, type Roster } from "@/shared/types";
import { eonDate, formatAge, lifeStage, PHASES } from "@/shared/time";
import { indexBuildings, makeTerrain, placeFor, WORLD_SIZE, type BuildingIndex } from "@/shared/world";

type Agent = {
  id: number; name: string; sex: "F" | "M"; birth: number; settlement: number; home: number | null;
  job: string; partner: number | null; flags: number;
};

type Cam = { x: number; y: number; z: number }; // world-space centre, pixels per world unit

const TERRAIN_RES = 1; // world units per terrain pixel

const RAMP: [number, [number, number, number]][] = [
  [-0.6, [8, 16, 34]],
  [-0.2, [12, 30, 58]],
  [-0.02, [22, 52, 86]],
  [0.0, [74, 84, 72]],
  [0.05, [44, 78, 52]],
  [0.22, [34, 68, 44]],
  [0.4, [30, 56, 40]],
  [0.52, [66, 70, 60]],
  [0.65, [96, 98, 100]],
  [0.8, [150, 156, 162]],
];

function terrainColor(e: number): [number, number, number] {
  if (e <= RAMP[0][0]) return RAMP[0][1];
  for (let i = 1; i < RAMP.length; i++) {
    const [e1, c1] = RAMP[i];
    if (e <= e1) {
      const [e0, c0] = RAMP[i - 1];
      const t = (e - e0) / (e1 - e0);
      return [c0[0] + (c1[0] - c0[0]) * t, c0[1] + (c1[1] - c0[1]) * t, c0[2] + (c1[2] - c0[2]) * t];
    }
  }
  return RAMP[RAMP.length - 1][1];
}

function renderTerrain(seed: number): HTMLCanvasElement {
  const t = makeTerrain(seed);
  const n = WORLD_SIZE / TERRAIN_RES;
  const c = document.createElement("canvas");
  c.width = n;
  c.height = n;
  const ctx = c.getContext("2d")!;
  const img = ctx.createImageData(n, n);
  for (let py = 0; py < n; py++) {
    for (let px = 0; px < n; px++) {
      const e = t.elevation(px * TERRAIN_RES, py * TERRAIN_RES);
      const [r, g, b] = terrainColor(e);
      // cheap hill-shading from the slope toward the north-west light
      const shade = e > 0 ? 1 + Math.max(-0.18, Math.min(0.18, (e - t.elevation(px * TERRAIN_RES - 2, py * TERRAIN_RES - 2)) * 6)) : 1;
      const i = (py * n + px) * 4;
      img.data[i] = r * shade;
      img.data[i + 1] = g * shade;
      img.data[i + 2] = b * shade;
      img.data[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  return c;
}

function unpack(r: Roster): Agent[] {
  return r.id.map((id, i) => ({
    id, name: r.name[i], sex: r.sex[i], birth: r.birth[i], settlement: r.settlement[i], home: r.home[i],
    job: r.job[i], partner: r.partner[i], flags: r.flags[i],
  }));
}

const ease = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

export function WorldMap() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const [now, setNow] = useState<NowState | null>(null);
  const nowAt = useRef<number>(0);
  const [geo, setGeo] = useState<Geo | null>(null);
  const [agents, setAgents] = useState<Agent[]>([]);
  const [selected, setSelected] = useState<Agent | null>(null);
  const [follow, setFollow] = useState(false);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const cam = useRef<Cam>({ x: 500, y: 500, z: 3 });
  const terrain = useRef<HTMLCanvasElement | null>(null);
  const placed = useRef(false);

  // --- data -------------------------------------------------------------------
  const loadedVersion = useRef<number>(-1);
  const refresh = useCallback(async () => {
    try {
      const r = await fetch("/api/pub/now");
      if (!r.ok) throw new Error();
      const n: NowState = await r.json();
      nowAt.current = performance.now();
      setNow(n);
      if (n.genesis && n.rosterVersion !== loadedVersion.current) {
        const w = await fetch(`/api/pub/world/${n.rosterVersion}`);
        if (!w.ok) throw new Error();
        const data: { roster: Roster; geo: Geo } = await w.json();
        loadedVersion.current = data.roster.version;
        setGeo(data.geo);
        setAgents(unpack(data.roster));
      }
      setError(null);
    } catch {
      setError("Lost contact with EON — retrying…");
    }
  }, []);

  useEffect(() => {
    const first = setTimeout(refresh, 0);
    const id = setInterval(() => document.visibilityState === "visible" && refresh(), 30_000);
    return () => {
      clearTimeout(first);
      clearInterval(id);
    };
  }, [refresh]);

  const idx: BuildingIndex | null = useMemo(() => (geo ? indexBuildings(geo.buildings) : null), [geo]);
  const settlementById = useMemo(() => new Map((geo?.settlements ?? []).map((s) => [s.id, s])), [geo]);

  useEffect(() => {
    if (!geo) return;
    terrain.current = renderTerrain(Number(geo.seed));
    if (!placed.current && geo.settlements.length) {
      const s = geo.settlements[0];
      cam.current = { x: s.x, y: s.y, z: 7 };
      placed.current = true;
    }
  }, [geo]);

  // --- rendering ------------------------------------------------------------------
  const tickFloat = useCallback(() => {
    if (!now) return 0;
    if (now.paused) return now.tick;
    return now.tick + Math.min(1.5, (performance.now() - nowAt.current) / 60_000);
  }, [now]);

  const positionOf = useCallback(
    (a: Agent, tf: number) => {
      if (!idx) return { x: 0, y: 0 };
      const s = settlementById.get(a.settlement);
      const fallback = s ? { x: s.x, y: s.y } : { x: 500, y: 500 };
      const cur = Math.floor(tf);
      const ageYears = (tf - a.birth) / 1440;
      const base = { id: a.id, job: a.job, ageYears, home: a.home, settlement: a.settlement };
      const to = placeFor(base, ((cur % 4) + 4) % 4, idx, fallback);
      const from = placeFor(base, (((cur - 1) % 4) + 4) % 4, idx, fallback);
      const k = ease(Math.min(1, (tf - cur) / 0.45)); // commute during the first ~27 s of each tick
      return { x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k };
    },
    [idx, settlementById],
  );

  useEffect(() => {
    const canvas = canvasRef.current;
    const wrap = wrapRef.current;
    if (!canvas || !wrap) return;
    const ctx = canvas.getContext("2d")!;
    let raf = 0;
    let last = 0;
    const draw = (ts: number) => {
      raf = requestAnimationFrame(draw);
      if (ts - last < 33) return; // ~30 fps
      last = ts;
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      const W = wrap.clientWidth;
      const H = wrap.clientHeight;
      if (canvas.width !== W * dpr || canvas.height !== H * dpr) {
        canvas.width = W * dpr;
        canvas.height = H * dpr;
        canvas.style.width = `${W}px`;
        canvas.style.height = `${H}px`;
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const tf = tickFloat();
      const c = cam.current;
      if (follow && selected) {
        const p = positionOf(selected, tf);
        c.x += (p.x - c.x) * 0.15;
        c.y += (p.y - c.y) * 0.15;
      }
      const sx = (x: number) => (x - c.x) * c.z + W / 2;
      const sy = (y: number) => (y - c.y) * c.z + H / 2;

      ctx.fillStyle = "#070b14";
      ctx.fillRect(0, 0, W, H);
      if (terrain.current) {
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = "high";
        ctx.drawImage(terrain.current, sx(0), sy(0), WORLD_SIZE * c.z, WORLD_SIZE * c.z);
      }

      // buildings
      if (idx && c.z >= 2.5) {
        for (const [, b] of idx.byId) {
          const x = sx(b.x);
          const y = sy(b.y);
          if (x < -10 || y < -10 || x > W + 10 || y > H + 10) continue;
          const s = Math.max(2, c.z * (b.kind === "home" ? 0.9 : 1.6));
          ctx.fillStyle = b.kind === "home" ? "#6b5b4a" : b.kind === "temple" ? "#b8964a" : b.kind === "clinic" ? "#7aa8a3" : "#56657d";
          ctx.fillRect(x - s / 2, y - s / 2, s, s);
        }
      }

      // agents
      const r = Math.max(1.4, Math.min(5, c.z * 0.6));
      for (const a of agents) {
        const p = positionOf(a, tf);
        const x = sx(p.x);
        const y = sy(p.y);
        if (x < -5 || y < -5 || x > W + 5 || y > H + 5) continue;
        const stage = lifeStage((tf - a.birth) / 1440);
        ctx.beginPath();
        ctx.arc(x, y, stage === "baby" ? r * 0.6 : stage === "child" ? r * 0.8 : r, 0, Math.PI * 2);
        ctx.fillStyle = stage === "elder" ? "#c9d1dc" : a.sex === "F" ? "#e58bd5" : "#4fd1c5";
        ctx.fill();
        if (a.flags & (FLAG_SICK | FLAG_PREGNANT | FLAG_PLAYER | FLAG_FOUNDER) && c.z >= 2) {
          ctx.lineWidth = 1;
          ctx.strokeStyle = a.flags & FLAG_PLAYER ? "#ffffff" : a.flags & FLAG_SICK ? "#d9a441" : a.flags & FLAG_PREGNANT ? "#ffb3ec" : "#f5b84b";
          ctx.stroke();
        }
      }

      // night
      const phase = ((Math.floor(tf) % 4) + 4) % 4;
      const dark = [0.08, 0, 0.22, 0.42][phase];
      if (dark) {
        ctx.fillStyle = `rgba(4, 8, 24, ${dark})`;
        ctx.fillRect(0, 0, W, H);
      }

      // settlements
      ctx.font = "600 12px var(--font-geist-sans), system-ui";
      ctx.textAlign = "center";
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
  }, [agents, geo, idx, positionOf, selected, follow, tickFloat]);

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
    const tf = tickFloat();
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

  const d = now ? eonDate(now.tick) : null;
  const tfNow = now?.tick ?? 0;

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

      <div className="pointer-events-none absolute left-3 top-3 flex flex-col gap-2">
        <div className="panel pointer-events-auto px-3 py-2 text-sm">
          {now?.genesis && d ? (
            <>
              <div className="font-mono">
                Year {d.year} · {d.monthName} {d.day}
              </div>
              <div className="text-xs text-ink-3">
                {PHASES[d.phase]} · {agents.length} alive · {geo?.settlements.length ?? 0} settlements
                {now.paused ? " · paused" : ""}
              </div>
            </>
          ) : now ? (
            <span className="text-ink-3">The void — EON awaits its Creator.</span>
          ) : (
            <span className="text-ink-3">Connecting to EON…</span>
          )}
        </div>
        <div className="pointer-events-auto w-64">
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
                {formatAge((tfNow - selected.birth) / 1440)} · {selected.job} · {settlementById.get(selected.settlement)?.name}
              </div>
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
