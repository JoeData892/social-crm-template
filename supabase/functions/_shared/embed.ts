import type { SupabaseClient } from "./deps.ts";
import { rpc } from "./db.ts";

// 384-dim gte-small embeddings, computed inside the Edge Runtime (no extra
// provider). Returns null where the runtime model isn't available, so search
// degrades to full-text instead of failing.

type Session = { run(input: string, opts: { mean_pool: boolean; normalize: boolean }): Promise<unknown> };
type AiGlobal = { ai: { Session: new (model: string) => Session } };

let session: Session | null = null;

export async function embed(text: string): Promise<string | null> {
  const ai = (globalThis as { Supabase?: AiGlobal }).Supabase?.ai;
  if (!ai || !text.trim()) return null;
  session ??= new ai.Session("gte-small");
  const out = await session.run(text.slice(0, 4000), { mean_pool: true, normalize: true });
  return JSON.stringify(Array.from(out as ArrayLike<number>));
}

export async function refreshEmbeddings(
  client: SupabaseClient,
  ids: { noteId?: number; people?: number[]; interactions?: number[] },
): Promise<void> {
  if (ids.noteId) {
    const { data } = await client.from("voice_notes").select("transcript").eq("id", ids.noteId).single();
    const v = data && await embed(data.transcript);
    if (v) await client.from("voice_notes").update({ embedding: v }).eq("id", ids.noteId);
  }
  for (const id of ids.people ?? []) {
    const v = await embed(await rpc<string>(client, "crm_person_text", { p_id: id }) ?? "");
    if (v) await client.from("people").update({ embedding: v }).eq("id", id);
  }
  for (const id of ids.interactions ?? []) {
    const { data } = await client.from("interactions").select("type, summary, notes, hooks(hook)").eq("id", id).single();
    if (!data) continue;
    const hooks = (data.hooks as { hook: string }[] ?? []).map((h) => h.hook).join("\n");
    const v = await embed([`${data.type}: ${data.summary}`, data.notes, hooks].filter(Boolean).join("\n"));
    if (v) await client.from("interactions").update({ embedding: v }).eq("id", id);
  }
}

// Catch up on rows written without embeddings (e.g. by the Claude skill).
export async function backfillEmbeddings(client: SupabaseClient, limit = 10): Promise<void> {
  const missing = async (table: string) =>
    ((await client.from(table).select("id").is("embedding", null).limit(limit)).data ?? []).map((r) => r.id as number);
  const [people, interactions, notes] = await Promise.all([missing("people"), missing("interactions"), missing("voice_notes")]);
  await refreshEmbeddings(client, { people, interactions });
  for (const noteId of notes) await refreshEmbeddings(client, { noteId });
}
