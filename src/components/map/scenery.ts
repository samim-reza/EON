/**
 * What the map draws on top of the terrain so the land looks the way it really is: the woods a
 * village has left, the stumps and the scar of a fire, flood water on the fields, smoke from
 * the chimneys, boats on the sea and the animals themselves. Everything is drawn from numbers
 * the world already keeps, so nothing here is decoration only.
 */
import type { Creature, Grove } from "@/shared/nature";

type Ctx = CanvasRenderingContext2D;
type Project = (v: number) => number;

const TREE_GREEN = ["#3f6b3a", "#365f33", "#2f5a34"];
const TREE_AUTUMN = ["#b9772c", "#c48a2e", "#9c5f2a"];

/** The village's woods. `autumn` is 0 to 1; conifers and palms stay green. `bare` is deep winter. */
export function drawGrove(ctx: Ctx, grove: Grove, sx: Project, sy: Project, z: number, autumn: number, bare: number, charred: number, W: number, H: number) {
  const unit = Math.max(1.2, z * 0.55);
  // Stumps first, so the trees that stand overlap them.
  if (z >= 3.2) {
    ctx.fillStyle = charred > 0.05 ? `rgba(28, 22, 18, ${0.55 + 0.4 * charred})` : "rgba(196, 170, 128, 0.85)";
    for (const s of grove.stumps) {
      const x = sx(s.x);
      const y = sy(s.y);
      if (x < -6 || y < -6 || x > W + 6 || y > H + 6) continue;
      ctx.beginPath();
      ctx.arc(x, y, Math.max(0.9, unit * 0.28), 0, Math.PI * 2);
      ctx.fill();
    }
  }
  grove.trees.forEach((t, i) => {
    const x = sx(t.x);
    const y = sy(t.y);
    const r = unit * t.size;
    if (x < -r * 2 || y < -r * 2 || x > W + r * 2 || y > H + r * 2) return;
    ctx.fillStyle = "rgba(0, 0, 0, 0.26)";
    ctx.beginPath();
    ctx.ellipse(x + r * 0.45, y + r * 0.5, r, r * 0.7, 0, 0, Math.PI * 2);
    ctx.fill();
    if (t.shape === "conifer") {
      ctx.fillStyle = TREE_GREEN[(i + 1) % 3];
      ctx.beginPath();
      ctx.moveTo(x, y - r * 1.35);
      ctx.lineTo(x + r * 0.95, y + r * 0.8);
      ctx.lineTo(x - r * 0.95, y + r * 0.8);
      ctx.closePath();
      ctx.fill();
      return;
    }
    if (t.shape === "palm") {
      ctx.strokeStyle = "#4f7a3c";
      ctx.lineWidth = Math.max(1, r * 0.35);
      ctx.beginPath();
      for (let k = 0; k < 5; k++) {
        const a = (Math.PI * 2 * k) / 5 + i;
        ctx.moveTo(x, y);
        ctx.lineTo(x + Math.cos(a) * r * 1.2, y + Math.sin(a) * r * 1.2);
      }
      ctx.stroke();
      return;
    }
    // Leaves turn in autumn and fall in a hard winter, a few trees at a time.
    const turned = autumn > ((i * 37) % 100) / 100;
    const leafless = bare > ((i * 53) % 100) / 100;
    if (leafless) {
      ctx.strokeStyle = "rgba(74, 60, 48, 0.9)";
      ctx.lineWidth = Math.max(0.8, r * 0.22);
      ctx.beginPath();
      for (let k = 0; k < 4; k++) {
        const a = (Math.PI * k) / 2 + i;
        ctx.moveTo(x, y);
        ctx.lineTo(x + Math.cos(a) * r * 0.9, y + Math.sin(a) * r * 0.9);
      }
      ctx.stroke();
      return;
    }
    ctx.fillStyle = turned ? TREE_AUTUMN[i % 3] : TREE_GREEN[i % 3];
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = "rgba(255, 255, 255, 0.13)";
    ctx.beginPath();
    ctx.arc(x - r * 0.28, y - r * 0.3, r * 0.55, 0, Math.PI * 2);
    ctx.fill();
  });
}

