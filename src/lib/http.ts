import "server-only";

type CacheMode =
  | { kind: "immutable" }
  | { kind: "shared"; sMaxAge: number; swr?: number; browser?: number }
  | { kind: "none" };

function cacheHeaders(mode: CacheMode): Record<string, string> {
  switch (mode.kind) {
    case "immutable":
      return {
        "Cache-Control": "public, max-age=31536000, immutable",
        "CDN-Cache-Control": "public, max-age=31536000, immutable",
      };
    case "shared": {
      const swr = mode.swr ? `, stale-while-revalidate=${mode.swr}` : "";
      return {
        "Cache-Control": `public, max-age=${mode.browser ?? 0}, s-maxage=${mode.sMaxAge}${swr}`,
        "CDN-Cache-Control": `public, max-age=${mode.sMaxAge}${swr}`,
      };
    }
    default:
      return { "Cache-Control": "no-store" };
  }
}

export function json(data: unknown, mode: CacheMode, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...cacheHeaders(mode), ...extra },
  });
}

export function problem(status: number, message: string) {
  return json({ error: message }, { kind: "none" }, status);
}

/** Rejects unknown query params so nobody can bust the CDN cache with junk keys. */
export function onlyParams(url: URL, allowed: string[]): string | null {
  for (const k of url.searchParams.keys()) if (!allowed.includes(k)) return k;
  return null;
}

export function parseIntStrict(v: string | null | undefined, min: number, max: number): number | null {
  if (v == null || !/^-?\d{1,12}$/.test(v)) return null;
  const n = Number(v);
  return n >= min && n <= max ? n : null;
}
