"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useSyncExternalStore } from "react";
import { signOut } from "@/app/login/actions";
import { decodeNav, NAV_COOKIE } from "@/shared/nav-cookie";

const listeners = new Set<() => void>();

function subscribe(listener: () => void) {
  listeners.add(listener);
  window.addEventListener("focus", listener);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("focus", listener);
  };
}

function readCookie(): string {
  const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${NAV_COOKIE}=([^;]*)`));
  return match?.[1] ?? "";
}

function clearCookie() {
  document.cookie = `${NAV_COOKIE}=; Max-Age=0; Path=/`;
  listeners.forEach((l) => l());
}

/**
 * Header account area. Pages are cached for everyone, so this is decided in the browser from a
 * display-only cookie, with no server call per view. Hidden until hydrated so a signed-in
 * visitor never sees a flash of "Sign in".
 */
export function AuthNav() {
  usePathname(); // re-reads the cookie after each navigation
  const raw = useSyncExternalStore(subscribe, readCookie, () => null);
  const user = decodeNav(raw);

  if (user) {
    return (
      <div className="ml-auto flex items-center gap-3 text-sm">
        <Link href={user.isGod ? "/god" : "/me"} prefetch={false} className={`font-medium hover:underline ${user.isGod ? "text-god" : "text-ink"}`}>
          {user.username}
        </Link>
        <form action={signOut} onSubmit={clearCookie}>
          <button className="text-ink-2 hover:text-ink">Sign out</button>
        </form>
      </div>
    );
  }
  return (
    <div className={`ml-auto flex items-center gap-3 text-sm ${raw === null ? "invisible" : ""}`}>
      <Link href="/login" prefetch={false} className="text-ink-2 hover:text-ink">
        Sign in
      </Link>
      <Link href="/signup" prefetch={false} className="btn btn-life !px-3 !py-1.5">
        Sign up
      </Link>
    </div>
  );
}
