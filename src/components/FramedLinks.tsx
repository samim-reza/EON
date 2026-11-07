"use client";

import { useEffect } from "react";

/** Routes that refuse to load inside a frame (proxy.ts sends them frame-ancestors 'none'). */
const UNFRAMEABLE = /^\/(?:me|god|login|signup|auth)(?:\/|$)/;

/**
 * When EON is shown inside another site's frame (its itch.io page), links to the sign-in pages or
 * to other sites would only show a "refused to connect" box, so they open in a new tab instead.
 */
export function FramedLinks() {
  useEffect(() => {
    if (window.self === window.top) return;
    const onClick = (e: MouseEvent) => {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const link = e.target instanceof Element ? e.target.closest("a[href]") : null;
      if (!(link instanceof HTMLAnchorElement)) return;
      const url = new URL(link.href, location.href);
      if (url.origin === location.origin && !UNFRAMEABLE.test(url.pathname)) return;
      e.preventDefault();
      e.stopPropagation();
      window.open(url.href, "_blank", "noopener");
    };
    window.addEventListener("click", onClick, true);
    return () => window.removeEventListener("click", onClick, true);
  }, []);
  return null;
}
