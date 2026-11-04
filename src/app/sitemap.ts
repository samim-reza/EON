import type { MetadataRoute } from "next";
import { siteUrl } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  const pages: [string, MetadataRoute.Sitemap[number]["changeFrequency"], number][] = [
    ["", "hourly", 1],
    ["/world", "hourly", 0.9],
    ["/feed", "hourly", 0.8],
    ["/chronicle", "daily", 0.7],
    ["/about", "weekly", 0.6],
    ["/signup", "monthly", 0.5],
  ];
  return pages.map(([path, changeFrequency, priority]) => ({ url: `${siteUrl}${path}`, changeFrequency, priority }));
}
