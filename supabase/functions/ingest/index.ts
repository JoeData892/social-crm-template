// POST /functions/v1/ingest   header x-crm-key: <CRM_SHARED_SECRET>
// body: {"text": "<dictated note>", "now": "<ISO 8601 with offset, optional>"}
// -> {"ok": true, "message": "<notification text>", "note_id": 12}
//
// Stores the raw transcript first (so nothing is ever lost), has Claude turn it
// into a plan, applies the plan atomically with crm_apply_plan, then refreshes
// search embeddings in the background.

import type { SupabaseClient } from "../_shared/deps.ts";
import { background, handle, json, localToday, readJson, requireSecret, requireText } from "../_shared/http.ts";
import { db } from "../_shared/db.ts";
import { backfillEmbeddings, refreshEmbeddings } from "../_shared/embed.ts";
import { runAgent, tool } from "../_shared/claude.ts";
import { readTools } from "../_shared/read_tools.ts";
import { buildContext } from "../_shared/context.ts";
import { Plan } from "../_shared/plan.ts";
import { INGEST_SYSTEM } from "../_shared/prompts.ts";

interface Applied {
  touched_people: number[];
  interaction_ids: number[];
  flags: string[];
  info: string[];
}

interface Reply {
  ok: boolean;
  message: string;
  note_id: number;
  pending?: boolean;
}

const EFFORT = (Deno.env.get("CRM_INGEST_EFFORT") ?? "medium") as "low" | "medium" | "high";
// iOS Shortcuts gives up on slow requests; answer before that and finish in the background.
const REPLY_AFTER_MS = Number(Deno.env.get("CRM_REPLY_AFTER_MS") ?? 45_000);

function notification(confirmation: string, applied: Applied): string {
  const lines = [confirmation.trim(), ...applied.info, ...applied.flags.map((f) => `? ${f}`)];
  const msg = lines.filter(Boolean).join("\n");
  return msg.length > 1200 ? msg.slice(0, 1197) + "..." : msg;
}

async function markError(client: SupabaseClient, noteId: number, error: string) {
  await client.from("voice_notes").update({
    status: "error",
    error: error.slice(0, 2000),
    processed_at: new Date().toISOString(),
  })
    .eq("id", noteId);
}

async function fileNote(
  client: SupabaseClient,
  noteId: number,
  transcript: string,
  today: string,
  weekday: string,
): Promise<Reply> {
  try {
    const context = await buildContext(client, today, weekday);
    const reads = readTools(client, today);
    const state: { applied?: Applied; saves: number } = { saves: 0 };

    const savePlan = tool({
      name: "save_plan",
      description:
        "Apply the complete plan for this voice note in one transaction. On error nothing is saved; fix the plan and call again.",
      schema: Plan,
      run: async (plan) => {
        if (++state.saves > 4) return { content: "Too many failed save attempts; stop.", isError: true };
        const { data, error } = await client.rpc("crm_apply_plan", {
          p_plan: { ...plan, occurred_on: plan.occurred_on ?? today },
          p_note_id: noteId,
          p_requested_by: "voice note",
        });
        if (error) {
          return {
            content: `The database rejected the plan and saved nothing: ${error.message}. Fix the plan and call save_plan again.`,
            isError: true,
          };
        }
        state.applied = data as Applied;
        return { content: plan.confirmation, done: true };
      },
    });

    const run = await runAgent({
      system: INGEST_SYSTEM,
      user: `${context}\n\n<voice_note>\n${transcript}\n</voice_note>`,
      tools: [reads.find_people, reads.get_person, reads.search_rosters, reads.search_memory, savePlan],
      effort: EFFORT,
      maxTurns: 12,
    });

    if (!run.done || !state.applied) {
      const why = run.text || "No plan was saved.";
      await markError(client, noteId, why);
      return { ok: false, note_id: noteId, message: `Your note is saved (#${noteId}) but wasn't filed: ${why}`.slice(0, 1200) };
    }

    background(
      refreshEmbeddings(client, {
        noteId,
        people: state.applied.touched_people,
        interactions: state.applied.interaction_ids,
      }).then(() => backfillEmbeddings(client)),
    );
    return { ok: true, note_id: noteId, message: notification(run.text, state.applied) };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`note ${noteId} failed:`, msg);
    await markError(client, noteId, msg);
    return { ok: false, note_id: noteId, message: `Your note is saved (#${noteId}) but filing failed: ${msg}`.slice(0, 1200) };
  }
}

Deno.serve(handle(async (req) => {
  await requireSecret(req);
  const body = await readJson(req);
  const transcript = requireText(body, "text", 10_000);
  const { date, weekday, spokenAt } = localToday(body.now);
  const client = db();

  const { data: note, error } = await client.from("voice_notes")
    .insert({ transcript, spoken_at: spokenAt, status: "processing" })
    .select("id").single();
  if (error) throw new Error(error.message);

  const work = fileNote(client, note.id, transcript, date, weekday);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<null>((resolve) => timer = setTimeout(() => resolve(null), REPLY_AFTER_MS));
  const reply = await Promise.race([work, timeout]);
  clearTimeout(timer);

  if (reply === null) {
    background(work);
    return json({
      ok: true,
      pending: true,
      note_id: note.id,
      message: "Got it. Still filing this one; it will be in your CRM in a minute.",
    });
  }
  return json(reply);
}));
