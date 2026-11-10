/** The two emails EON sends a player. Pure, so the wording can be tested and reviewed. */
export type EmailFacts = { username?: string; name?: string; mother?: string; father?: string; place?: string };
export type Email = { subject: string; text: string; html: string };

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c);

function render(lines: string[], link: string, linkText: string): Pick<Email, "text" | "html"> {
  const footer = "You are getting this because you asked for a life in EON.";
  return {
    text: [...lines, "", `${linkText}: ${link}`, "", footer].join("\n"),
    html: `${lines.map((l) => `<p>${esc(l)}</p>`).join("")}<p><a href="${esc(link)}">${esc(linkText)}</a></p><p style="color:#888;font-size:12px">${esc(footer)}</p>`,
  };
}

export function bornEmail(f: EmailFacts, site: string): Email {
  const name = f.name ?? "Your child";
  const parents = f.mother && f.father ? `, to ${f.mother} and ${f.father}` : "";
  return {
    subject: `You are born: ${name}`,
    ...render([
      `${name} was born today${f.place ? ` in ${f.place}` : ""}${parents}. You are their soul now.`,
      "For their first three days, EON gives them a mind: their thoughts, and the choices you do not make in time. You make the big choices yourself, though the people around them, and the Creator, may have their say.",
      "After three days, connect your own AI (a free Gemini or Groq key works) to keep them thinking and choosing. Without one they live by habit, and you can only watch.",
    ], `${site}/me`, "Open your life"),
  };
}

export function trialOverEmail(f: EmailFacts, site: string): Email {
  const name = f.name ?? "Your person";
  return {
    subject: `${name} needs your AI now`,
    ...render([
      `${name}'s first three days are over, and EON's own mind has stepped back.`,
      "Connect your own AI key to give them a mind again. A free Gemini or Groq key takes two minutes. Until then they live by habit, and you can only watch.",
    ], `${site}/me`, "Connect your AI"),
  };
}
