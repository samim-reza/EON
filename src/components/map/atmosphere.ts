import { climateAt, clamp01, moonAt, smooth, sunElevation, WEATHER_DRIFT, weatherAt, type Climate, type Moon, type Weather, type WeatherTuning } from "@/shared/climate";
import { makeTerrain } from "@/shared/world";

export type View = { x0: number; y0: number; x1: number; y1: number };

const GRID_X = 18; // weather is sampled coarsely: it changes over tens of map units, not pixels
const GRID_Y = 12;
const WIDTH = 104; // light and clouds are painted small, then scaled up smoothly by the GPU
const HEIGHT = 70;
const WEATHER_MS = 500;
const PAINT_MS = 120;
const MARGIN = 0.12; // painted a little beyond the view, so panning between updates shows no edge

/** Multiply-blend light: white by day, warm near the horizon, blue under the moon. */
export function skyLight(sun: number, moon: Moon, cloud: number): [number, number, number] {
  const day = smooth(-5, 9, sun);
  const moonlight = moon.light * smooth(-2, 14, moon.elevation) * (1 - 0.8 * cloud);
  const nightR = 0.27 + 0.14 * moonlight;
  const nightG = 0.31 + 0.17 * moonlight;
  const nightB = 0.48 + 0.2 * moonlight;
  const low = Math.exp(-(((sun - 2.5) / 7.5) ** 2)); // the golden hour
  const dim = 1 - 0.3 * cloud * day;
  return [
    (nightR + (1 - nightR) * day) * dim,
    (nightG + (1 - nightG) * day) * (1 - 0.17 * low) * dim,
    (nightB + (1 - nightB) * day) * (1 - 0.42 * low) * dim,
  ];
}

/** A soft cloud texture that tiles, so one small image can cover the sky. */
function cloudTexture(size: number) {
  const octave = (cells: number, seed: number) => {
    const lattice = new Float32Array(cells * cells);
    let h = seed;
    for (let i = 0; i < lattice.length; i++) {
      h = Math.imul(h ^ (h >>> 15), 0x2c1b3c6d) + 0x297a2d39;
      lattice[i] = ((h ^ (h >>> 14)) >>> 0) / 4294967296;
    }
    return (u: number, v: number) => {
      const x = u * cells;
      const y = v * cells;
      const x0 = Math.floor(x);
      const y0 = Math.floor(y);
      const fx = x - x0;
      const fy = y - y0;
      const a = fx * fx * (3 - 2 * fx);
      const b = fy * fy * (3 - 2 * fy);
      const at = (i: number, j: number) => lattice[((j % cells) * cells + (i % cells)) | 0];
      return (at(x0, y0) * (1 - a) + at(x0 + 1, y0) * a) * (1 - b) + (at(x0, y0 + 1) * (1 - a) + at(x0 + 1, y0 + 1) * a) * b;
    };
  };
  const layers = [octave(4, 11), octave(8, 23), octave(16, 37), octave(32, 53)];
  const fine = new Float32Array(size * size);
  const soft = new Float32Array(size * size); // large shapes only, for far-away views where fine detail would alias
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const u = x / size;
      const v = y / size;
      const broad = 0.5 * layers[0](u, v) + 0.27 * layers[1](u, v);
      fine[y * size + x] = broad + 0.15 * layers[2](u, v) + 0.08 * layers[3](u, v);
      soft[y * size + x] = broad;
    }
  }
  const normalise = (data: Float32Array) => {
    let low = 1;
    let high = 0;
    for (const n of data) {
      low = Math.min(low, n);
      high = Math.max(high, n);
    }
    for (let i = 0; i < data.length; i++) data[i] = (data[i] - low) / (high - low);
    return data;
  };
  return { fine: normalise(fine), soft: normalise(soft) };
}

type Drop = { x: number; y: number; speed: number; seed: number };

/**
 * Everything between the ground and the sky. Two tiny canvases carry the light and the clouds, and
 * are re-painted a few times a second; each frame just stretches them over the map, which is
 * nearly free. They are pinned to world coordinates, so panning stays smooth between re-paints.
 */
