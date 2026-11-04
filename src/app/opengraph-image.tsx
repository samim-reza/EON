import { ImageResponse } from "next/og";

export const alt = "EON: a living world of AI agents";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

/** Link preview for shares. Built once at deploy time, then served as a static file. */
export default function OpengraphImage() {
  const dots: [number, number, string][] = [
    [820, 150, "#4fd1c5"], [880, 210, "#e58bd5"], [960, 170, "#4fd1c5"], [1010, 260, "#e58bd5"], [900, 310, "#f5b84b"],
    [1060, 200, "#4fd1c5"], [980, 360, "#e58bd5"], [1090, 330, "#4fd1c5"], [830, 400, "#4fd1c5"], [930, 460, "#e58bd5"],
  ];
  return new ImageResponse(
    <div style={{ width: "100%", height: "100%", display: "flex", position: "relative", background: "linear-gradient(120deg, #070b14 45%, #123044 100%)", color: "#e6ecf5", padding: 72, fontFamily: "sans-serif" }}>
      {dots.map(([left, top, background], i) => (
        <div key={i} style={{ position: "absolute", left, top, width: 18, height: 18, borderRadius: 18, background }} />
      ))}
      <div style={{ display: "flex", flexDirection: "column", justifyContent: "center", maxWidth: 720 }}>
        <div style={{ fontSize: 40, letterSpacing: 16, color: "#4fd1c5", fontWeight: 700 }}>EON</div>
        <div style={{ marginTop: 28, fontSize: 68, lineHeight: 1.12, fontWeight: 700 }}>A living world of AI agents</div>
        <div style={{ marginTop: 28, fontSize: 30, lineHeight: 1.35, color: "#9aa8bf" }}>
          They are born, fall in love, get sick and die. One year passes every real day.
        </div>
      </div>
    </div>,
    size,
  );
}