/** Burnt ground where the woods caught fire, fading over two EON years as they grow back. */
export function drawBurn(ctx: Ctx, cx: number, cy: number, z: number, scar: number) {
  if (scar <= 0.02) return;
  const radius = 30 * z;
  const smudge = ctx.createRadialGradient(cx, cy, radius * 0.25, cx, cy, radius);
  smudge.addColorStop(0, "rgba(24, 18, 14, 0)");
  smudge.addColorStop(0.55, `rgba(24, 18, 14, ${0.34 * scar})`);
  smudge.addColorStop(1, "rgba(24, 18, 14, 0)");
  ctx.fillStyle = smudge;
  ctx.fillRect(cx - radius, cy - radius, radius * 2, radius * 2);
}

/** Flames and smoke at the places that are burning now. Positions are already on screen. */
export function drawFlames(ctx: Ctx, points: { x: number; y: number }[], z: number, ts: number) {
  const size = Math.max(3, z * 1.1);
  ctx.globalCompositeOperation = "lighter";
  points.forEach((p, i) => {
    const flicker = 0.65 + 0.35 * Math.sin(ts / 90 + i * 2.3);
    const glow = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, size * 2.2);
    glow.addColorStop(0, `rgba(255, 190, 80, ${0.85 * flicker})`);
    glow.addColorStop(0.45, `rgba(240, 96, 30, ${0.5 * flicker})`);
    glow.addColorStop(1, "rgba(240, 96, 30, 0)");
    ctx.fillStyle = glow;
    ctx.fillRect(p.x - size * 2.2, p.y - size * 2.2, size * 4.4, size * 4.4);
  });
  ctx.globalCompositeOperation = "source-over";
  points.forEach((p, i) => {
    if (i % 3) return;
    drawSmoke(ctx, p.x, p.y - size, size * 1.3, ts + i * 700, 0.5, "60, 56, 54");
  });
}

/** A thin plume rising and drifting downwind. `rgb` lets a house fire and a cooking fire differ. */
export function drawSmoke(ctx: Ctx, x: number, y: number, size: number, ts: number, strength: number, rgb = "214, 218, 224") {
  for (let k = 0; k < 4; k++) {
    const age = ((ts / 2600 + k / 4) % 1 + 1) % 1;
    ctx.fillStyle = `rgba(${rgb}, ${strength * 0.5 * (1 - age)})`;
    ctx.beginPath();
    ctx.arc(x + age * size * 1.6 + Math.sin(age * 5 + k) * size * 0.2, y - age * size * 3.2, size * (0.35 + age * 0.7), 0, Math.PI * 2);
    ctx.fill();
  }
}