export function createAtmosphere(seed: number) {
  const terrain = makeTerrain(seed);
  const climates = new Map<number, Climate>();
  const climateFor = (x: number, y: number) => {
    const key = Math.round(x / 20) * 4096 + Math.round(y / 20);
    let c = climates.get(key);
    if (!c) {
      c = climateAt(seed, x, y, terrain.elevation(x, y));
      climates.set(key, c);
    }
    return c;
  };

  const texSize = 192;
  const textures = cloudTexture(texSize);
  const tex = (data: Float32Array, u: number, v: number) => {
    const x = ((Math.floor(u * texSize) % texSize) + texSize) % texSize;
    const y = ((Math.floor(v * texSize) % texSize) + texSize) % texSize;
    return data[y * texSize + x];
  };

  const make = () => {
    const canvas = document.createElement("canvas");
    canvas.width = WIDTH;
    canvas.height = HEIGHT;
    const ctx = canvas.getContext("2d")!;
    return { canvas, ctx, image: ctx.createImageData(WIDTH, HEIGHT) };
  };
  const light = make();
  const clouds = make();

  const size = (GRID_X + 1) * (GRID_Y + 1);
  const field = {
    cloud: new Float32Array(size), rain: new Float32Array(size), r: new Float32Array(size), g: new Float32Array(size), b: new Float32Array(size),
    snow: new Float32Array(size), fog: new Float32Array(size), sand: new Float32Array(size),
  };
  let wind = 12;
  let painted: View = { x0: 0, y0: 0, x1: 1, y1: 1 };
  let sampled: View | null = null;
  let lastWeather = -Infinity;
  let lastPaint = -Infinity;
  let storm = 0; // how much of the view is under a thunderstorm
  let flashAt = -Infinity;
  let nextFlash = 0;
  let flashX = 0.5;
  let flashY = 0.4;
  let daylight = 1;

  function sampleField(view: View, tf: number, tune: WeatherTuning) {
    const moonSample = moonAt(seed, tf, 35, 500);
    let windSum = 0;
    let stormCells = 0;
    let lightSum = 0;
    for (let j = 0; j <= GRID_Y; j++) {
      for (let i = 0; i <= GRID_X; i++) {
        const x = view.x0 + ((view.x1 - view.x0) * i) / GRID_X;
        const y = view.y0 + ((view.y1 - view.y0) * j) / GRID_Y;
        const c = climateFor(x, y);
        const w = weatherAt(seed, c, x, y, tf, tune);
        const k = j * (GRID_X + 1) + i;
        field.cloud[k] = w.cloud;
        field.rain[k] = w.rain;
        field.snow[k] = w.kind === "snow" || w.kind === "blizzard" ? 1 : w.kind === "sleet" ? 0.5 : 0;
        field.fog[k] = w.kind === "fog" ? 1 : 0;
        field.sand[k] = w.kind === "sandstorm" ? 1 : 0;
        const sun = sunElevation(tf, c.lat, x);
        const [r, g, b] = skyLight(sun, { ...moonSample, elevation: moonSample.elevation }, w.cloud);
        field.r[k] = r;
        field.g[k] = g;
        field.b[k] = b;
        lightSum += smooth(-5, 9, sun);
        windSum += w.wind;
        if (w.kind === "thunderstorm") stormCells++;
      }
    }
    wind = windSum / size;
    storm = stormCells / size;
    daylight = lightSum / size;
    sampled = view;
  }

  /** Reads a field at a view position with bilinear filtering. */
  const read = (f: Float32Array, u: number, v: number) => {
    const gx = Math.max(0, Math.min(GRID_X - 0.001, u * GRID_X));
    const gy = Math.max(0, Math.min(GRID_Y - 0.001, v * GRID_Y));
    const i = Math.floor(gx);
    const j = Math.floor(gy);
    const fx = gx - i;
    const fy = gy - j;
    const a = j * (GRID_X + 1) + i;
    const b = a + GRID_X + 1;
    return (f[a] * (1 - fx) + f[a + 1] * fx) * (1 - fy) + (f[b] * (1 - fx) + f[b + 1] * fx) * fy;
  };

  function paint(view: View, tf: number, zoom: number, soften: number) {
    const days = tf / 4;
    const offset = WEATHER_DRIFT * days;
    const spanX = view.x1 - view.x0;
    const spanY = view.y1 - view.y0;
    const shadowX = 18 / Math.max(1, zoom * 0.35);
    const ceiling = 0.72 - 0.32 * smooth(1.5, 7, zoom); // close up you look under the clouds, not at them
    const far = spanX / WIDTH > 5; // each painted cell spans more than the texture's finest detail
    const softness = far ? 0.42 : 0.18; // a sharp edge would show the cells once they are stretched
    const lightData = light.image.data;
    const cloudData = clouds.image.data;
    for (let py = 0; py < HEIGHT; py++) {
      const v = py / (HEIGHT - 1);
      const wy = view.y0 + spanY * v;
      for (let px = 0; px < WIDTH; px++) {
        const u = px / (WIDTH - 1);
        const wx = view.x0 + spanX * u;
        const i = (py * WIDTH + px) * 4;
        const cover = read(field.cloud, u, v);
        const puff = (x: number, y: number) =>
          far ? tex(textures.soft, (x - offset) / 420, y / 420) : 0.68 * tex(textures.fine, (x - offset) / 260, y / 260) + 0.32 * tex(textures.fine, (x - offset) / 70, y / 70);
        const cloud = cover < 0.01 ? 0 : smooth(1.02 - cover - softness, 1.02 - cover + softness, puff(wx, wy));
        const shadow = cover < 0.01 ? 0 : smooth(1.02 - cover - softness, 1.02 - cover + softness, puff(wx - shadowX, wy - shadowX));
        const dim = 1 - 0.3 * shadow;
        lightData[i] = 255 * Math.min(1, read(field.r, u, v) * dim + soften);
        lightData[i + 1] = 255 * Math.min(1, read(field.g, u, v) * dim + soften);
        lightData[i + 2] = 255 * Math.min(1, read(field.b, u, v) * dim + soften);
        lightData[i + 3] = 255;

        const rain = read(field.rain, u, v);
        const grey = 1 - 0.5 * clamp01(rain * 1.2);
        const fog = read(field.fog, u, v);
        const sand = read(field.sand, u, v);
        const haze = Math.max(fog * 0.55, sand * 0.62);
        const alpha = Math.max(cloud * ceiling, haze);
        const sandShare = alpha > 0 ? (sand * 0.62) / Math.max(alpha, 0.01) : 0;
        cloudData[i] = 244 * grey + (214 - 244 * grey) * clamp01(sandShare);
        cloudData[i + 1] = 247 * grey + (170 - 247 * grey) * clamp01(sandShare);
        cloudData[i + 2] = 252 * grey + (108 - 252 * grey) * clamp01(sandShare);
        cloudData[i + 3] = 255 * alpha;
      }
    }
    light.ctx.putImageData(light.image, 0, 0);
    clouds.ctx.putImageData(clouds.image, 0, 0);
    painted = view;
  }

  /** Re-samples and re-paints when due. Call once per frame. */
  function update(view: View, tf: number, zoom: number, tune: WeatherTuning, now: number, soften: number) {
    const w = view.x1 - view.x0;
    const h = view.y1 - view.y0;
    const wide = { x0: view.x0 - w * MARGIN, y0: view.y0 - h * MARGIN, x1: view.x1 + w * MARGIN, y1: view.y1 + h * MARGIN };
    const drifted = !sampled || Math.abs(view.x0 - painted.x0 - w * MARGIN) > w * MARGIN * 0.6 || Math.abs(view.y0 - painted.y0 - h * MARGIN) > h * MARGIN * 0.6 ||
      Math.abs(view.x1 - view.x0 - (painted.x1 - painted.x0) / (1 + 2 * MARGIN)) > w * 0.08;
    if (drifted || now - lastPaint >= PAINT_MS) {
      const area = drifted ? wide : painted;
      if (drifted || now - lastWeather >= WEATHER_MS) {
        sampleField(area, tf, tune);
        lastWeather = now;
      }
      paint(area, tf, zoom, soften);
      lastPaint = now;
    }
  }

  // --- drawing ---------------------------------------------------------------------------------

  function placed(ctx: CanvasRenderingContext2D, canvas: HTMLCanvasElement, sx: (x: number) => number, sy: (y: number) => number) {
    ctx.drawImage(canvas, sx(painted.x0), sy(painted.y0), sx(painted.x1) - sx(painted.x0), sy(painted.y1) - sy(painted.y0));
  }

  /** Clouds and the day's light, over the land and people. */
  function drawSky(ctx: CanvasRenderingContext2D, sx: (x: number) => number, sy: (y: number) => number) {
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "low";
    placed(ctx, clouds.canvas, sx, sy);
    ctx.globalCompositeOperation = "multiply";
    placed(ctx, light.canvas, sx, sy);
    ctx.globalCompositeOperation = "source-over";
  }

  let drops: Drop[] = [];

  /** Rain and snow live on the screen, and each drop only shows where the field says it is falling. */
  function drawPrecipitation(ctx: CanvasRenderingContext2D, W: number, H: number, view: View, dt: number, zoom: number) {
    const wanted = Math.min(460, Math.round((W * H) / 2200));
    if (drops.length !== wanted) {
      drops = Array.from({ length: wanted }, (_, i) => ({ x: Math.random() * W, y: Math.random() * H, speed: 0.75 + Math.random() * 0.5, seed: (i * 0.618034) % 1 }));
    }
    if (zoom < 1.6) return;
    const slant = Math.min(0.55, wind / 110);
    const toU = (x: number) => clamp01((view.x0 + ((view.x1 - view.x0) * x) / W - painted.x0) / (painted.x1 - painted.x0));
    const toV = (y: number) => clamp01((view.y0 + ((view.y1 - view.y0) * y) / H - painted.y0) / (painted.y1 - painted.y0));
    ctx.lineCap = "round";
    ctx.beginPath();
    let rainDrawn = 0;
    const flakes: Drop[] = [];
    const sandGrains: Drop[] = [];
    for (const d of drops) {
      const u = toU(d.x);
      const v = toV(d.y);
      const rain = read(field.rain, u, v);
      const snow = read(field.snow, u, v);
      const sand = read(field.sand, u, v);
      const falling = rain > 0.08 && d.seed < Math.min(1, 0.2 + rain * 1.1);
      if (falling && snow > 0.5) {
        d.y += d.speed * dt * 0.05;
        d.x += (Math.sin(d.y * 0.03 + d.seed * 9) * 0.03 + slant * 0.05) * dt;
        flakes.push(d);
      } else if (falling) {
        const dy = d.speed * dt * 0.75;
        d.y += dy;
        d.x += dy * slant;
        ctx.moveTo(d.x, d.y);
        ctx.lineTo(d.x + 11 * slant, d.y + 11);
        rainDrawn++;
      } else if (sand > 0.3 && d.seed < sand * 0.8) {
        d.x += d.speed * dt * 0.45;
        d.y += Math.sin(d.x * 0.02 + d.seed * 7) * 0.2;
        sandGrains.push(d);
      } else {
        d.y += d.speed * dt * 0.2;
      }
      if (d.y > H + 12) {
        d.y = -12;
        d.x = Math.random() * (W + 80) - 80;
      }
      if (d.x > W + 12) d.x = -12;
    }
    if (rainDrawn) {
      ctx.strokeStyle = "rgba(190, 214, 245, 0.42)";
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    if (flakes.length) {
      ctx.fillStyle = "rgba(244, 248, 255, 0.9)";
      ctx.beginPath();
      for (const f of flakes) {
        const r = 0.9 + f.seed * 1.3;
        ctx.moveTo(f.x + r, f.y);
        ctx.arc(f.x, f.y, r, 0, Math.PI * 2);
      }
      ctx.fill();
    }
    if (sandGrains.length) {
      ctx.strokeStyle = "rgba(226, 190, 130, 0.45)";
      ctx.beginPath();
      for (const g of sandGrains) {
        ctx.moveTo(g.x, g.y);
        ctx.lineTo(g.x + 14, g.y + 1);
      }
      ctx.stroke();
    }
  }

  /** A gentle flash at most every 6 seconds: never a strobe. */
  function drawLightning(ctx: CanvasRenderingContext2D, W: number, H: number, now: number) {
    if (storm > 0.08 && now > nextFlash) {
      flashAt = now;
      nextFlash = now + 6000 + Math.random() * 9000;
      flashX = 0.15 + Math.random() * 0.7;
      flashY = 0.15 + Math.random() * 0.5;
    }
    const age = now - flashAt;
    if (age > 320) return;
    const alpha = 0.34 * (1 - age / 320);
    const x = W * flashX;
    const y = H * flashY;
    const glow = ctx.createRadialGradient(x, y, 0, x, y, Math.max(W, H) * 0.5);
    glow.addColorStop(0, `rgba(226, 232, 255, ${alpha})`);
    glow.addColorStop(1, "rgba(226, 232, 255, 0)");
    ctx.globalCompositeOperation = "lighter";
    ctx.fillStyle = glow;
    ctx.fillRect(0, 0, W, H);
    ctx.globalCompositeOperation = "source-over";
  }

  return {
    update,
    drawSky,
    drawPrecipitation,
    drawLightning,
    get daylight() {
      return daylight;
    },
  };
}

export type Atmosphere = ReturnType<typeof createAtmosphere>;
export type { Weather };
