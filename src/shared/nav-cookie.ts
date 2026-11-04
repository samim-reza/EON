/**
 * A display hint, not a credential: it only lets cached pages show the right buttons without a
 * server call on every view. Nothing on the server ever trusts it, and forging it shows a wrong
 * label to yourself and nothing more. The real session stays in httpOnly cookies.
 */
export const NAV_COOKIE = "eon_nav";
export const NAV_COOKIE_MAX_AGE = 60 * 60 * 24 * 30;

export type NavUser = { username: string; isGod: boolean };

export const encodeNav = (username: string, isGod: boolean) => `${username}.${isGod ? 1 : 0}`;

export function decodeNav(raw: string | null | undefined): NavUser | null {
  const m = raw?.match(/^([a-z0-9_]{3,20})\.([01])$/);
  return m ? { username: m[1], isGod: m[2] === "1" } : null;
}
