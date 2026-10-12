# CRM field semantics

Read the table section relevant to the task: People, Groups, Events, Interactions,
Rosters, or Changelog. Setup's machine-readable specification is
[../schema.json](../schema.json). Roster matching is in [rosters.md](rosters.md).

## Tables

Fetch current schema through the configured connector at task start. With authorized
REST access, the equivalent endpoint is:
```
GET https://api.airtable.com/v0/meta/bases/<YOUR_BASE_ID>/tables
```

### People (<TBL_PEOPLE_ID>)
The main contact table. One record per person.

| Field Name | Type | Purpose / Notes |
|---|---|---|
| Name | singleLineText | Full name or primary identifier |
| Community Name | singleLineText | Nickname used in a social scene or club, if any |
| Nicknames / Aliases | multilineText | Common nicknames or alternate names, one per line. **Also the home for roster spelling variants** — see the auto-match rules under "Adding a roster". |
| Phone | phoneNumber | Primary phone |
| Email | email | Primary email |
| Instagram / Social | url | Primary social media profile. If links from different networks tend to overwrite each other, split this into a dedicated "Instagram" URL field plus this legacy/other field, and always write a new link to the empty one. |
| Location | multilineText | Street address or a rough area description |
| Birthday | date | Format: YYYY-MM-DD |
| Known Since | date | Approximate date first met — use YYYY-01-01 if only year known |
| Relationship Tier | singleSelect | Close Friend, Friend, Acquaintance, **Building**, etc. — see "Relationship Tier options" below. `Building` = someone the user is actively turning into a friend (not a friend yet). |
| Follow Up Frequency | singleSelect | Per-person contact cadence — how often the user wants to reach out. Drives the bump scan. See "Follow Up Frequency (cadence)" below. |
| Next Follow-Up | date | Optional MANUAL override date for the next planned reach-out. Not auto-computed; the bump scan derives due-ness from Last Contacted + cadence, but the user can set this by hand to pin a specific date. |
| Last Contacted | date | Date of most recent real-world contact |
| Tags | multipleSelects | Cross-cutting labels (the schema.json starter set: College, Work, Travel, Local, ...). A "Local" tag is useful for scoping scans to people nearby. |
| Member Status | singleSelect | Current Member / Former Member — standing in the user's primary scene or club, if they have one. Rename or drop if not applicable. |
| Likes & Interests | multilineText | Hobbies, preferences, things they enjoy |
| Family and Pets | multilineText | Spouses, kids, pets — people close to them who don't have their own record. One relation per line in the form "Relation: Name"; use "(name unknown)" where a name is not known |
| Job/Employer | singleLineText | Job title and/or employer (field ID: <FIELD_ID>) |
| How We Met | multilineText | Brief context for where/how the user met this person |
| History | multilineText | Longer-arc relationship backstory that doesn't fit a single interaction |
| Notes | multilineText | **Catch-all / last resort.** Data here should be minimal. If it belongs in a structured field, move it there. |
| Romantic Interest | singleSelect | See options below |
| Partner | linkedRecord → People | Their partner/spouse when that person has their own record (self-link) |
| Groups | linkedRecord → Groups | **Clubs and groups this person belongs to.** This is a linked record — never store club/group names as text in Notes or any other field. Look up or create the Group record and link it. |

(Plus auto-created reverse links from Interactions, Events, and Rosters — see schema.json.)

