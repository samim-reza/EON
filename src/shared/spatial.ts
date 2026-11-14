/**
 * A uniform grid over the map: the quick way to ask "what is near here?". Items are hashed into
 * square cells by their position, so a question about one screen or one pointer looks at a few
 * cells instead of every village in the world.
 *
 * A grid suits EON better than a tree: villages are spread fairly evenly, they never move, and the
 * index is rebuilt only when a village is founded.
 */
export type Spatial<T> = {
  /** Calls `visit` for every item inside the rectangle. */
  within(x0: number, y0: number, x1: number, y1: number, visit: (item: T) => void): void;
  /** Calls `visit` for every item no further than `radius` from the point. */
  near(x: number, y: number, radius: number, visit: (item: T) => void): void;
  readonly size: number;
};

export function spatialIndex<T extends { x: number; y: number }>(items: readonly T[], cell = 64): Spatial<T> {
  const cells = new Map<number, T[]>();
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  const col = (v: number) => Math.floor(v / cell);
  // Cell coordinates are packed into one number, which a Map hashes far faster than a string key.
  const key = (cx: number, cy: number) => (cx + 32768) * 65536 + (cy + 32768);
  for (const item of items) {
    const cx = col(item.x);
    const cy = col(item.y);
    minX = Math.min(minX, cx); maxX = Math.max(maxX, cx);
    minY = Math.min(minY, cy); maxY = Math.max(maxY, cy);
    const k = key(cx, cy);
    const list = cells.get(k);
    if (list) list.push(item);
    else cells.set(k, [item]);
  }

  const within = (x0: number, y0: number, x1: number, y1: number, visit: (item: T) => void) => {
    // Clamped to where there is anything at all, so a huge rectangle costs no more than a full scan.
    const fromX = Math.max(minX, col(x0)), toX = Math.min(maxX, col(x1));
    const fromY = Math.max(minY, col(y0)), toY = Math.min(maxY, col(y1));
    for (let cx = fromX; cx <= toX; cx++) {
      for (let cy = fromY; cy <= toY; cy++) {
        const list = cells.get(key(cx, cy));
        if (!list) continue;
        for (const item of list) if (item.x >= x0 && item.x <= x1 && item.y >= y0 && item.y <= y1) visit(item);
      }
    }
  };

  return {
    size: items.length,
    within,
    near(x, y, radius, visit) {
      const r2 = radius * radius;
      within(x - radius, y - radius, x + radius, y + radius, (item) => {
        if ((item.x - x) ** 2 + (item.y - y) ** 2 <= r2) visit(item);
      });
    },
  };
}
