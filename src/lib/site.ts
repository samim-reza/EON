/** Canonical origin: set automatically on Vercel, so forks get their own without configuration. */
const production = process.env.VERCEL_PROJECT_PRODUCTION_URL;

export const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? (production ? `https://${production}` : "http://localhost:3000");