**Romantic Interest options** (with the user's definitions):
- `Interested` — the user is interested, doesn't know if mutual
- `Flirting` — something going on, not confirmed how strong
- `Mutual` — physical contact has happened (made out, hooked up, etc.)
- `Situationship` — ongoing something
- `Former Hookup` — was physical, no longer
- `Former Flame` — above a hookup level, no longer happening

**Relationship Tier options:** Close Friend, Friend, Acquaintance, Work Contact, Scene Friend, Scene Foe, Old Friend, **Building**.
- `Building` means someone the user wants to befriend but does not yet consider a
  friend. Set a Follow Up Frequency when known; move to Friend when the user says the
  relationship has changed.

**Follow Up Frequency (cadence)** — the per-person "how often do I want to reach out" dial. Each choice maps to a number of days; the **bump scan** computes "due for a bump" as `daysSince(Last Contacted) >= cadenceDays` (never-contacted = always due). Mapping:

| Follow Up Frequency | Days |
|---|---|
| Weekly | 7 |
| Every 2 weeks, Frequent | 14 |
| Monthly check-in, Occasional text | 30 |
| Every 6 weeks | 42 |
| Occasional drinks, Brunch | 45 |
| Quarterly | 90 |
| Twice a year | 182 |
| Annual / Life events | 365 |
| As needed | never auto-surfaces |
| (unset) | default 30 for Building people; otherwise not scanned |

These are configurable default day counts, including the informal labels; use the
user's chosen mapping when it differs.

### Groups (look up table ID via metadata)
Represents clubs, communities, friend groups, workplaces, etc.

| Field Name | Type | Purpose |
|---|---|---|
| Group Name | singleLineText | Group name (primary field) |
| Type | singleSelect | Friend Group, Social Circle, Group Chat, Community, Other |
| Group Subtype | singleLineText | Free-text refinement, e.g. Book Club, Running Club |
| Abbreviation | singleLineText | The short form the user actually says, so lookups match casual speech |
| Last Contacted | date | Last time the user showed up to this group |
| Notes | multilineText | Anything about the group itself |
| People | linkedRecord → People | Reverse link — populated automatically when People.Groups is set |

**CRITICAL: Clubs are Groups.** When someone's record mentions any recurring named club or group, that information belongs in the Groups linked record field — NOT in Notes, NOT in any text field. Look up the Group record by name (check Abbreviation too), or create it if it doesn't exist, then link it.

### Events (look up table ID via metadata)
Parties, trips, gatherings the user attended or hosted. An Event links the People who were there and can anchor a Roster (a party's name list hangs off its Event record).

| Field Name | Type | Purpose |
|---|---|---|
| Event Name | singleLineText | Primary field |
| Date | date | When it happened (YYYY-MM-DD) |
| Location | singleLineText | Where |
| Notes | multilineText | Context |
| People | linkedRecord → People | CRM contacts who were at this event |
| Rosters | linkedRecord → Rosters | Reverse link from Rosters.Event |

Attending an event together is context, not contact — linking a person to an Event does NOT replace an Interaction record. Log an Interaction only when the user reports actually talking/meeting per the Interactions rules below.

### Interactions (look up table ID via metadata — has description set)
Logs real-world contact events between the user and a person already in People.

Create an Interaction when the user reports contact with an existing person or asks
to log it. A request to update an existing Interaction edits that record. Mentioning
the word "interaction" in a question or explanation does not authorize a write.

| Field Name | Type | Purpose |
|---|---|---|
| Summary | singleLineText | One-line description of the contact event (primary field) |
| Date | date | When it happened |
| Type | singleSelect | Contact method: In Person, Phone Call, Text, Social Media, Email, Video Call |
| Location | singleLineText | Where, for in-person contact |
| Notes | multilineText | Longer detail beyond the Summary line |
| Person | linkedRecord → People | Who the interaction was with |
| Follow-up Hooks | multilineText | Forward-looking topics from the exchange worth raising next time, one per line, in the user's words. Append only. Read back by the pre-hangout recap and the weekly nudge. |

**CRITICAL: Only create an Interaction record when the user reports having real-world contact with an existing person** (a text, call, meeting, etc.). Do NOT create Interaction records when:
- Adding a new person to the CRM (even if the user says when they last talked)
- Adding a Roster (a name dump is not contact with anyone)
- Running data quality tasks
- Making schema changes

The Changelog covers record additions. Interactions cover contact events.

### Rosters (<TBL_ROSTERS_ID>)
Name-dump records — the user calls them "globs". One record = one list of names from an event, sign-up list, or social circle, kept as TEXT, not contacts. Most names on a roster will never become People records; the roster preserves them so recurrence is detectable months or years later.

**LANGUAGE TRIGGER:** When the user says "glob this", "add a roster", "here's the sign-up list", or dumps a list of names with event context — create ONE Rosters record. Do NOT create People records or Interactions for the names on it. DO auto-link the high-confidence matches to people already in the CRM (see the auto-match procedure under "Adding a roster").

| Field Name | Type | Purpose |
|---|---|---|
| Roster Name | singleLineText | Short label naming the source or host, the event, and the date |
| Date | date | When the event/list happened (YYYY-MM-DD) |
| Source | singleSelect | Event sign-up, Met in person, Online list, Friend's circle, Party invite list, Other |
| Names | multilineText | The dump. One name per line; optional context note after " — ". Nicknames welcome. |
| Anchor Group | linkedRecord → Groups | The club/group touchstone |
| Anchor Person | linkedRecord → People | The friend whose circle this is |
| Event | linkedRecord → Events | The Events record this corresponds to, when one exists |
| Notes | multilineText | Event context, vibes, anything not per-name |
| Promoted People | linkedRecord → People | Names from this roster that later became real contacts — the back-reference |

**Anchoring rule:** every roster links AT LEAST ONE of Anchor Group, Anchor Person, or Event; any combination is fine. An Event alone is a valid anchor (a party roster with no club or specific friend). Look up or create the anchor record before saving the roster.

### Changelog (look up table ID via metadata)
Audit log of changes made to the CRM.

| Field Name | Type | Purpose |
|---|---|---|
| Summary | singleLineText | One-line description of what changed |
| Date | date | When the change was made (use today's date) |
| Changes Made | multilineText | Detail of what was added/updated |
| Tables Affected | multipleSelects | Which tables were touched: People, Interactions, Events, Groups, Rosters, Changelog, Base Structure (pass names as strings with typecast: true if a new choice is needed) |
| Records Added | number | Count of new records created |
| Records Updated | number | Count of existing records patched |
| Requested By | singleLineText | Who asked for the change — useful when multiple people or automations write to the base |
| Open Questions / Flags | multilineText | Anything the agent flagged for human review instead of acting on |

Create a Changelog record for: adding new people, adding rosters, bulk updates, schema changes. Do NOT create Changelog records for routine data quality corrections (moving data between fields on the same record).

