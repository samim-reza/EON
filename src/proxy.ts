import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { encodeNav, NAV_COOKIE, NAV_COOKIE_MAX_AGE } from "@/shared/nav-cookie";

/**
 * Runs only on interactive ("play") routes: /me, /god, /login, /signup, /auth/*.
 * 1. Builds a per-request nonce Content-Security-Policy (scripts must carry the nonce).
 * 2. Refreshes the Supabase session (httpOnly cookies).
 * 3. Keeps the display-only nav hint in step with the real session.
 * Authorization is NOT decided here — every server action / RPC re-checks it.
 */
const isDev = process.env.NODE_ENV === "development";

function buildCsp(nonce: string): string {
  const supabase = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const wss = supabase.replace(/^https:/, "wss:");
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isDev ? " 'unsafe-eval'" : ""}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self'",
    `connect-src 'self' ${supabase} ${wss}`,
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    ...(isDev ? [] : ["upgrade-insecure-requests"]),
  ].join("; ");
}

const SESSION = { httpOnly: true, secure: !isDev, sameSite: "lax" as const, path: "/" };

export async function proxy(request: NextRequest) {
  const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
  const csp = buildCsp(nonce);

  const forward = () => {
    const headers = new Headers(request.headers);
    headers.set("x-nonce", nonce);
    headers.set("Content-Security-Policy", csp);
    return NextResponse.next({ request: { headers } });
  };

  let response = forward();
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (url && key) {
    const supabase = createServerClient(url, key, {
      db: { schema: "api" },
      cookieOptions: SESSION,
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll(toSet) {
          for (const { name, value } of toSet) request.cookies.set(name, value);
          response = forward();
          for (const { name, value, options } of toSet) response.cookies.set(name, value, { ...options, ...SESSION });
        },
      },
    });
    const { data: session } = await supabase.auth.getClaims(); // refreshes an expiring session
    const signedIn = Boolean(session?.claims?.sub);
    const hinted = request.cookies.has(NAV_COOKIE);
    if (signedIn && !hinted) {
      const { data: me } = await supabase.rpc("whoami");
      if (me?.username) {
        response.cookies.set(NAV_COOKIE, encodeNav(me.username, Boolean(me.is_god)), {
          secure: !isDev, sameSite: "lax", path: "/", maxAge: NAV_COOKIE_MAX_AGE,
        });
      }
    } else if (!signedIn && hinted) {
      response.cookies.delete(NAV_COOKIE);
    }
  }
  response.headers.set("Content-Security-Policy", csp);
  response.headers.set("Cache-Control", "private, no-store");
  return response;
}

export const config = {
  matcher: ["/me/:path*", "/god/:path*", "/login", "/signup", "/auth/:path*", "/api/me"],
};
