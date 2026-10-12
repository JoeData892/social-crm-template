---
name: weekly-social-engagement-nudge
description: Check Building-tier CRM contacts due for follow-up and, if Saturday has no social event, suggest Local friends overdue for contact. Use when the user requests the weekly social nudge or an already configured task invokes it; deliver through the configured notification channel.
---

Requires a configured Social CRM base, current table/field/choice IDs, Google Calendar
access, the user's calendar timezone, and an authorized Telegram destination. Keep
schema dependencies in the user's private automation inventory. This is a read-only
CRM report; it does not create a schedule or contact anyone on the user's behalf.

Run the user's social engagement check using the current local date.

Use the configured Airtable connector for CRM access. Verify tool availability and
parameter shapes in this environment; connector access is not guaranteed in every runtime.
For every fetch below, use the connector's supported page size and follow all pagination
cursors before client-side ranking, filtering or selecting recent interactions. If the
notifier is unavailable or unauthorized, return the report in the current session.

There are **two independent checks**: the **Building bump scan (STEP 1) runs every week no matter what**, and the **weekend-social nudge (STEPS 2–3) only runs if Saturday is open**. They are combined into one Telegram in STEP 4.

If the Airtable MCP tools aren't loaded:
```
ToolSearch { query: "select:mcp__<airtable-mcp-server-id>__list_records_for_table", max_results: 1 }
```

---

## STEP 1 — Building-tier bump scan (ALWAYS runs)

"Building" is the Relationship Tier for people the user is actively turning into friends — not friends yet, but he wants to keep the energy up. Each has a personal cadence in the **Follow Up Frequency** field. This step flags the ones who've gone quiet past *their own* cadence.

Call `mcp__<airtable-mcp-server-id>__list_records_for_table` with:
- `baseId`: `<YOUR_BASE_ID>`
- `tableId`: `<TBL_PEOPLE_ID>` (People)
- `filters`: `{operator: "and", operands: [{operator: "isAnyOf", operands: ["<FIELD_ID>", ["<CHOICE_ID>"]]}]}` (Relationship Tier = Building)
- `fieldIds`: `["<FIELD_ID>", "<FIELD_ID>", "<FIELD_ID>", "<FIELD_ID>", "<FIELD_ID>"]` (Name, Last Contacted, Follow Up Frequency, Location, Phone)
- `pageSize`: the connector's supported size

For each returned person, compute whether they're **due for a bump**, client-side:

1. **Cadence → days** (map the Follow Up Frequency choice name):
   - `Weekly` → 7
   - `Every 2 weeks`, `Frequent` → 14
   - `Monthly check-in`, `Occasional text` → 30
   - `Every 6 weeks` → 42
   - `Occasional drinks`, `Brunch` → 45
   - `Quarterly` → 90
   - `Twice a year` → 182
   - `Annual / Life events` → 365
   - `As needed` → **skip this person entirely** (no auto-surfacing)
   - **unset / blank** → default 30 (a warm prospect with no cadence still surfaces; note "no cadence set")
2. **Days since contact**: `today − Last Contacted`. If Last Contacted is blank → treat as **never contacted** (always due, highest priority).
3. **Due** if never contacted, OR `daysSinceContact >= cadenceDays`.
4. Sort the due people: never-contacted first, then by **most overdue** (`daysSinceContact − cadenceDays`) descending. Cap at **7**.

Hold this list for STEP 4. If nobody is due, the bump section is simply omitted.

**Choice-ID drift:** if the Building filter returns nothing unexpectedly, re-fetch IDs via `get_table_schema` with `tables: [{tableId: "<TBL_PEOPLE_ID>", fieldIds: ["<FIELD_ID>", "<FIELD_ID>"]}]` and retry once.

---

## STEP 2 — Check Google Calendar for Saturday (gates STEP 3 only)

Calculate this coming Saturday's date. Use the Google Calendar MCP (`mcp__<gcal-mcp-server-id>__list_events`) to fetch events on Saturday:
- calendarId: "primary"
- startTime: Saturday at 00:00:00 in the user's configured timezone
- endTime: Sunday at 00:00:00 in that timezone (exclusive)
- timeZone: the user's configured calendar timezone

If calendar access or timezone is unavailable, keep the Building scan, omit the weekend
list, and report that calendar availability could not be checked. Do not assume an empty
calendar or infer the user's location.

A "social event" is any event that involves other people — dinner, party, drinks, brunch, birthday, group run, social gathering, concert with friends, etc. Exclude: solo workouts, work events, appointments, errands, reminders, all-day informational events (reminder-style entries with no attendees).

- If Saturday has at least one social event → **skip STEP 3** (no weekend list); note the event name for STEP 4.
- If Saturday is free → continue to STEP 3.

(Note: this only gates the weekend list. The STEP 1 bump scan already ran regardless.)

## STEP 3 — Pull 5 Local friends from the CRM (only if Saturday is open)

**Filtering logic:** The CRM's `Tags` multipleSelects field has a **"Local"** option
(`<CHOICE_ID>`) for people the user can realistically meet nearby. Use that tag rather
than a location-string match; no particular Airtable view is required.

Call `mcp__<airtable-mcp-server-id>__list_records_for_table` with:
- `baseId`: `<YOUR_BASE_ID>`
- `tableId`: `<TBL_PEOPLE_ID>` (People)
- `filters`: structured, AND of two conditions:
  1. Tags `hasAnyOf` `["<CHOICE_ID>"]` (the Local choice ID, on field `<FIELD_ID>`)
  2. Relationship Tier `isAnyOf` `["<CHOICE_ID>", "<CHOICE_ID>"]` (Friend, Close Friend on field `<FIELD_ID>`)
