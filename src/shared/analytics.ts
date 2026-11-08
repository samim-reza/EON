// What a page view may tell the analytics service. Only campaign tags survive
// from the query string, so a sign-in or confirmation token can never leave the
// site, and the auth callbacks and the Creator's pages are not counted at all.
const SKIP = /^\/(auth|god)(\/|$)/;

export function redactPageUrl(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (SKIP.test(url.pathname)) return null;
  const kept = new URLSearchParams();
  for (const [k, v] of url.searchParams) {
    if ((k.startsWith("utm_") || k === "ref") && v.length <= 64) kept.set(k, v);
  }
  const query = kept.toString();
  return `${url.origin}${url.pathname}${query ? `?${query}` : ""}`;
}
