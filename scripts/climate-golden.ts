// Regenerates the vectors that keep src/shared/climate.ts and its SQL twin identical.
// Usage: npx tsx scripts/climate-golden.ts
// Writes src/shared/params/climate-golden.json and prints the matching pgTAP block for supabase/tests/eon_test.sql.
import { writeFileSync } from "node:fs";
import { climateAt, hash3, noise3, springTide, weatherAt } from "../src/shared/climate";

const round = (v: number) => Math.round(v * 1e9) / 1e9;
const hashes = [[1, 2, 3, 4], [1257650109, -7, 90000, 12], [2147483646, 123456, -1, 77]].map(([s, a, b, c]) => ({ in: [s, a, b, c], out: hash3(s, a, b, c) }));
const noises = [[42, 1.25, 2.5, 3.75], [1257650109, 301.7, 12.2, 900.4], [99, -14.3, 7.7, 0.5]].map(([s, x, y, z]) => ({ in: [s, x, y, z], out: round(noise3(s, x, y, z)) }));
const tides = [[1257650109, 419], [777, 2000.5], [4242, 31.25]].map(([seed, tf]) => ({ in: [seed, tf], out: round(springTide(seed, tf)) }));
const places: [number, number, number, number, number][] = [
  [1257650109, 509.2, 511, 0.43, 397], // highland grassland, summer
  [1257650109, 300, 860, 0.14, 1210], // southern forest
  [4242, 620, 640, 0.2, 980], // arid, winter
  [777, 440, 120, 0.3, 1090.5], // arctic, deep winter
  [90210, 520, 920, 0.08, 505.25], // equator, monsoon
  [31337, 700, 300, 0.12, 1000.75],
];
const weather = places.map(([seed, x, y, elev, tf]) => {
  const c = climateAt(seed, x, y, elev);
  const w = weatherAt(seed, c, x, y, tf, { tempShift: 1.5, rainMult: 1.2 });
  return {
    in: { seed, x, y, elev, tf },
    climate: { tempMean: round(c.tempMean), tempSwing: round(c.tempSwing), wet: round(c.wet), rainfall: round(c.rainfall), biome: c.biome },
    weather: { temp: round(w.temp), high: round(w.high), low: round(w.low), cloud: round(w.cloud), rain: round(w.rain), wind: round(w.wind), kind: w.kind, heatwave: w.heatwave, coldSnap: w.coldSnap },
  };
});
writeFileSync(new URL("../src/shared/params/climate-golden.json", import.meta.url), JSON.stringify({ hashes, noises, tides, weather }, null, 1) + "\n");

const q = (s: string) => `'${s}'`;
const near = (a: string, b: number) => `abs(${a} - (${b})) < 1e-6`;
const lines = [
  ...hashes.map((h) => `select is(sim.hash3(${h.in.join(", ")}), ${h.out}::double precision, 'hash3 matches JavaScript exactly');`),
  ...noises.map((n) => `select ok(${near(`sim.noise3(${n.in[0]}, ${n.in[1]}, ${n.in[2]}, ${n.in[3]})`, n.out)}, 'noise3 matches JavaScript');`),
  ...tides.map((t) => `select ok(${near(`sim.spring_tide(${t.in[0]}, ${t.in[1]})`, t.out)}, 'spring tide matches JavaScript');`),
  ...weather.map((v) => {
    const { seed, x, y, elev, tf } = v.in;
    const c = v.climate;
    const w = v.weather;
    return `select ok((select ${near("c.temp_mean", c.tempMean)} and ${near("c.temp_swing", c.tempSwing)} and ${near("c.wet", c.wet)} and ${near("c.rainfall", c.rainfall)} and c.biome = ${q(c.biome)}
    and ${near("w.temp", w.temp)} and ${near("w.high", w.high)} and ${near("w.low", w.low)} and ${near("w.cloud", w.cloud)} and ${near("w.rain", w.rain)} and ${near("w.wind", w.wind)}
    and w.kind = ${q(w.kind)} and w.heatwave = ${w.heatwave} and w.cold_snap = ${w.coldSnap}
  from sim.climate_at(${seed}, ${x}, ${y}, ${elev}) c
  cross join lateral sim.weather_at(${seed}, c.lat, c.temp_mean, c.temp_swing, c.wet, c.rainfall, c.biome, ${x}, ${y}, ${tf}, 1.5, 1.2) w), 'weather at ${seed}/${x},${y} matches JavaScript');`;
  }),
];
console.log(lines.join("\n"));
