import { terrainPixels } from "@/shared/terrain-pixels";

type Pixels = { size: number; data: Uint8ClampedArray<ArrayBuffer> };

function generate(seed: number, res: number): Promise<Pixels> {
  return new Promise((resolve) => {
    const onMainThread = () => resolve(terrainPixels(seed, res) as Pixels);
    try {
      const worker = new Worker(new URL("./terrain.worker.ts", import.meta.url));
      worker.onmessage = (event: MessageEvent<Pixels>) => {
        resolve(event.data);
        worker.terminate();
      };
      worker.onerror = () => {
        worker.terminate();
        onMainThread();
      };
      worker.postMessage({ seed, res });
    } catch {
      onMainThread();
    }
  });
}

const cache = new Map<string, Promise<HTMLCanvasElement>>();

/** The map for a seed never changes, so it is built once per tab and reused across pages. */
export function loadTerrain(seed: number, res: number): Promise<HTMLCanvasElement> {
  const key = `${seed}:${res}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const pending = generate(seed, res).then(({ size, data }) => {
    const canvas = document.createElement("canvas");
    canvas.width = size;
    canvas.height = size;
    canvas.getContext("2d")!.putImageData(new ImageData(data, size, size), 0, 0);
    return canvas;
  });
  cache.set(key, pending);
  return pending;
}
