/**
 * What the map draws on top of the terrain so the land looks the way it really is: the woods a
 * village has left, the stumps and the scar of a fire, flood water on the fields, smoke from
 * the chimneys, boats on the sea and the animals themselves. Everything is drawn from numbers
 * the world already keeps, so nothing here is decoration only.
 */
import { BIRD, GRAZER, HERD, HUNTER, type Grove } from "@/shared/nature";

type Ctx = CanvasRenderingContext2D;
type Project = (v: number) => number;

const TREE_GREEN = ["#3f6b3a", "#365f33", "#2f5a34"];
const TREE_AUTUMN = ["#b9772c", "#c48a2e", "#9c5f2a"];
const TAU = Math.PI * 2;
const ROUND = 0, CONIFER = 1, PALM = 2;

/** A village's woods packed into flat arrays, ready to be drawn many times a second. */
export type PackedGrove = {
  count: number;
  x: Float32Array;
  y: Float32Array;
  size: Float32Array;
  shape: number;
  stumps: { x: number; y: number }[];
};

export function packGrove(grove: Grove): PackedGrove {
  const count = grove.trees.length;
  const packed: PackedGrove = {
    count, x: new Float32Array(count), y: new Float32Array(count), size: new Float32Array(count),
    shape: grove.trees[0]?.shape === "conifer" ? CONIFER : grove.trees[0]?.shape === "palm" ? PALM : ROUND,
    stumps: grove.stumps,
  };
  grove.trees.forEach((t, i) => {
    packed.x[i] = t.x;
    packed.y[i] = t.y;
    packed.size[i] = t.size;
  });
  return packed;
}

/** One village's woods and how they look today. `autumn` and `bare` are 0 to 1; `charred` marks a recent fire. */
export type GroveView = { grove: PackedGrove; autumn: number; bare: number; charred: boolean };

type View = { x0: number; y0: number; x1: number; y1: number };

// A tree turns gold, or loses its leaves, when the season passes its own threshold: a few at a time.
const turned = (i: number, autumn: number) => autumn > ((i * 37) % 100) / 100;
const leafless = (i: number, bare: number) => bare > ((i * 53) % 100) / 100;

// Trees are sorted into colour buckets once per frame; each bucket is then one path and one fill.
const GREEN = 0, AUTUMN = 3, BARE = 6, PINE = 7, PALMS = 10, BUCKETS = 11;
const bucketData: Float32Array[] = Array.from({ length: BUCKETS }, () => new Float32Array(1024));
const bucketCount = new Int32Array(BUCKETS);

function intoBucket(b: number, x: number, y: number, r: number, i: number) {
  let buf = bucketData[b];
  const at = bucketCount[b] * 4;
  if (at + 4 > buf.length) {
    const bigger = new Float32Array(buf.length * 2);
    bigger.set(buf);
    bucketData[b] = buf = bigger;
  }
  buf[at] = x;
  buf[at + 1] = y;
  buf[at + 2] = r;
  buf[at + 3] = i;
  bucketCount[b]++;
}

/**
 * Draws every wood on screen in a handful of canvas calls. Each tree is looked at once and put in
 * the bucket for its colour; a bucket is one path and one fill. A canvas is slow per call, not per
 * shape, so two hundred villages cost about as much as one.
 */
