// POST /functions/v1/ask   header x-crm-key: <CRM_SHARED_SECRET>
// body: {"question": "...", "now": "<ISO 8601 with offset, optional>"}
// -> {"ok": true, "answer": "<plain text>"}
//
// Read-only: every tool here is a SELECT. Questions are not stored.

import { handle, json, localToday, readJson, requireSecret, requireText } from "../_shared/http.ts";
import { db } from "../_shared/db.ts";
import { runAgent } from "../_shared/claude.ts";
import { readTools } from "../_shared/read_tools.ts";
import { ASK_SYSTEM } from "../_shared/prompts.ts";

const EFFORT = (Deno.env.get("CRM_ASK_EFFORT") ?? "low") as "low" | "medium" | "high";

Deno.serve(handle(async (req) => {
  await requireSecret(req);
  const body = await readJson(req);
  const question = requireText(body, "question", 2_000);
  const { date, weekday } = localToday(body.now);

  const run = await runAgent({
    system: ASK_SYSTEM,
    user: `Today is ${weekday}, ${date}.\n\n<question>\n${question}\n</question>`,
    tools: Object.values(readTools(db(), date)),
    effort: EFFORT,
    maxTurns: 8,
  });
  return json({ ok: true, answer: run.text || "I couldn't find anything on that." });
}));
