import { ImageResponse } from "next/og";
import { pub } from "@/lib/pub";
import { formatAge } from "@/shared/time";
import type { AgentDetail } from "@/shared/types";

export const alt = "A person of EON";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export const revalidate = 300;

async function getAgent(raw: string): Promise<AgentDetail | null> {
  if (!/^\d{1,13}$/.test(raw)) return null;
  return pub.agent(Number(raw)).catch(() => null);
}

/** The card shown when someone shares a person's page. */
export default async function AgentImage({ params }: { params: Promise<{ id: string }> }) {
  const a = await getAgent((await params).id);
  const name = a ? `${a.name} ${a.surname}` : "Someone in EON";
  const tags = a ? [a.founder && "founder", a.isPlayer && "human soul", `generation ${a.generation}`, !a.alive && "deceased"].filter(Boolean) : [];
  const line = a
    ? a.alive
      ? `${formatAge(a.age)} old · ${a.occupation ?? "adult"} in ${a.settlement?.name ?? "the wilds"}${a.pregnant ? " · expecting a child" : ""}`
      : `Lived ${formatAge(a.age)} · died of ${a.cause ?? "unknown causes"}`
    : "An AI agent with a family, a body and a fate of their own";
  const kids = a && a.children.length ? `${a.children.length} ${a.children.length === 1 ? "child" : "children"}` : null;
  const accent = a && !a.alive ? "#8e98ab" : a?.sex === "F" ? "#e58bd5" : "#4fd1c5";
  return new ImageResponse(
    <div style={{ width: "100%", height: "100%", display: "flex", flexDirection: "column", justifyContent: "space-between", background: "linear-gradient(120deg, #070b14 45%, #123044 100%)", color: "#e6ecf5", padding: 72, fontFamily: "sans-serif" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
        <div style={{ width: 14, height: 14, borderRadius: 14, background: "#4fd1c5" }} />
        <div style={{ fontSize: 30, letterSpacing: 12, color: "#4fd1c5", fontWeight: 700 }}>EON</div>
        <div style={{ fontSize: 26, color: "#9aa8bf", marginLeft: 8 }}>a living world of AI agents</div>
      </div>
      <div style={{ display: "flex", flexDirection: "column" }}>
        <div style={{ display: "flex", gap: 12 }}>
          {tags.map((t) => (
            <div key={String(t)} style={{ fontSize: 22, padding: "6px 14px", borderRadius: 999, border: "1px solid #2b3a52", color: "#9aa8bf" }}>
              {String(t)}
            </div>
          ))}
        </div>
        <div style={{ marginTop: 22, fontSize: 84, lineHeight: 1.05, fontWeight: 700, color: accent }}>{name}</div>
        <div style={{ marginTop: 22, fontSize: 34, lineHeight: 1.3, color: "#c7d0de" }}>{line}</div>
        {kids && <div style={{ marginTop: 10, fontSize: 28, color: "#9aa8bf" }}>{kids}</div>}
      </div>
      <div style={{ fontSize: 24, color: "#6f7d94" }}>One EON year passes every real day. Follow a life from its first day at eon-rose.vercel.app</div>
    </div>,
    size,
  );
}
