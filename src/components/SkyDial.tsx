import { clamp01, smooth, type Moon, type Weather } from "@/shared/climate";

const W = 200;
const H = 56;
const HORIZON = 46;

const STARS = [[14, 12], [31, 26], [46, 8], [63, 20], [79, 11], [96, 28], [111, 7], [127, 18], [143, 9], [158, 25], [173, 13], [188, 22]];

function mix(a: number[], b: number[], t: number) {
  return `rgb(${a.map((v, i) => Math.round(v + (b[i] - v) * t)).join(",")})`;
}

/** The lit part of the moon, for a disc of radius `r` centred on the origin. */
function moonPath(r: number, phase: number) {
  const waxing = phase < 0.5;
  const quarter = waxing ? phase * 2 : (phase - 0.5) * 2; // 0 to 1 within each half of the month
  const inner = Math.abs(Math.cos(Math.PI * quarter)) * r;
  const gibbous = waxing ? quarter > 0.5 : quarter < 0.5;
  const outer = waxing ? 1 : 0;
  return `M 0 ${-r} A ${r} ${r} 0 0 ${outer} 0 ${r} A ${inner.toFixed(2)} ${r} 0 0 ${gibbous === waxing ? 1 : 0} 0 ${-r} Z`;
}

/** Where a body sits on the dome: `elevation` in degrees, `progress` 0 at the eastern horizon to 1 in the west. */
function onDome(elevation: number, progress: number) {
  return { x: 10 + (W - 20) * clamp01(progress), y: HORIZON - Math.max(-12, Math.min(38, elevation * 0.62)) };
}

export function SkyDial({ sun, sunProgress, moon, moonProgress, weather }: { sun: number; sunProgress: number; moon: Moon; moonProgress: number; weather: Weather }) {
  const day = smooth(-6, 8, sun);
  const low = Math.exp(-(((sun - 1) / 9) ** 2));
  const grey = 0.75 * weather.cloud;
  const top = mix([8, 14, 40], [46, 118, 206], day);
  const bottom = mix(low > 0.2 ? [214, 122, 84] : [22, 32, 72], [150, 206, 244], day * (1 - low * 0.6));
  const sunSpot = onDome(sun, sunProgress);
  const moonSpot = onDome(moon.elevation, moonProgress);
  const rainy = weather.rain > 0.08;
  const snowy = weather.kind === "snow" || weather.kind === "blizzard";
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="block h-9 w-full sm:h-14" role="img" aria-hidden preserveAspectRatio="none">
      <defs>
        <linearGradient id="sky-grad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={top} />
          <stop offset="1" stopColor={bottom} />
        </linearGradient>
        <radialGradient id="sun-glow">
          <stop offset="0" stopColor="#ffe9a8" stopOpacity="0.95" />
          <stop offset="1" stopColor="#ffb648" stopOpacity="0" />
        </radialGradient>
      </defs>
      <rect width={W} height={H} fill="url(#sky-grad)" />
      <g opacity={(1 - smooth(-14, -3, sun)) * (1 - grey)}>
        {STARS.map(([x, y]) => (
          <circle key={x} cx={x} cy={y} r={0.8} fill="#f4f7ff" />
        ))}
      </g>
      {moon.elevation > -4 && (
        <g transform={`translate(${moonSpot.x} ${moonSpot.y})`} opacity={(0.35 + 0.65 * (1 - day)) * (1 - grey * 0.6)}>
          <circle r={6} fill="#2c3550" />
          <path d={moonPath(6, moon.phase)} fill="#eef1f6" />
        </g>
      )}
      {sun > -4 && (
        <g transform={`translate(${sunSpot.x} ${sunSpot.y})`} opacity={1 - grey * 0.75}>
          <circle r={15} fill="url(#sun-glow)" />
          <circle r={5.5} fill={sun < 7 ? "#ffc06a" : "#fff2bf"} />
        </g>
      )}
      <rect width={W} height={HORIZON + 1} fill="#7f8a9b" opacity={grey * 0.7} />
      {rainy && (
        <g stroke={snowy ? "#f4f7ff" : "#c6dcf6"} strokeWidth={snowy ? 1.8 : 0.9} strokeLinecap="round" opacity={0.35 + 0.5 * weather.rain} strokeDasharray={snowy ? "0.1 7" : undefined}>
          {[18, 42, 66, 90, 114, 138, 162, 186].map((x, i) => (
            <line key={x} x1={x} y1={4 + (i % 3) * 5} x2={x - 3} y2={snowy ? 42 : 16 + (i % 3) * 7} />
          ))}
        </g>
      )}
      <rect y={HORIZON} width={W} height={H - HORIZON} fill={mix([12, 18, 26], [46, 70, 50], day)} />
    </svg>
  );
}