/** Standing water over low ground after days of rain, with slow ripples. */
export function drawFlood(ctx: Ctx, x: number, y: number, radius: number, depth: number, ts: number) {
  ctx.fillStyle = `rgba(64, 118, 168, ${0.42 * depth})`;
  ctx.beginPath();
  ctx.ellipse(x, y, radius * 1.25, radius * 0.85, 0.35, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = `rgba(200, 226, 245, ${0.4 * depth})`;
  ctx.lineWidth = 1;
  for (let k = 0; k < 3; k++) {
    const phase = ((ts / 3200 + k / 3) % 1 + 1) % 1;
    ctx.globalAlpha = 1 - phase;
    ctx.beginPath();
    ctx.ellipse(x + Math.cos(k * 2.1) * radius * 0.4, y + Math.sin(k * 2.1) * radius * 0.3, radius * 0.5 * phase, radius * 0.32 * phase, 0.35, 0, Math.PI * 2);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

/** A small fishing boat seen from above: hull, a pale sail, and a faint wake. */
export function drawBoat(ctx: Ctx, x: number, y: number, size: number, heading: number) {
  const cos = Math.cos(heading);
  const sin = Math.sin(heading);
  ctx.strokeStyle = "rgba(235, 245, 255, 0.35)";
  ctx.lineWidth = Math.max(0.8, size * 0.18);
  ctx.beginPath();
  ctx.moveTo(x - cos * size * 1.2, y - sin * size * 1.2);
  ctx.lineTo(x - cos * size * 2.6, y - sin * size * 2.6);
  ctx.stroke();
  ctx.fillStyle = "#6b4a2f";
  ctx.beginPath();
  ctx.ellipse(x, y, size * 1.25, size * 0.5, heading, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#f3ecdc";
  ctx.beginPath();
  ctx.moveTo(x + cos * size * 0.5, y + sin * size * 0.5);
  ctx.lineTo(x - cos * size * 0.5 - sin * size * 0.7, y - sin * size * 0.5 + cos * size * 0.7);
  ctx.lineTo(x - cos * size * 0.5, y - sin * size * 0.5);
  ctx.closePath();
  ctx.fill();
}

export const CREATURE_COLOURS = { grazer: "#b08d57", hunter: "#2b2724", herd: "#efe7d6" };

/**
 * One animal seen from above, turned the way it is heading. From a distance it is a small body;
 * close up a deer has antlers, a wolf a tail, and the village's animals are rounder and paler.
 */
export function drawCreature(ctx: Ctx, a: Creature, x: number, y: number, unit: number) {
  const cos = Math.cos(a.heading);
  const sin = Math.sin(a.heading);
  if (a.kind === "bird") {
    const w = unit * 1.2;
    ctx.strokeStyle = "rgba(245, 247, 250, 0.85)";
    ctx.lineWidth = Math.max(0.8, unit * 0.32);
    ctx.beginPath();
    ctx.moveTo(x - w * cos + w * sin, y - w * sin - w * cos);
    ctx.lineTo(x, y);
    ctx.lineTo(x - w * cos - w * sin, y - w * sin + w * cos);
    ctx.stroke();
    return;
  }
  const u = unit * (a.kind === "grazer" ? 1 : a.kind === "hunter" ? 0.9 : 0.8);
  const long = a.kind === "herd" ? 0.95 : 1.15;
  const wide = a.kind === "herd" ? 0.7 : 0.55;
  ctx.fillStyle = "rgba(0, 0, 0, 0.28)";
  ctx.beginPath();
  ctx.ellipse(x + u * 0.25, y + u * 0.3, u * long, u * wide, a.heading, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = CREATURE_COLOURS[a.kind];
  ctx.beginPath();
  ctx.ellipse(x, y, u * long, u * wide, a.heading, 0, Math.PI * 2);
  ctx.fill();
  if (u < 1.8) return;
  const hx = x + cos * u * (long + 0.05);
  const hy = y + sin * u * (long + 0.05);
  ctx.beginPath();
  ctx.arc(hx, hy, u * 0.42, 0, Math.PI * 2);
  ctx.fill();
  if (u < 2.6) return;
  ctx.lineCap = "round";
  if (a.kind === "grazer") {
    // antlers or horns: two short strokes swept back from the head
    ctx.strokeStyle = "#e8dcc0";
    ctx.lineWidth = Math.max(0.8, u * 0.14);
    ctx.beginPath();
    for (const side of [1, -1]) {
      ctx.moveTo(hx, hy);
      ctx.lineTo(hx - cos * u * 0.35 - sin * side * u * 0.6, hy - sin * u * 0.35 + cos * side * u * 0.6);
    }
    ctx.stroke();
  } else if (a.kind === "hunter") {
    ctx.strokeStyle = CREATURE_COLOURS.hunter;
    ctx.lineWidth = Math.max(1, u * 0.24);
    ctx.beginPath();
    ctx.moveTo(x - cos * u * long, y - sin * u * long);
    ctx.lineTo(x - cos * u * (long + 0.8) + sin * u * 0.25, y - sin * u * (long + 0.8) - cos * u * 0.25);
    ctx.stroke();
  } else {
    ctx.fillStyle = "rgba(120, 96, 72, 0.55)"; // a darker patch on the back
    ctx.beginPath();
    ctx.arc(x - cos * u * 0.25, y - sin * u * 0.25, u * 0.3, 0, Math.PI * 2);
    ctx.fill();
  }
}

/**
 * Where a village's boats work: up to three spots of open water near it, found once from the
 * terrain. A village with no sea in reach has none.
 */
export function boatSpots(place: { x: number; y: number }, elevation: (x: number, y: number) => number): { x: number; y: number }[] {
  const spots: { x: number; y: number; angle: number }[] = [];
  for (let step = 0; step < 24 && spots.length < 3; step++) {
    const angle = (Math.PI * 2 * step) / 24;
    if (spots.some((s) => Math.abs(Math.atan2(Math.sin(angle - s.angle), Math.cos(angle - s.angle))) < 0.7)) continue;
    for (let radius = 8; radius <= 26; radius += 2) {
      const x = place.x + radius * Math.cos(angle);
      const y = place.y + radius * Math.sin(angle);
      const further = elevation(place.x + (radius + 5) * Math.cos(angle), place.y + (radius + 5) * Math.sin(angle));
      if (elevation(x, y) < 0.004 && further < 0.004) {
        spots.push({ x: place.x + (radius + 4) * Math.cos(angle), y: place.y + (radius + 4) * Math.sin(angle), angle });
        break;
      }
    }
  }
  return spots.map(({ x, y }) => ({ x, y }));
}
