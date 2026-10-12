---
name: social-crm
description: >
  Maintain a configured personal Airtable CRM: contacts, groups, interactions, event
  rosters, relationship follow-ups, and pre-meeting recaps. Use when the user asks to
  read or update this Social CRM, log contact, add a roster ("glob this"), or run its
  data-quality or follow-up scans. Requires the user's CRM base configuration.
---

# Social CRM — Personal Airtable CRM (template)

## What this is
A personal Social CRM built in Airtable for tracking relationships: friends, club contacts, acquaintances. The CRM records people, their contact info and context, their connections to groups (clubs, teams, etc.), events, interactions the user has with them, and Rosters — raw name-dumps from events that are kept as lists, not contacts.

**Building this base from scratch?** [schema.json](schema.json) is the machine-readable
specification; [SETUP.md](SETUP.md) creates it. For daily tasks, use the field semantics
and task references linked below. Keep these files together when installing the skill.

---

## Credentials & API Access

- **Airtable Base ID:** `<YOUR_BASE_ID>`
- **Airtable Token:** `<YOUR_AIRTABLE_TOKEN>`
- **Telegram Bot Token:** `<YOUR_TELEGRAM_BOT_TOKEN>`
- **Telegram Chat ID (the user):** `<YOUR_TELEGRAM_CHAT_ID>`

### Airtable access

Use the configured connector and fetch current schema before reading or writing.
Inspect active tool definitions for parameter shapes and pagination. Follow every page
before client-side filtering, ranking, matching or aggregation. For the reference
connector's conventions or an authorized local REST fallback, read
[references/access.md](references/access.md). If required access is unavailable, report
the limitation rather than inventing an empty result.
---

## Automated runs that depend on this CRM (read before any schema change)

Before changing tables, fields, select choices, or tiers, find configured automations
that use this base and reconcile their dependent IDs and rules. Keep the user's private
automation inventory beside their configuration. Scheduling or adding a notification
channel requires the user's authorization; these templates do not establish a cadence.

---

## Field semantics

Read only the relevant table sections in [references/schema.md](references/schema.md).
It defines the People fields, relationship tiers and cadence mapping; Groups, Events,
Interactions, Rosters, and Changelog fields; and the rules for when each record is created.
---

## Standard Operations

### Adding a new person
Create 2 records:
1. **POST to People** — populate all known structured fields. Never leave data in Notes if a proper field exists.
2. **POST to Changelog** — summarize the addition.

Do NOT create an Interaction record.

If the person has a club/group: look up the Group record by name first, then link it in the People POST.

**Roster cross-reference (do this on every add):** after creating the person, search Rosters.Names for their name(s) — real name, community name, nicknames. If they appear on rosters, link the new People record into each roster's Promoted People field, and tell the user the history (e.g., "they've been on 4 sign-up lists since January — set Known Since accordingly?"). Use the EARLIEST roster Date as the Known Since candidate and the roster's anchor as How We Met context.

### Rosters and recurrence

For a name list with event context, read [references/rosters.md](references/rosters.md)
and create one anchored Roster, linking only high-confidence existing contacts. For
repeat-name questions, use that reference’s on-demand recurrence scan. Neither procedure
promotes new names into People without the user’s confirmation.

### Bump scan — who's due for a reach-out (on demand)
Trigger: the user asks who is overdue for contact or requests a bump scan. This is the
on-demand, any-tier version; the optional weekly template scans Building contacts.

1. Decide scope from the user's phrasing:
   - Default / "warm prospects" / "people I'm building with" → filter Relationship Tier = **Building** (`<CHOICE_ID>`).
   - "everyone" / "all my friends" → no tier filter (scan all People with a Follow Up Frequency set).
   - A named tier → filter that tier.
2. `list_records_for_table` (People, `<TBL_PEOPLE_ID>`), fields: Name, Last Contacted (`<FLD_LAST_CONTACTED_ID>`), Follow Up Frequency (`<FIELD_ID>`), Location, Phone, Relationship Tier. Use the connector's supported page size and fetch every page.
3. Compute due-ness client-side using the **Follow Up Frequency → days** mapping in
   [references/schema.md](references/schema.md), People section:
   - `cadenceDays` from the choice name; `As needed` → skip; unset → 30 for Building, else skip.
   - `daysSinceContact = today − Last Contacted`; blank Last Contacted → never contacted (always due, top priority).
   - **Due** if never contacted OR `daysSinceContact >= cadenceDays`.
4. Report due people sorted never-contacted-first, then most-overdue first (`daysSinceContact − cadenceDays`). Show name, cadence, last-contact date + days overdue, and Phone so the user can act. This is a READ-ONLY report — do not create or modify records. When the user later says they reached out, that's a normal **interaction** log (which updates Last Contacted and clears the overdue state).

### Promoting a roster name to a contact
When the user confirms a recurring name deserves a record:
1. Create the People record. Known Since = earliest roster Date they appear on; How We Met = that roster's context; Groups = the roster's Anchor Group(s) if club-sourced.
2. Link the new person into Promoted People on EVERY roster where the name appears. Keep their name line in each roster's Names text — it is the historical record, not a duplicate.
3. Changelog entry (1 added to People, N rosters updated).

### Logging an interaction
When the user reports contact with an existing person, create one Interaction. Update
Last Contacted to the most recent reported contact date; do not move it backward when
logging an older exchange. No Changelog needed.

