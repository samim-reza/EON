/**
 * The sound of the place the map is showing: wind, rain, birds by day and insects at night.
 * It is made in the browser from noise and a few tones, so there is nothing to download, and it
 * only ever starts when the visitor asks for it.
 */
export type Scene = {
  /** 0 to 1 */
  rain: number;
  /** km/h */
  wind: number;
  /** 0 (night) to 1 (day) */
  daylight: number;
  /** °C */
  temp: number;
  fire: boolean;
};

export type Ambience = { set: (scene: Scene) => void; stop: () => void };

type AudioWindow = Window & { webkitAudioContext?: typeof AudioContext };

/** Starts the sound. Call it from a click: browsers refuse audio that nobody asked for. */
export function startAmbience(): Ambience | null {
  const Ctor = window.AudioContext ?? (window as AudioWindow).webkitAudioContext;
  if (!Ctor) return null;
  const audio = new Ctor();
  const master = audio.createGain();
  master.gain.value = 0;
  master.connect(audio.destination);
  master.gain.linearRampToValueAtTime(0.5, audio.currentTime + 1.5);

  // Two seconds of noise, looped, feed the wind, the rain and the fire.
  const buffer = audio.createBuffer(1, audio.sampleRate * 2, audio.sampleRate);
  const samples = buffer.getChannelData(0);
  let last = 0;
  for (let i = 0; i < samples.length; i++) {
    last = 0.97 * last + 0.03 * (Math.random() * 2 - 1); // soften white noise towards brown
    samples[i] = last * 6;
  }
  const noise = audio.createBufferSource();
  noise.buffer = buffer;
  noise.loop = true;

  const layer = (type: BiquadFilterType, frequency: number, q: number) => {
    const filter = audio.createBiquadFilter();
    filter.type = type;
    filter.frequency.value = frequency;
    filter.Q.value = q;
    const gain = audio.createGain();
    gain.gain.value = 0;
    noise.connect(filter);
    filter.connect(gain);
    gain.connect(master);
    return { filter, gain };
  };
  const wind = layer("lowpass", 420, 0.6);
  const rain = layer("highpass", 2400, 0.4);
  const fire = layer("bandpass", 900, 0.8);
  noise.start();

  let scene: Scene = { rain: 0, wind: 8, daylight: 1, temp: 15, fire: false };
  let stopped = false;

  /** One bird call: two or three quick notes that slide in pitch. */
  const chirp = () => {
    const t0 = audio.currentTime;
    const base = 2200 + Math.random() * 1800;
    const notes = 2 + Math.floor(Math.random() * 3);
    for (let n = 0; n < notes; n++) {
      const osc = audio.createOscillator();
      const gain = audio.createGain();
      const start = t0 + n * 0.11;
      osc.type = "sine";
      osc.frequency.setValueAtTime(base * (1 + 0.12 * n), start);
      osc.frequency.exponentialRampToValueAtTime(base * (0.8 + Math.random() * 0.5), start + 0.08);
      gain.gain.setValueAtTime(0, start);
      gain.gain.linearRampToValueAtTime(0.05, start + 0.015);
      gain.gain.exponentialRampToValueAtTime(0.0005, start + 0.09);
      osc.connect(gain);
      gain.connect(master);
      osc.start(start);
      osc.stop(start + 0.1);
    }
  };

  /** Night insects: a high tone switched on and off very fast, in short bursts. */
  const crickets = () => {
    const t0 = audio.currentTime;
    const osc = audio.createOscillator();
    const gain = audio.createGain();
    osc.type = "sine";
    osc.frequency.value = 4300 + Math.random() * 500;
    gain.gain.setValueAtTime(0, t0);
    for (let n = 0; n < 9; n++) {
      gain.gain.setValueAtTime(0.018, t0 + n * 0.06);
      gain.gain.setValueAtTime(0, t0 + n * 0.06 + 0.03);
    }
    osc.connect(gain);
    gain.connect(master);
    osc.start(t0);
    osc.stop(t0 + 0.6);
  };

  const life = window.setInterval(() => {
    if (stopped || audio.state !== "running") return;
    const quiet = scene.rain > 0.35 || scene.wind > 45; // nothing sings in a storm
    if (scene.daylight > 0.45 && scene.temp > 2 && !quiet && Math.random() < 0.3) chirp();
    if (scene.daylight < 0.2 && scene.temp > 12 && !quiet && Math.random() < 0.55) crickets();
  }, 700);

  return {
    set(next) {
      scene = next;
      const now = audio.currentTime;
      wind.gain.gain.setTargetAtTime(Math.min(0.5, 0.05 + next.wind / 110), now, 1.2);
      wind.filter.frequency.setTargetAtTime(300 + next.wind * 9, now, 1.2);
      rain.gain.gain.setTargetAtTime(Math.min(0.42, next.rain * 0.5), now, 0.8);
      fire.gain.gain.setTargetAtTime(next.fire ? 0.3 : 0, now, 0.6);
    },
    stop() {
      stopped = true;
      window.clearInterval(life);
      master.gain.setTargetAtTime(0, audio.currentTime, 0.2);
      window.setTimeout(() => void audio.close().catch(() => undefined), 700);
    },
  };
}
