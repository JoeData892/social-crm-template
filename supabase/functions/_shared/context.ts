import type { SupabaseClient } from "./deps.ts";
import { rpc } from "./db.ts";

// The per-note context Claude needs to resolve names without a lookup per
// person: today's date, a compact contact directory, groups, recent events
// and the current choice lists.

interface DirRow {
  id: number;
  name: string;
  also_known_as: string[];
  tier: string | null;
  groups: string[];
  last_contacted: string | null;
}

async function rows<T>(q: PromiseLike<{ data: T[] | null; error: { message: string } | null }>): Promise<T[]> {
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return data ?? [];
}

export async function buildContext(client: SupabaseClient, today: string, weekday: string): Promise<string> {
  const since = new Date(Date.parse(today) - 90 * 86400_000).toISOString().slice(0, 10);
  const [dir, groups, events, tiers, cadences, tagRows] = await Promise.all([
    rpc<DirRow[]>(client, "crm_directory"),
    rows<{ id: number; name: string; abbreviation: string | null; type: string | null }>(
      client.from("groups").select("id, name, abbreviation, type").order("name"),
    ),
    rows<{ id: number; name: string; date: string | null }>(
      client.from("events").select("id, name, date").gte("date", since).order("date", { ascending: false }),
    ),
    rows<{ name: string; description: string }>(
      client.from("relationship_tiers").select("name, description").order("sort_order"),
    ),
    rows<{ name: string; days: number | null }>(client.from("follow_up_cadences").select("name, days")),
    rows<{ tags: string[] }>(client.from("people").select("tags").neq("tags", "{}")),
  ]);

  const tags = [...new Set(tagRows.flatMap((r) => r.tags))].sort();
  const people = dir.map((p) =>
    [
      `#${p.id} ${p.name}`,
      p.also_known_as.length ? `aka ${p.also_known_as.join(", ")}` : "",
      p.tier ?? "",
      p.groups.join(", "),
      p.last_contacted ? `last contact ${p.last_contacted}` : "",
    ]
      .filter(Boolean).join(" | ")
  );

  return [
    `Today is ${weekday}, ${today} (the user's local date).`,
    `## Contacts (${dir.length})\n${people.join("\n") || "(none yet)"}`,
    `## Groups\n${
      groups.map((g) => `#${g.id} ${g.name}${g.abbreviation ? ` (${g.abbreviation})` : ""}${g.type ? ` | ${g.type}` : ""}`).join(
        "\n",
      ) || "(none yet)"
    }`,
    `## Events in the last 90 days\n${
      events.map((e) => `#${e.id} ${e.name}${e.date ? ` | ${e.date}` : ""}`).join("\n") || "(none)"
    }`,
    `## Relationship tiers\n${tiers.map((t) => `${t.name}: ${t.description}`).join("\n")}`,
    `## Follow-up frequencies\n${cadences.map((c) => c.days ? `${c.name} (${c.days} days)` : c.name).join(", ")}`,
    `## Tags in use\n${tags.join(", ") || "(none yet)"}`,
  ].join("\n\n");
}
