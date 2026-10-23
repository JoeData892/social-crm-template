---
name: social-crm
description: >
  Read and update the user's personal Social CRM in Supabase: contacts, groups,
  events, interactions with follow-up hooks, rosters of names from events, and
  the voice notes that feed it. Use when the user asks about people in their life
  ("what do I know about Sam", "who am I letting go cold", "seeing Dana tonight"),
  wants to add or change something in the CRM, or wants to review voice notes
  that were flagged or failed.
---

# Social CRM (Supabase)

The CRM lives in a Supabase Postgres database. Most data arrives from iPhone
voice notes through the `ingest` Edge Function; this skill is for querying and
editing it in conversation.

## Access

Use the connected **Supabase connector** (its `execute_sql` tool) against the
user's CRM project; list projects first if you don't know which one. In a
terminal session with `psql` and a connection string the user provides, the same
SQL works. If no access path is available, say so; never guess at data.

## Reading: use the helper functions

| Need | SQL |
|---|---|
| Find a person by (mis)spelled name or nickname | `select * from crm_find_people('sam rivra');` |
| Everything about one person (fields, groups, open hooks with ids, last 5 interactions, events, rosters) | `select crm_person_card(12);` |
| Search by keywords across interactions, hooks, transcripts, profiles | `select * from crm_search('denver move');` |
| Who is due for a reach-out | `select * from crm_people_due();` or `crm_people_due(array['Building'])` |
| Upcoming birthdays | `select * from crm_upcoming_birthdays(30);` |
| Recent interactions | `select * from crm_recent_interactions(current_date - 14);` |
| A name on past event rosters | `select * from crm_search_rosters('Jo Okafor');` |
| Names that keep showing up | `select * from crm_roster_recurrence(3);` |
| Follow-ups due today / coming up | `select * from crm_due_reminders(current_date);` / `select * from crm_upcoming_follow_ups(current_date, 14);` |
| Whole directory | `select * from crm_directory();` |

Plain `select`s on the tables (`people`, `groups`, `person_groups`, `events`,
`event_people`, `interactions`, `interaction_people`, `hooks`, `rosters`,
`roster_people`, `voice_notes`, `changelog`, `important_dates`, `nudge_runs`,
`relationship_tiers`, `follow_up_cadences`, `hook_kinds`) are fine for anything else. Never select the `embedding`
columns; they are large and meaningless to read.

`crm_search` here is keyword search only (pass no embedding); search by meaning
is available through the `ask` Shortcut.

**Pre-hangout recap** ("seeing Sam tonight"): resolve to exactly one person (two
plausible matches → ask which), read `crm_person_card`, then answer with open
hooks first (with the date each came up), a line per recent interaction, then
personal details (partner, family and pets, interests). Short enough for a phone.

**Bump scan** ("who am I letting go cold"): `crm_people_due`, report rows with
`due = true`, never-contacted first, then most overdue, with phone numbers and an
open hook as an opener when one exists. Read-only.

**Follow-ups**: hooks carry `kind`, `happens_on`/`happens_until` and a
`follow_up_on` reminder date; a morning push lists what's due. To mark one
handled, snooze it, or record that the user texted/called about it:
`select crm_follow_up_action('follow_up', <hook id>, 'done' | 'snooze' | 'dismiss' | 'texted' | 'called');`
Never contact anyone on the user's behalf.

## Writing: only through `crm_apply_plan`

Every change goes through one function that applies a JSON plan atomically and
enforces the data rules (fills empty fields only unless a field is listed in
`overwrite`, lists only grow, links only get added, Last Contacted never moves
backward, rosters need an anchor, every change is logged to `changelog`):

```sql
select crm_apply_plan($plan$ { ...plan JSON... } $plan$::jsonb, null, 'claude chat');
```

The plan format and filing rules are in
[references/filing-rules.md](references/filing-rules.md). Read it before your
first write in a session. Report back what the function returned, including
`flags` (things it refused to overwrite or found ambiguous) and `info`.

Do **not** `insert`, `update` or `delete` the tables directly, with two exceptions
the user must ask for explicitly:

- **Merging duplicates** or **deleting** a contact or record. Show what will
  change, get a yes, do it in one transaction, and insert a `changelog` row
  (`requested_by` = 'claude chat') describing it.
- **Changing choice lists**: insert/update rows in `relationship_tiers` or
  `follow_up_cadences` (renames cascade to people).

## Reviewing voice notes

```sql
select id, received_at, status, transcript, result_summary, flags, error
from voice_notes where status in ('needs_review', 'error') order by id;
```

- `needs_review`: the note was filed, but the agent had questions (`flags`). Ask
  the user, apply their answers with `crm_apply_plan`, then
  `update voice_notes set status = 'done' where id = …`.
- `error`: nothing from that note was filed. File it now: build a plan from the
  transcript using the filing rules and call
  `crm_apply_plan(plan, <note id>, 'claude chat')`. That marks the note done.
- `processing` for more than a few minutes means the function died mid-run;
  treat it like `error`.
