# Roster intake and recurrence

Use for name-list intake, matching existing contacts, and on-demand recurrence scans.
Field meanings are in [schema.md](schema.md), Rosters section. Returning a roster
name to the user is not authorization to promote it into a contact.

### Adding a roster ("glob this")
Trigger: the user dumps a list of names with event context, says "glob this", "add a roster", "here's the sign-up list", etc. Often arrives via dispatch from their phone on the way to or from an event — the procedure must work unattended.

**First, decide whether this is even a roster.** A roster is a bare list of mostly-strangers — names (and maybe a club) and little else, the kind of list where most entries will never become contacts. If instead the input carries per-person detail (phone numbers, jobs, how they're related, romantic interest) or is framed as a contact update, follow **Adding a new person** or **Updating a field** in [../SKILL.md](../SKILL.md), one contact at a time. A phone number next to a name, or wording like "update my CRM", is the tell. When it really is a name-dump:

1. Look up (or create) the anchor: Group (club/group), Person (the friend), and/or Event. At least one.
2. **POST to Rosters** — Names as given, one per line; Date; Source; Notes for event context.
3. **Auto-match against People and link the high-confidence hits.** See the procedure and confidence bar below. This is automatic; do not ask first.
4. **POST to Changelog** (1 record added; Tables Affected: Rosters, plus People if links changed).

Do NOT create People records or Interactions for roster names. Auto-matching links EXISTING contacts; it never promotes a stranger.

#### Auto-match procedure
1. Fetch every People record with a non-empty Name, Community Name, or Nicknames / Aliases using `list_records_for_table`, selecting those three fields. Use the connector's supported page size and follow its pagination cursor until no pages remain; only then build the name lookup.
2. Normalize both sides client-side before comparing: lowercase, strip punctuation and any placeholder prefix your community puts in front of a name, collapse whitespace, and drop a trailing parenthetical club/group.
3. Compare each roster line's name portion (everything before " — ") against all three People fields.
4. Link every high-confidence hit (see the bar below) into that roster's `Promoted People`.
5. When the matched spelling differs from the stored name, append the roster's spelling to that person's `Nicknames / Aliases` as `<roster spelling> (sign-up-list spelling)` — do not overwrite the stored name, and do not duplicate a variant already recorded.
6. Report: how many you linked, and separately the near-misses you did NOT link and why.

#### The confidence bar
**Link automatically — high confidence:**
- Exact match after normalization.
- Case, punctuation, spacing, or accent differences only.
- A single-character typo, transposition, or obvious phonetic variant of the same name.
- Trivial truncation or an added/removed parenthetical suffix.

**Do NOT link — flag instead:**
- A shared word or acronym fragment without corroborating identity evidence.
- A bare common first name with nothing else to anchor it, unless the club on the roster also matches that person's linked Group.
- Two different CRM people both plausibly matching one roster line.
- A fuzzy-search hit you cannot justify in one sentence. If explaining the match takes a paragraph, it is not high confidence.

When in doubt, leave the name unlinked and report the ambiguity.

**Writing the links safely:** `Promoted People` is a linked-record field, so read the roster's existing list first and write back the full union — linked-record updates REPLACE the array, they do not append. Pass plain record-ID strings; see **Linking a group** in [../SKILL.md](../SKILL.md). Re-read the roster afterward and confirm the links landed before reporting done.

### Recurrence scan (on demand only)
Trigger: the user asks "who keeps showing up", "run the roster scan", "any repeat names", etc. Never scheduled.
1. Fetch all Rosters (Names, Date, anchors).
2. Normalize names client-side: lowercase, strip any placeholder name prefix (same rule as the auto-match), collapse whitespace.
3. Count appearances per normalized name across rosters; also match each against People (Name, Community Name, Nicknames / Aliases).
4. Report: (a) names appearing on 3+ rosters that are NOT in People — promotion candidates, with their roster dates and anchors; (b) names already in People but not linked in those rosters' Promoted People — link these automatically if they clear the high-confidence bar above, and report what you linked.
5. Promotion to a NEW People record still needs the user's confirmation. Linking an EXISTING contact does not.
