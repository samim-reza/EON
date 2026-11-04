import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { pub } from "@/lib/pub";
import type { FamilyPerson } from "@/shared/types";

export const revalidate = 300;

// Rendered on first visit, then cached (ISR) — no agent pages are built ahead of time.
export async function generateStaticParams() {
  return [];
}
export const metadata: Metadata = { title: "Family tree" };

const GEN_LABEL: Record<number, string> = {
  [-3]: "Great-grandparents",
  [-2]: "Grandparents",
  [-1]: "Parents",
  0: "",
  1: "Children",
  2: "Grandchildren",
};

function Card({ p, root }: { p: FamilyPerson; root: boolean }) {
  return (
    <Link
      href={`/agents/${p.id}`}
      className={`panel block min-w-36 px-3 py-2 text-sm hover:border-ink-3 ${root ? "border-life" : ""} ${p.alive ? "" : "opacity-60"}`}
    >
      <div className={p.sex === "F" ? "text-love" : "text-life"}>{p.sex === "F" ? "♀" : "♂"}</div>
      <div className="font-medium">
        {p.name}
        {p.alive ? "" : " ✝"}
      </div>
    </Link>
  );
}

export default async function FamilyPage(props: PageProps<"/family/[id]">) {
  const raw = (await props.params).id;
  if (!/^\d{1,13}$/.test(raw)) notFound();
  const tree = await pub.family(Number(raw)).catch(() => null);
  if (!tree || tree.people.length === 0) notFound();
  const root = tree.people.find((p) => p.id === tree.root);
  const gens = [...new Set(tree.people.map((p) => p.gen))].sort((a, b) => a - b);
  return (
    <div className="mx-auto max-w-6xl px-4 py-10">
      <h1 className="text-2xl font-semibold">The family of {root?.name ?? "?"}</h1>
      <p className="mt-1 text-sm text-ink-2">Three generations up, two down. Dimmed names have passed away.</p>
      <div className="mt-8 space-y-8">
        {gens.map((g) => (
          <section key={g}>
            {GEN_LABEL[g] && <h2 className="mb-2 text-xs uppercase tracking-widest text-ink-3">{GEN_LABEL[g]}</h2>}
            <div className="flex flex-wrap gap-3">
              {tree.people
                .filter((p) => p.gen === g)
                .map((p) => (
                  <Card key={p.id} p={p} root={p.id === tree.root} />
                ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  );
}