- `fieldIds`: `["<FIELD_ID>", "<FIELD_ID>", "<FIELD_ID>", "<FIELD_ID>"]` (Name, Last Contacted, Location, Follow Up Frequency)
- `pageSize`: the connector's supported size

The MCP server's sort param has been unreliable; sort client-side instead. Sort the records so `Last Contacted` ascending — records with **no** Last Contacted (never contacted) come first, then oldest to newest. Take the first 5.

**Choice ID verification:** if the Local tag choice ID changes (the user renames it, or you suspect a stale ID), call `get_table_schema` with `tables: [{tableId: "<TBL_PEOPLE_ID>", fieldIds: ["<FIELD_ID>", "<FIELD_ID>"]}]` to re-fetch current choice IDs. Same if Relationship Tier choices shift.

**If the Airtable MCP errors or returns nothing on either pull:** retry the call once, and re-fetch choice IDs via `get_table_schema` if a filter returned zero records unexpectedly. If it still fails, report which CRM pull failed and exit; use Telegram only through the configured, authorized channel. Do NOT fall back to Chrome or direct API calls — the MCP connector is the only Airtable path for this task.

## STEP 3.5 — Attach conversation openers (Follow-up Hooks)

Read **Follow-up Hooks** from Interactions for the people the report will show.

1. Collect the record IDs of every person who will be SHOWN in Section A and Section B. If that set is empty, skip this step.
2. Fetch Interactions using `mcp__<airtable-mcp-server-id>__list_records_for_table`, following every page:
   - `baseId`: `<YOUR_BASE_ID>`
   - `tableId`: `<TBL_INTERACTIONS_ID>` (Interactions)
   - `fieldIds`: `["<FIELD_ID>", "<FIELD_ID>", "<FIELD_ID>", "<FIELD_ID>"]` (Person, Date, Summary, Follow-up Hooks)
   - `sort`: `[{fieldId: "<FIELD_ID>", direction: "desc"}]` (the Date field; sort takes field IDs, a field name returns an error)
   - `pageSize`: the connector's supported size
3. For each shown person, look at their **three most recent** interactions (Person contains their record ID). Take the hooks from the most recent one whose Follow-up Hooks is non-blank. Drop any line that starts with `(resolved`. Keep at most 2 hooks.
4. Hold them for STEP 4 as that person's opener line. A person with no hooks gets no opener line; never invent one from Summary, Notes, or anything else.

If this call fails, send the nudge without openers and say so in the STEP 5 report. Openers are an extra, never a reason to skip the Telegram.

## STEP 4 — Compose and send ONE Telegram via Telegram MCP

Send only through the user's configured, authorized notifier. The
[telegram-notifier-mcp](https://github.com/dtiger1889-ops/telegram-notifier-mcp) server is
one supported option; use its configured recipient, never an inferred destination.

1. If `mcp__Telegram_Notifier__send_message` is in your active tool list, call it directly.
2. If not: `ToolSearch { query: "select:mcp__Telegram_Notifier__send_message", max_results: 1 }`, then call it.
3. Signature: `mcp__Telegram_Notifier__send_message({ text, parse_mode?: "Markdown" })`.
4. If ToolSearch doesn't return the tool, log the contents in your final report with a "couldn't deliver to Telegram" note and exit.

Assemble the message from whichever sections apply:

**Section A — Building bumps (include only if STEP 1 found due people):**
```
🌱 *Warm prospects due for a bump*

People you're building with who've gone quiet past their cadence:

1. *<Name>* — <Follow Up Frequency or "no cadence set">; last contact <YYYY-MM-DD> (<N>d ago, <M>d overdue)
2. ...
```
For never-contacted, write `never contacted yet — kick it off` instead of the date/overdue part.
**Opener line (Sections A and B):** if STEP 3.5 found hooks for a shown person, add one indented line directly under their entry: `   💬 Ask about: <hook>; <hook> (from <YYYY-MM-DD>)`.

**Section B — Weekend social (include only if Saturday was open, STEP 3 ran):**
```
🍹 *Weekend Social Check — Saturday is open!*

Your calendar is free Saturday. Here are 5 friends to reach out to for Friday drinks or Saturday brunch:

1. *<Name>* — last contact: <YYYY-MM-DD> · <Follow Up Frequency>
   📍 <Location>
2. ...

_Reach out by Wednesday to lock something in._
```
If Last Contacted is null, write `never contacted`. If Follow Up Frequency is null, omit the ` · <freq>` segment.

**Combining rules:**
- Both sections apply → send Section A, then a blank line, then Section B.
- Only one applies → send just that one.
- **Neither applies** (no bumps due AND Saturday is booked) → send a short confirmation: `✅ You're already social this Saturday — <event name>. And no warm-prospect bumps are due. Nothing to chase this week!`
- If a section could not be checked, state that limitation rather than using the
  "nothing due" confirmation. Show however many candidates were found, even if fewer
  than the output cap.

## STEP 5 — Report

Brief summary of what was sent: the Building bump names (if any) and the 5 weekend names (if sent), plus how many got an opener line (STEP 3.5).

## Notes
- **Airtable MCP is the only CRM path for this task.** If it is unavailable after the
  bounded retry, report the limitation; do not switch to Chrome or raw credentials.
- Google Calendar MCP tools are named `mcp__<gcal-mcp-server-id>__*` (the server id is a UUID specific to your claude.ai connector; find it in your tool list).
- Airtable MCP tools are named `mcp__<airtable-mcp-server-id>__*`.
- The cadence→days mapping in STEP 1 mirrors the on-demand "bump scan" in the social-crm skill; keep the two in sync if either changes.
