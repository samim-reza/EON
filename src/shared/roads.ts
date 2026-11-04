/**
 * Paths and roads. Nobody plans a village's paths: people wear them between the places they go. A
 * minimum spanning tree gives the same result, the shortest network that joins every building, and
 * because it is a tree there is exactly one route between any two places.
 */
import { hash01 } from "./world";

type Point = { x: number; y: number };
type Node = Point & { id: number; parent: number; depth: number; bendX: number; bendY: number };

export type RoadNet = {
  nodes: Map<number, Node>;
  /** One curved piece per building: from, control point, to. */
  segments: [number, number, number, number, number, number][];
};

/** Prim's algorithm, grown outward from the centre of each settlement. */
export function buildRoads(places: { id: number; x: number; y: number; group: number }[], centres: Map<number, Point>): RoadNet {
  const nodes = new Map<number, Node>();
  const segments: RoadNet["segments"] = [];
  const groups = new Map<number, typeof places>();
  for (const p of places) {
    const list = groups.get(p.group);
    if (list) list.push(p);
    else groups.set(p.group, [p]);
  }
  for (const [group, list] of groups) {
    const centre = centres.get(group) ?? list[0];
    const count = list.length;
    const nearest = new Float64Array(count).fill(Infinity);
    const via = new Int32Array(count).fill(-1);
    const done = new Uint8Array(count);
    let start = 0;
    let best = Infinity;
    list.forEach((p, i) => {
      const d = (p.x - centre.x) ** 2 + (p.y - centre.y) ** 2;
      if (d < best) {
        best = d;
        start = i;
      }
    });
    nearest[start] = 0;
    for (let step = 0; step < count; step++) {
      let at = -1;
      for (let i = 0; i < count; i++) if (!done[i] && (at < 0 || nearest[i] < nearest[at])) at = i;
      done[at] = 1;
      const p = list[at];
      const from = via[at] >= 0 ? list[via[at]] : null;
      const parent = from ? nodes.get(from.id)! : null;
      // A worn path wanders a little, always the same way.
      const lean = from ? (hash01(p.id, 61) - 0.5) * 0.28 : 0;
      const bendX = from ? (from.x + p.x) / 2 - (p.y - from.y) * lean : p.x;
      const bendY = from ? (from.y + p.y) / 2 + (p.x - from.x) * lean : p.y;
      nodes.set(p.id, { id: p.id, x: p.x, y: p.y, parent: from ? from.id : -1, depth: parent ? parent.depth + 1 : 0, bendX, bendY });
      if (from) segments.push([from.x, from.y, bendX, bendY, p.x, p.y]);
      for (let i = 0; i < count; i++) {
        if (done[i]) continue;
        const d = (list[i].x - p.x) ** 2 + (list[i].y - p.y) ** 2;
        if (d < nearest[i]) {
          nearest[i] = d;
          via[i] = at;
        }
      }
    }
  }
  return { nodes, segments };
}

/** The way from one building to another: up from each end until the two meet. */
export function routeBetween(net: RoadNet, from: number, to: number): Point[] {
  let a = net.nodes.get(from);
  let b = net.nodes.get(to);
  if (!a || !b) return [];
  const up: Point[] = [{ x: a.x, y: a.y }];
  const down: Point[] = [{ x: b.x, y: b.y }];
  const climb = (node: Node, path: Point[]) => {
    const parent = net.nodes.get(node.parent)!;
    path.push({ x: (parent.x + 2 * node.bendX + node.x) / 4, y: (parent.y + 2 * node.bendY + node.y) / 4 }); // the middle of the curve
    path.push({ x: parent.x, y: parent.y });
    return parent;
  };
  while (a.id !== b.id) {
    if (a.parent < 0 && b.parent < 0) return []; // different settlements
    if (a.parent >= 0 && (a.depth >= b.depth || b.parent < 0)) a = climb(a, up);
    else b = climb(b, down);
  }
  return [...up, ...down.reverse().slice(1)];
}

/** A point part of the way along a line of points, by distance walked. */
export function alongPath(path: Point[], k: number): Point {
  let total = 0;
  for (let i = 1; i < path.length; i++) total += Math.hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y);
  let left = total * k;
  for (let i = 1; i < path.length; i++) {
    const length = Math.hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y);
    if (left <= length && length > 0) {
      const t = left / length;
      return { x: path[i - 1].x + (path[i].x - path[i - 1].x) * t, y: path[i - 1].y + (path[i].y - path[i - 1].y) * t };
    }
    left -= length;
  }
  return path[path.length - 1];
}

/** Roads between settlements, joining each to its nearest neighbour without crossing open water. */
export function linkSettlements(settlements: { id: number; x: number; y: number }[], elevation: (x: number, y: number) => number) {
  const links: [number, number, number, number][] = [];
  const joined = settlements.slice(0, 1);
  const waiting = settlements.slice(1);
  while (waiting.length) {
    let best = 0;
    let from = joined[0];
    let distance = Infinity;
    waiting.forEach((s, i) => {
      for (const j of joined) {
        const d = Math.hypot(s.x - j.x, s.y - j.y);
        if (d < distance) {
          distance = d;
          best = i;
          from = j;
        }
      }
    });
    const [to] = waiting.splice(best, 1);
    joined.push(to);
    let wet = 0;
    for (let k = 1; k < 20; k++) if (elevation(from.x + ((to.x - from.x) * k) / 20, from.y + ((to.y - from.y) * k) / 20) <= 0) wet++;
    if (wet <= 2) links.push([from.x, from.y, to.x, to.y]);
  }
  return links;
}