export function drawGroves(ctx: Ctx, views: readonly GroveView[], n: number, sx: Project, sy: Project, z: number, view: View) {
  if (!n) return;
  const unit = Math.max(1.2, z * 0.55);
  const detail = unit >= 2; // shadows and highlights only once a tree is more than a dot
  const x0 = view.x0 - 3, x1 = view.x1 + 3, y0 = view.y0 - 3, y1 = view.y1 + 3;

  // Stumps first, so the trees that stand overlap them.
  if (z >= 3.2) {
    const r = Math.max(0.9, unit * 0.28);
    for (const burnt of [false, true]) {
      let any = false;
      ctx.beginPath();
      for (let v = 0; v < n; v++) {
        if (views[v].charred !== burnt) continue;
        for (const s of views[v].grove.stumps) {
          if (s.x < x0 || s.x > x1 || s.y < y0 || s.y > y1) continue;
          const x = sx(s.x);
          const y = sy(s.y);
          ctx.moveTo(x + r, y);
          ctx.arc(x, y, r, 0, TAU);
          any = true;
        }
      }
      if (any) {
        ctx.fillStyle = burnt ? "rgba(28, 22, 18, 0.8)" : "rgba(196, 170, 128, 0.85)";
        ctx.fill();
      }
    }
  }

  bucketCount.fill(0);
  for (let v = 0; v < n; v++) {
    const { grove: g, autumn, bare } = views[v];
    for (let i = 0; i < g.count; i++) {
      const wx = g.x[i];
      const wy = g.y[i];
      if (wx < x0 || wx > x1 || wy < y0 || wy > y1) continue;
      const bucket = g.shape === CONIFER ? PINE + ((i + 1) % 3)
        : g.shape === PALM ? PALMS
          : leafless(i, bare) ? BARE
            : (turned(i, autumn) ? AUTUMN : GREEN) + (i % 3);
      intoBucket(bucket, sx(wx), sy(wy), unit * g.size[i], i);
    }
  }

  if (detail) {
    ctx.beginPath();
    for (let b = 0; b < BUCKETS; b++) {
      const buf = bucketData[b];
      for (let k = 0, end = bucketCount[b] * 4; k < end; k += 4) {
        const r = buf[k + 2];
        ctx.moveTo(buf[k] + r * 1.45, buf[k + 1] + r * 0.5);
        ctx.ellipse(buf[k] + r * 0.45, buf[k + 1] + r * 0.5, r, r * 0.7, 0, 0, TAU);
      }
    }
    ctx.fillStyle = "rgba(0, 0, 0, 0.26)";
    ctx.fill();
  }

  // Leafy trees: three greens and three autumn colours.
  for (let b = GREEN; b < BARE; b++) {
    if (!bucketCount[b]) continue;
    const buf = bucketData[b];
    ctx.beginPath();
    for (let k = 0, end = bucketCount[b] * 4; k < end; k += 4) {
      ctx.moveTo(buf[k] + buf[k + 2], buf[k + 1]);
      ctx.arc(buf[k], buf[k + 1], buf[k + 2], 0, TAU);
    }
    ctx.fillStyle = b < AUTUMN ? TREE_GREEN[b - GREEN] : TREE_AUTUMN[b - AUTUMN];
    ctx.fill();
  }
  // The light on their crowns.
  if (detail) {
    let any = false;
    ctx.beginPath();
    for (let b = GREEN; b < BARE; b++) {
      const buf = bucketData[b];
      for (let k = 0, end = bucketCount[b] * 4; k < end; k += 4) {
        const r = buf[k + 2] * 0.55;
        const x = buf[k] - buf[k + 2] * 0.28;
        const y = buf[k + 1] - buf[k + 2] * 0.3;
        ctx.moveTo(x + r, y);
        ctx.arc(x, y, r, 0, TAU);
        any = true;
      }
    }
    if (any) {
      ctx.fillStyle = "rgba(255, 255, 255, 0.13)";
      ctx.fill();
    }
  }
  // Bare branches in a hard winter.
  if (bucketCount[BARE]) {
    const buf = bucketData[BARE];
    ctx.beginPath();
    for (let k = 0, end = bucketCount[BARE] * 4; k < end; k += 4) {
      for (let spoke = 0; spoke < 4; spoke++) {
        const a = (Math.PI * spoke) / 2 + buf[k + 3];
        ctx.moveTo(buf[k], buf[k + 1]);
        ctx.lineTo(buf[k] + Math.cos(a) * buf[k + 2] * 0.9, buf[k + 1] + Math.sin(a) * buf[k + 2] * 0.9);
      }
    }
    ctx.strokeStyle = "rgba(74, 60, 48, 0.9)";
    ctx.lineWidth = Math.max(0.8, unit * 0.22);
    ctx.stroke();
  }
  // Conifers stay green all year.
  for (let b = PINE; b < PALMS; b++) {
    if (!bucketCount[b]) continue;
    const buf = bucketData[b];
    ctx.beginPath();
    for (let k = 0, end = bucketCount[b] * 4; k < end; k += 4) {
      const r = buf[k + 2];
      ctx.moveTo(buf[k], buf[k + 1] - r * 1.35);
      ctx.lineTo(buf[k] + r * 0.95, buf[k + 1] + r * 0.8);
      ctx.lineTo(buf[k] - r * 0.95, buf[k + 1] + r * 0.8);
      ctx.closePath();
    }
    ctx.fillStyle = TREE_GREEN[b - PINE];
    ctx.fill();
  }
  if (bucketCount[PALMS]) {
    const buf = bucketData[PALMS];
    ctx.beginPath();
    for (let k = 0, end = bucketCount[PALMS] * 4; k < end; k += 4) {
      for (let frond = 0; frond < 5; frond++) {
        const a = (TAU * frond) / 5 + buf[k + 3];
        ctx.moveTo(buf[k], buf[k + 1]);
        ctx.lineTo(buf[k] + Math.cos(a) * buf[k + 2] * 1.2, buf[k + 1] + Math.sin(a) * buf[k + 2] * 1.2);
      }
    }
    ctx.strokeStyle = "#4f7a3c";
    ctx.lineWidth = Math.max(1, unit * 0.35);
    ctx.stroke();
  }
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
const BODY = [CREATURE_COLOURS.grazer, CREATURE_COLOURS.hunter, CREATURE_COLOURS.herd];
const SCALE = [1, 0.9, 0.8]; // a wolf is a little smaller than a deer, a goat smaller still
const LONG = [1.15, 1.15, 0.95];
const WIDE = [0.55, 0.55, 0.7];

/**
 * Every animal on screen, gathered first and drawn together. Each kind is one path and one fill,
 * so the cost of a frame does not grow with the number of animals' canvas calls: eight calls at
 * most, however many herds are in view. Positions live in flat arrays that are reused every frame.
 */
export function createWildlifeBatch() {
  const data = [new Float32Array(768), new Float32Array(192), new Float32Array(384), new Float32Array(192)];
  const count = [0, 0, 0, 0];

  return {
    reset() {
      count[0] = count[1] = count[2] = count[3] = 0;
    },
    /** `x` and `y` are already on screen. */
    add(kind: number, x: number, y: number, heading: number) {
      let buf = data[kind];
      const at = count[kind] * 3;
      if (at + 3 > buf.length) {
        const bigger = new Float32Array(buf.length * 2);
        bigger.set(buf);
        data[kind] = buf = bigger;
      }
      buf[at] = x;
      buf[at + 1] = y;
      buf[at + 2] = heading;
      count[kind]++;
    },
    get total() {
      return count[0] + count[1] + count[2] + count[3];
    },
    draw(ctx: Ctx, unit: number) {
      const ground = [GRAZER, HUNTER, HERD];
      // shadows of everything that walks, in one go
      if (unit >= 1.5 && count[GRAZER] + count[HUNTER] + count[HERD] > 0) {
        ctx.beginPath();
        for (const kind of ground) {
          const u = unit * SCALE[kind];
          const buf = data[kind];
          for (let i = 0, n = count[kind] * 3; i < n; i += 3) {
            const h = buf[i + 2];
            const x = buf[i] + u * 0.25;
            const y = buf[i + 1] + u * 0.3;
            ctx.moveTo(x + Math.cos(h) * u * LONG[kind], y + Math.sin(h) * u * LONG[kind]);
            ctx.ellipse(x, y, u * LONG[kind], u * WIDE[kind], h, 0, TAU);
          }
        }
        ctx.fillStyle = "rgba(0, 0, 0, 0.28)";
        ctx.fill();
      }
      // bodies, and heads once they are big enough to see
      for (const kind of ground) {
        if (!count[kind]) continue;
        const u = unit * SCALE[kind];
        const long = LONG[kind];
        const buf = data[kind];
        ctx.beginPath();
        for (let i = 0, n = count[kind] * 3; i < n; i += 3) {
          const cos = Math.cos(buf[i + 2]);
          const sin = Math.sin(buf[i + 2]);
          ctx.moveTo(buf[i] + cos * u * long, buf[i + 1] + sin * u * long);
          ctx.ellipse(buf[i], buf[i + 1], u * long, u * WIDE[kind], buf[i + 2], 0, TAU);
          if (u >= 1.8) {
            const hx = buf[i] + cos * u * (long + 0.05);
            const hy = buf[i + 1] + sin * u * (long + 0.05);
            ctx.moveTo(hx + u * 0.42, hy);
            ctx.arc(hx, hy, u * 0.42, 0, TAU);
          }
        }
        ctx.fillStyle = BODY[kind];
        ctx.fill();
      }
      // close up: antlers on the deer, a tail on the wolf, a darker patch on the goat's back
      if (unit >= 2.6) {
        ctx.lineCap = "round";
        if (count[GRAZER]) {
          const u = unit;
          const buf = data[GRAZER];
          ctx.beginPath();
          for (let i = 0, n = count[GRAZER] * 3; i < n; i += 3) {
            const cos = Math.cos(buf[i + 2]);
            const sin = Math.sin(buf[i + 2]);
            const hx = buf[i] + cos * u * 1.2;
            const hy = buf[i + 1] + sin * u * 1.2;
            for (const side of [1, -1]) {
              ctx.moveTo(hx, hy);
              ctx.lineTo(hx - cos * u * 0.35 - sin * side * u * 0.6, hy - sin * u * 0.35 + cos * side * u * 0.6);
            }
          }
          ctx.strokeStyle = "#e8dcc0";
          ctx.lineWidth = Math.max(0.8, u * 0.14);
          ctx.stroke();
        }
        if (count[HUNTER]) {
          const u = unit * SCALE[HUNTER];
          const buf = data[HUNTER];
          ctx.beginPath();
          for (let i = 0, n = count[HUNTER] * 3; i < n; i += 3) {
            const cos = Math.cos(buf[i + 2]);
            const sin = Math.sin(buf[i + 2]);
            ctx.moveTo(buf[i] - cos * u * 1.15, buf[i + 1] - sin * u * 1.15);
            ctx.lineTo(buf[i] - cos * u * 1.95 + sin * u * 0.25, buf[i + 1] - sin * u * 1.95 - cos * u * 0.25);
          }
          ctx.strokeStyle = CREATURE_COLOURS.hunter;
          ctx.lineWidth = Math.max(1, u * 0.24);
          ctx.stroke();
        }
        if (count[HERD]) {
          const u = unit * SCALE[HERD];
          const buf = data[HERD];
          ctx.beginPath();
          for (let i = 0, n = count[HERD] * 3; i < n; i += 3) {
            const x = buf[i] - Math.cos(buf[i + 2]) * u * 0.25;
            const y = buf[i + 1] - Math.sin(buf[i + 2]) * u * 0.25;
            ctx.moveTo(x + u * 0.3, y);
            ctx.arc(x, y, u * 0.3, 0, TAU);
          }
          ctx.fillStyle = "rgba(120, 96, 72, 0.55)";
          ctx.fill();
        }
      }
      // birds: every flock as shallow Vs in one stroke
      if (count[BIRD]) {
        const w = unit * 1.2;
        const buf = data[BIRD];
        ctx.beginPath();
        for (let i = 0, n = count[BIRD] * 3; i < n; i += 3) {
          const cos = Math.cos(buf[i + 2]);
          const sin = Math.sin(buf[i + 2]);
          ctx.moveTo(buf[i] - w * cos + w * sin, buf[i + 1] - w * sin - w * cos);
          ctx.lineTo(buf[i], buf[i + 1]);
          ctx.lineTo(buf[i] - w * cos - w * sin, buf[i + 1] - w * sin + w * cos);
        }
        ctx.strokeStyle = "rgba(245, 247, 250, 0.85)";
        ctx.lineWidth = Math.max(0.8, unit * 0.32);
        ctx.stroke();
      }
    },
  };
}

export type WildlifeBatch = ReturnType<typeof createWildlifeBatch>;

/**
 * Chimney smoke for every home on screen. A puff fades as it rises, so puffs are sorted into four
 * strengths and each strength is one fill: four calls a frame, not four per house.
 */
export function createSmokeBatch() {
  let data = new Float32Array(256);
  let count = 0;
  return {
    reset() {
      count = 0;
    },
    /** `seed` staggers the houses, so they do not all puff together. */
    add(x: number, y: number, seed: number) {
      if (count * 3 + 3 > data.length) {
        const bigger = new Float32Array(data.length * 2);
        bigger.set(data);
        data = bigger;
      }
      data[count * 3] = x;
      data[count * 3 + 1] = y;
      data[count * 3 + 2] = seed;
      count++;
    },
    draw(ctx: Ctx, size: number, ts: number, strength: number) {
      if (!count) return;
      for (let band = 0; band < 4; band++) {
        ctx.beginPath();
        for (let i = 0, n = count * 3; i < n; i += 3) {
          for (let k = 0; k < 4; k++) {
            const age = (((ts + data[i + 2]) / 2600 + k / 4) % 1 + 1) % 1;
            if (Math.min(3, Math.floor(age * 4)) !== band) continue;
            const x = data[i] + age * size * 1.6 + Math.sin(age * 5 + k) * size * 0.2;
            const y = data[i + 1] - age * size * 3.2;
            const r = size * (0.35 + age * 0.7);
            ctx.moveTo(x + r, y);
            ctx.arc(x, y, r, 0, TAU);
          }
        }
        ctx.fillStyle = `rgba(214, 218, 224, ${(strength * 0.5 * (1 - (band + 0.5) / 4)).toFixed(3)})`;
        ctx.fill();
      }
    },
  };
}

const DOT_COLOURS = ["#e58bd5", "#4fd1c5", "#c9d1dc"]; // women, men, elders
const DOT_ALPHA = [1, 0.72, 0.4]; // out and about, indoors, asleep
const RING_COLOURS = ["#ffffff", "#d9a441", "#ffb3ec", "#f5b84b"]; // a player's soul, ill, expecting, a founder

/**
 * People seen from far enough away to be dots. A town of two thousand is nine fills and at most
 * twelve strokes: dots are sorted by colour and by how dim they are, and each sort is one path.
 */
export function createDotBatch() {
  const fills = Array.from({ length: 9 }, () => new Float32Array(192));
  const rings = Array.from({ length: 12 }, () => new Float32Array(96));
  const fillCount = new Int32Array(9);
  const ringCount = new Int32Array(12);
  const push = (list: Float32Array[], counts: Int32Array, b: number, x: number, y: number, r: number) => {
    let buf = list[b];
    const at = counts[b] * 3;
    if (at + 3 > buf.length) {
      const bigger = new Float32Array(buf.length * 2);
      bigger.set(buf);
      list[b] = buf = bigger;
    }
    buf[at] = x;
    buf[at + 1] = y;
    buf[at + 2] = r;
    counts[b]++;
  };
  const trace = (ctx: Ctx, buf: Float32Array, n: number) => {
    ctx.beginPath();
    for (let i = 0, end = n * 3; i < end; i += 3) {
      ctx.moveTo(buf[i] + buf[i + 2], buf[i + 1]);
      ctx.arc(buf[i], buf[i + 1], buf[i + 2], 0, TAU);
    }
  };
  return {
    reset() {
      fillCount.fill(0);
      ringCount.fill(0);
    },
    /** `colour` 0 to 2, `dim` 0 to 2, `ring` 0 to 3 or -1 for none. */
    add(x: number, y: number, r: number, colour: number, dim: number, ring: number) {
      push(fills, fillCount, colour * 3 + dim, x, y, r);
      if (ring >= 0) push(rings, ringCount, ring * 3 + dim, x, y, r);
    },
    draw(ctx: Ctx) {
      for (let b = 0; b < 9; b++) {
        if (!fillCount[b]) continue;
        ctx.globalAlpha = DOT_ALPHA[b % 3];
        trace(ctx, fills[b], fillCount[b]);
        ctx.fillStyle = DOT_COLOURS[Math.floor(b / 3)];
        ctx.fill();
      }
      ctx.lineWidth = 1;
      for (let b = 0; b < 12; b++) {
        if (!ringCount[b]) continue;
        ctx.globalAlpha = DOT_ALPHA[b % 3];
        trace(ctx, rings[b], ringCount[b]);
        ctx.strokeStyle = RING_COLOURS[Math.floor(b / 3)];
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
    },
  };
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
