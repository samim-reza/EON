import type { Metadata } from "next";
import { WorldMap } from "@/components/map/WorldMap";

export const metadata: Metadata = { title: "World" };

export default function WorldPage() {
  return <WorldMap />;
}
