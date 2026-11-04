import { terrainPixels, terrainTile } from "@/shared/terrain-pixels";

export type TerrainRequest = { kind: "map"; seed: number; res: number } | { kind: "tile"; seed: number; x: number; y: number };

/** Runs off the main thread, so generating the world never freezes the page. */
self.onmessage = (event: MessageEvent<TerrainRequest>) => {
  const post = (self as unknown as Worker).postMessage.bind(self);
  const request = event.data;
  if (request.kind === "map") {
    const map = terrainPixels(request.seed, request.res);
    post({ kind: "map", map }, [map.data.buffer, map.snow.buffer, map.autumn.buffer]); // transfer, don't copy
  } else {
    const { data, tide } = terrainTile(request.seed, request.x, request.y);
    post({ kind: "tile", x: request.x, y: request.y, data, tide }, [data.buffer, tide.buffer]);
  }
};
