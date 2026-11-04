import "server-only";
import { cookies } from "next/headers";
import { encodeNav, NAV_COOKIE, NAV_COOKIE_MAX_AGE } from "@/shared/nav-cookie";

/** Readable by page scripts on purpose: see shared/nav-cookie.ts. Holds no session data. */
export async function rememberNav(username: string, isGod: boolean) {
  (await cookies()).set(NAV_COOKIE, encodeNav(username, isGod), {
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: NAV_COOKIE_MAX_AGE,
  });
}

export async function forgetNav() {
  (await cookies()).delete(NAV_COOKIE);
}
