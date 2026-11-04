import { terrainPixels } from "@/shared/terrain-pixels";

/** Runs off the main thread, so generating the map never freezes the page. */
self.onmessage = (event: MessageEvent<{ seed: number; res: number }>) => {
  const { size, data } = terrainPixels(event.data.seed, event.data.res);
  (self as unknown as Worker).postMessage({ size, data }, [data.buffer]); // transfer, don't copy
};
