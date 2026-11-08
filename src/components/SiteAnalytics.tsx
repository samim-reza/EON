"use client";

import { Analytics, type BeforeSendEvent } from "@vercel/analytics/next";
import { redactPageUrl } from "@/shared/analytics";

// Anonymous page counts (Vercel Web Analytics: no cookies, nothing personal).
function beforeSend(event: BeforeSendEvent): BeforeSendEvent | null {
  const url = redactPageUrl(event.url);
  return url ? { ...event, url } : null;
}

export function SiteAnalytics() {
  return <Analytics beforeSend={beforeSend} />;
}