**Capture the follow-up hooks.** After writing Summary, pull every forward-looking topic out of what the user said into `Follow-up Hooks`, one per line: plans, trips, interviews, moves, health or family news still unfolding, anything they would want to ask about next time. Rules:
- **The user's words, not yours.** Paraphrase only to shorten; never add a topic they did not mention and never infer one from tone.
- **Forward-looking only.** Something that already happened and is closed stays in Summary/Notes; something with a next chapter (waiting to hear back, about to start, planning) is a hook.
- **Nothing forward-looking → leave the field blank.** Do not write "none".
- **Append only** on an existing record: read it first, add lines, write the whole value back.
- **Close the loop** when the next interaction with that person is logged: if the user says a hook got talked through or resolved, prefix that line on the OLD record with `(resolved YYYY-MM-DD) ` rather than deleting it.

### Pre-hangout recap ("seeing <name> tonight", "what did I talk about with <name>")
Read only.
1. Resolve the name to exactly one People record (see "Looking up a person"). Two plausible matches → list them and ask; never recap the wrong person.
2. `list_records_for_table` on Interactions with `fieldIds` for Person, Date, Type, Summary and Follow-up Hooks, `sort` by the Date field ID descending (sort takes field IDs, not names); keep the rows whose Person contains that record ID; take the last three.
3. Answer in this order: **open hooks first** (lines not prefixed `(resolved`), each with the date it came up; then a one-line Summary per interaction, newest first; then anything useful already on the People record (interests, family and pets, partner). Short enough to read on a phone.
4. No interactions logged → say so plainly and fall back to the People record. Do not pad with guesses.
5. Writes nothing. If the meetup happens and the user reports back, that is "Logging an interaction", which also closes any hook they say got talked through.

A scheduled nudge can attach the same hooks as an opener line to each person it surfaces; `scheduled-tasks/weekly-social-engagement-nudge/SKILL.md` STEP 3.5 does this.

### Looking up a person

**Preferred: `search_records` MCP tool** — free-text fuzzy search with token-order independence. Handles typos and partial names automatically.
```
<airtable-mcp>__search_records({
  baseId: "<YOUR_BASE_ID>",
  table: "People",
  query: "<name>",
  fields: "ALL_SEARCHABLE_FIELDS"
})
```

If search returns nothing and the user says the person exists, fetch all People using
the connector's pagination and compare names, aliases and available text fields
client-side. Skip missing fields and apply the identity confidence bar.

**Also search Rosters.** A person not in People may still be on rosters — run the same query against the Rosters table (Names field). Roster hits are prior co-presence history; report them ("on the May 3 and May 17 sign-up lists") even when no contact record exists.

**Fuzzy search is a candidate generator, not a decision.** Apply the confidence bar in
[references/rosters.md](references/rosters.md) before treating a fuzzy hit as the person.

**Chrome-fallback path — formula gotcha.** If you're using the Chrome `javascript_tool` fetch() path for any reason, Airtable's REST `filterByFormula` has a silent failure mode: `SEARCH()` and `LOWER()` can error on `BLANK()` haystacks, and a single errored row inside an `OR()` branch drops that row from results with no diagnostic. Coerce every field ref with `&""` and prefer `FIND` over `SEARCH`:

```
OR(
  FIND(LOWER("<name>"), LOWER({Name}&"")),
  FIND(LOWER("<name>"), LOWER({Community Name}&"")),
  FIND(LOWER("<name>"), LOWER({Nicknames / Aliases}&""))
)
```

### Updating a field
PATCH the People record. If moving data out of Notes into a proper field: set the target field AND clear Notes (or remove just that portion from Notes). Never overwrite a non-empty field — flag it for human review instead.

### Linking a group
1. Search Groups by name (and Abbreviation) — the Groups primary field is `Group Name`, not "Name".
2. If not found: create a new Group record.
3. Set the People record's `Groups` field to an array of record-ID **strings**.

Use the installed connector's documented linked-record shape. The reference connector
and Airtable REST record writes use arrays of record-ID strings. Read the record back
to verify the resulting links; a successful response alone does not prove they landed.

The same rule covers every linked field (`Groups`, `Interactions.Person`, and each linked field on `Rosters` and `Events`). And **linked-record updates REPLACE the whole array — they do not append**: to add one link, read the current list first and write back the full union, or you silently wipe the existing links.

---

## Data Quality Rules

- **Notes is a catch-all.** During authorized edits or maintenance, move misplaced
  content into structured fields. During read-only lookups, recaps, or scans, flag
  misplaced content without changing records.
- **Never overwrite a field that already has a value** without explicit instruction from the user. Flag it instead.
- **Clubs belong in Groups** (linked record) — never store club names as text anywhere.
- **Name dumps belong in Rosters** — never bulk-create People records from a list of names, and never paste a name list into a person's or group's Notes.
- **Job info** belongs in Job/Employer field — if that field doesn't exist yet, check schema first.
- **Addresses** → Location field
- **Birthdays** → Birthday field (YYYY-MM-DD)
- **When they met** → Known Since field and/or How We Met field. When the person appears on rosters, Known Since defaults to the EARLIEST roster date — do not leave it blank.
- **Family / partner / kids / pets without their own record** → Family and Pets field (multiline, one per line)
- **Partner who has their own People record** → the Partner linked field, set on BOTH records.
- **Roster spelling variants** → Nicknames / Aliases, tagged `(sign-up-list spelling)`. Never rename the canonical name to match a roster.

---

## Telegram Notifications
Send summaries only through the user's configured and authorized notification channel.
With no channel configured, report results in the session.

**Preferred: the configured Telegram MCP tool** `mcp__Telegram_Notifier__send_message`
(discover it through the runtime if deferred). Verify it is available in the run's
environment. Use direct HTTP only if the user configured and authorized that path.

**Optional configured HTTP delivery:** verify access before relying on it.
```js
const tgSend = (text) => fetch(`https://api.telegram.org/bot<YOUR_TELEGRAM_BOT_TOKEN>/sendMessage`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ chat_id: '<YOUR_TELEGRAM_CHAT_ID>', text })
}).then(r => r.json());
```
