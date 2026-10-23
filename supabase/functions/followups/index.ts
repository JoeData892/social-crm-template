// POST /functions/v1/followups   header x-crm-key: <CRM_SHARED_SECRET>
//
// {"action": "nudge"}                       hourly from pg_cron. During the
//     CRM_NUDGE_HOUR window it sends one Pushover notification listing what is
//     due today, and only if something is due. At most once per day.
// {"action": "list", "now": "..."}          for the Follow-ups Shortcut:
//     everything due today as a menu of label -> item.
// {"action": "done" | "snooze" | "dismiss" | "texted" | "called",
//  "kind": "follow_up" | "birthday" | "date", "id": 12, "now": "..."}
//     what the user did. texted/called log the contact; nothing is ever sent
//     to anyone from here.
//
// No Claude calls: everything is decided in the database.

import { z } from "../_shared/deps.ts";
import { handle, HttpError, json, localToday, readJson, requireSecret } from "../_shared/http.ts";
import { db, rpc } from "../_shared/db.ts";
import { pushover } from "../_shared/pushover.ts";

interface Reminder {
  kind: "follow_up" | "birthday" | "date";
  id: number;
  people: string;
  person_ids: number[];
  phone: string | null;
  what: string;
  detail: string | null;
}

const NUDGE_HOUR = Number(Deno.env.get("CRM_NUDGE_HOUR") ?? 9);
// A failed push is retried on the next hourly runs within this many hours.
const NUDGE_WINDOW_HOURS = 3;
const SHORTCUT = Deno.env.get("CRM_FOLLOWUPS_SHORTCUT") ?? "Follow-ups";

const Action = z.object({
  action: z.enum(["done", "snooze", "dismiss", "texted", "called"]),
  kind: z.enum(["follow_up", "birthday", "date"]),
  id: z.number().int(),
});

function pushLine(r: Reminder): string {
  if (r.kind === "follow_up") return `• Ask ${r.people} about ${r.what}${r.detail ? ` (${r.detail})` : ""}`;
  return `• ${r.people}: ${r.what}`;
}

function menuItem(r: Reminder) {
  const digits = r.phone?.replace(/[^\d+]/g, "") ?? "";
  return {
    kind: r.kind,
    id: r.id,
    label: `${r.people}: ${r.what}`,
    detail: r.detail ?? "",
    phone: r.phone ?? "",
    sms_url: digits ? `sms:${digits}` : "",
    tel_url: digits ? `tel:${digits}` : "",
  };
}

Deno.serve(handle(async (req) => {
  await requireSecret(req);
  const body = await readJson(req);
  const { date, hour } = localToday(body.now);
  const client = db();

  if (body.action === "nudge") {
    if (hour < NUDGE_HOUR || hour >= NUDGE_HOUR + NUDGE_WINDOW_HOURS) {
      return json({ ok: true, status: "outside_window" });
    }
    // Claim today's run; a second call the same day does nothing.
    const claim = await client.from("nudge_runs").insert({ run_date: date, status: "sending" });
    if (claim.error) {
      if (claim.error.code === "23505") return json({ ok: true, status: "already_ran" });
      throw new Error(claim.error.message);
    }
    try {
      const due = await rpc<Reminder[]>(client, "crm_due_reminders", { p_today: date, p_for_push: true });
      if (due.length === 0) {
        await client.from("nudge_runs").update({ status: "nothing_due" }).eq("run_date", date);
        return json({ ok: true, status: "nothing_due" });
      }
      await pushover({
        title: due.length === 1 ? "1 follow-up today" : `${due.length} follow-ups today`,
        lines: due.map(pushLine),
        url: `shortcuts://run-shortcut?name=${encodeURIComponent(SHORTCUT)}`,
        urlTitle: "Open Follow-ups",
      });
      await rpc(client, "crm_mark_reminded", {
        p_hook_ids: due.filter((r) => r.kind === "follow_up").map((r) => r.id),
        p_today: date,
      });
      await client.from("nudge_runs").update({ status: "sent", item_count: due.length }).eq("run_date", date);
      return json({ ok: true, status: "sent", count: due.length });
    } catch (e) {
      // Release the claim so the next hourly run retries.
      await client.from("nudge_runs").delete().eq("run_date", date);
      throw e;
    }
  }

  if (body.action === "list") {
    const due = await rpc<Reminder[]>(client, "crm_due_reminders", { p_today: date, p_for_push: false });
    const menu: Record<string, ReturnType<typeof menuItem>> = {};
    for (const r of due) {
      const item = menuItem(r);
      const key = item.label in menu ? `${item.label} (#${r.id})` : item.label;
      menu[key] = item;
    }
    return json({ ok: true, count: due.length, message: due.length ? "" : "Nothing to follow up on today.", menu });
  }

  const parsed = Action.safeParse(body);
  if (!parsed.success) throw new HttpError(400, "Unknown action.");
  const { action, kind, id } = parsed.data;
  const { data, error } = await client.rpc("crm_follow_up_action", { p_kind: kind, p_id: id, p_action: action, p_today: date });
  if (error) throw new HttpError(400, error.message);
  return json(data);
}));
