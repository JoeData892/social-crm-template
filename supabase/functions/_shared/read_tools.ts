import { type SupabaseClient, z } from "./deps.ts";
import { rpc } from "./db.ts";
import { embed } from "./embed.ts";
import { type Tool, tool } from "./claude.ts";

// Read-only tools. Results go back to the model as compact JSON.

const out = (v: unknown) => ({ content: JSON.stringify(v ?? null) });
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "YYYY-MM-DD");

export function readTools(client: SupabaseClient, today: string): Record<string, Tool> {
  return {
    find_people: tool({
      name: "find_people",
      description:
        "Fuzzy-search contacts by name, nickname or alias (tolerates typos and dictation misspellings). Returns candidates with a 0-1 score.",
      schema: z.object({ query: z.string().min(1) }),
      run: async ({ query }) => out(await rpc(client, "crm_find_people", { q: query, lim: 8 })),
    }),

    get_person: tool({
      name: "get_person",
      description:
        "Everything on file for one contact: fields, groups, partner, open follow-up hooks (with hook_id), last 5 interactions, events, rosters they appear on.",
      schema: z.object({ id: z.number().int() }),
      run: async ({ id }) => {
        const card = await rpc(client, "crm_person_card", { p_id: id });
        return card ? out(card) : { content: `No contact #${id}`, isError: true };
      },
    }),

    search_memory: tool({
      name: "search_memory",
      description:
        "Search everything by meaning and keywords: interactions (with their hooks), original voice-note transcripts, and contact profiles. Use for questions like 'who is moving to Denver' or 'the guy who does pottery'.",
      schema: z.object({ query: z.string().min(1), limit: z.number().int().min(1).max(25).optional() }),
      run: async ({ query, limit }) =>
        out(
          await rpc(client, "crm_search", { q: query, query_embedding: await embed(query).catch(() => null), lim: limit ?? 10 }),
        ),
    }),

    search_rosters: tool({
      name: "search_rosters",
      description: "Find a name on past rosters (name lists from events), even if they are not a contact.",
      schema: z.object({ name: z.string().min(1) }),
      run: async ({ name }) => out(await rpc(client, "crm_search_rosters", { q: name })),
    }),

    roster_recurrence: tool({
      name: "roster_recurrence",
      description:
        "Names that keep showing up across rosters (promotion candidates). existing_person_id is set when they are already a contact.",
      schema: z.object({ min_appearances: z.number().int().min(2).optional() }),
      run: async ({ min_appearances }) => out(await rpc(client, "crm_roster_recurrence", { p_min: min_appearances ?? 3 })),
    }),

    people_due: tool({
      name: "people_due",
      description:
        "Who is due for a reach-out based on each person's own follow-up cadence and last contact. Optionally restrict to tiers. Rows are sorted most overdue first; only rows with due=true are actually due.",
      schema: z.object({ tiers: z.array(z.string()).optional() }),
      run: async ({ tiers }) => out(await rpc(client, "crm_people_due", { p_tiers: tiers ?? null, p_today: today })),
    }),

    upcoming_birthdays: tool({
      name: "upcoming_birthdays",
      description: "Birthdays in the next N days. turning is null when the birth year is unknown.",
      schema: z.object({ days: z.number().int().min(1).max(366) }),
      run: async ({ days }) => out(await rpc(client, "crm_upcoming_birthdays", { p_days: days, p_today: today })),
    }),

    upcoming_follow_ups: tool({
      name: "upcoming_follow_ups",
      description:
        "Open follow-ups (things to ask people about) whose reminder date falls within the next N days, including overdue ones, soonest first.",
      schema: z.object({ days: z.number().int().min(0).max(90) }),
      run: async ({ days }) => out(await rpc(client, "crm_upcoming_follow_ups", { p_today: today, p_days: days })),
    }),

    recent_interactions: tool({
      name: "recent_interactions",
      description: "Interactions on or after a date, newest first, with participants and still-open hooks.",
      schema: z.object({ since: isoDate, limit: z.number().int().min(1).max(100).optional() }),
      run: async ({ since, limit }) => out(await rpc(client, "crm_recent_interactions", { p_since: since, lim: limit ?? 30 })),
    }),
  };
}
