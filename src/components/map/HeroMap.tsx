"use client";

import dynamic from "next/dynamic";

/** Loaded after the page has painted, so the headline never waits for the map code. */
export const HeroMap = dynamic(() => import("./WorldMap").then((m) => m.HeroWorld), { ssr: false });
