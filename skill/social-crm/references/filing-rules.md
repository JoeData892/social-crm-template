# Filing rules and plan format

These are the same rules the voice-note pipeline follows (its prompt is
`supabase/functions/_shared/prompts.ts`; keep the two in sync).

## Plan format

All keys are optional except where marked. A **ref** is either a `"ref"` you
declare in this plan (e.g. `"p1"`) or an existing record id (`42`).

```jsonc
{
  "occurred_on": "2026-10-22",           // default date for everything below; usually today
  "groups": [{ "ref": "g1", "id": 3 }, { "ref": "g2", "name": "Tuesday Trivia", "type": "Friend Group",
              "subtype": "Pub quiz", "abbreviation": "TT", "notes": "...", "attended_on": "2026-10-22" }],
  "people": [{
    "ref": "p1", "id": 12,                  // existing contact; omit id and give "name" to create one
    "set": { "job": "...", "location": "...", "birthday": "1904-03-03", "known_since": "...",
             "relationship_tier": "Building", "follow_up_frequency": "Monthly", "how_we_met": "...",
             "community_name": "...", "phone": "...", "email": "...", "next_follow_up": "..." },
    "overwrite": ["job"],                   // fields the user explicitly corrected/updated
    "add": { "aliases": [], "socials": [], "tags": [], "likes_interests": [], "family_pets": ["Dog: Biscuit"] },
    "append": { "history": "...", "notes": "..." },
    "groups": ["g1"], "partner": "p2",
    "dates": [{ "label": "Wedding anniversary", "date": "2019-11-02", "remind_days_before": 3 }]
  }],
  "events": [{ "ref": "e1", "name": "Maya's 30th", "date": "...", "location": "...", "notes": "...", "people": ["p1"] }],
  "interactions": [{ "date": "...", "type": "In Person",   // * In Person | Phone Call | Text | Social Media | Email | Video Call
                     "summary": "One line", "location": "...", "notes": "...",
                     "people": ["p1"],                      // * at least one
                     "hooks": [{ "text": "Move to Denver", "person": "p1", "kind": "move",
                                 "happens_on": "2027-05-01", "happens_until": "2027-05-31", "date_precision": "month",
                                 "follow_up_on": null }] }],      // follow_up_on only if the user said when
  "resolve_hooks": [{ "id": 31, "resolution": "Decided to stay" }],
  "update_hooks": [{ "id": 32, "happens_on": "2026-12-04", "happens_until": "2026-12-06" }],   // or just "follow_up_on"
  "rosters": [{ "name": "BKB comp sign-up 2026-03-02", "date": "...", "source": "Event sign-up",
                "names": ["Ana", "Ben — belayer"], "notes": "...",
                "anchor_group": "g1", "anchor_person": null, "event": null,   // at least one anchor
                "people": ["12"] }],
  "flags": ["Short question for the user"],
  "confirmation": "What you'd tell the user"
}
```

Choice lists: `select * from relationship_tiers order by sort_order;` and
`select * from follow_up_cadences;`. Group types: Friend Group, Social Circle,
Group Chat, Club, Community, Workplace, Other. Roster sources: Event sign-up, Met
in person, Online list, Friend's circle, Party invite list, Other. Birthday with
unknown year: use year 1904.

## Rules

**People**
- New contact = someone the user met or describes who isn't in the CRM. Set
  `known_since` and `how_we_met`. Check `crm_find_people` first; the function
  flags (but allows) a second contact with an identical name.
- Someone mentioned only in relation to a contact ("Sam's sister Ana") goes in that
  contact's `family_pets` ("Sister: Ana"), not a new contact, unless the user says
  to add them.
- Facts go in fields; `likes_interests` are short phrases; `family_pets` are
  "Relation: Name"; long-arc backstory goes in `history`; `notes` is a last resort.
- `set` fills empty fields only. Add the field to `overwrite` only when the user is
  explicitly correcting or updating it.
- Tier: set for new people as implied (wants to become friends → `Building`).
  Don't change an existing tier unless asked. Cadence only when stated or clearly
  implied. Reuse existing tags.

**Groups**: clubs, teams, communities, group chats, workplaces are linked groups,
never text in a field. Reuse by id; a new name is matched against existing names
and abbreviations before anything is created.

**Interactions**: log one whenever the user had real contact (including first
meeting), listing everyone they interacted with, not people merely mentioned.
Resolve relative dates against today. Summary is one line.

**Hooks**: forward-looking topics worth asking about next time (plans, trips,
interviews, moves, unfolding health or family news), in the user's words,
shortened. Never invent one. None → omit. When an open hook played out, add it to
`resolve_hooks` and also file any lasting fact (with `overwrite` if needed).

**Hook timing**: date every hook you can. kind is one of trip, interview,
medical, move, baby, wedding, new_job, exam, event, other (`select * from
hook_kinds` for the days-after defaults). Resolve "next weekend" or "early
December" against today. Vague timing gets `date_precision` week/month/approx,
with `happens_until` at the end of the window. Set `follow_up_on` only when the
user says when to check in. Hook text has no relative dates ("Gunks climbing
trip", not "trip next month"). Changed timing for an open hook goes in
`update_hooks`. Yearly dates other than a contact's own birthday go in that
person's `dates`.

**Events**: parties, trips, weddings and the like get an event linked to who was
there; an ordinary hangout is just an interaction.

**Rosters**: a bare list of mostly strangers from an event becomes one roster with
at least one anchor; no contacts are created for its names. List only confident
existing-contact matches in `people` (exact matches link automatically). People
with real details are filed individually instead.

**Ambiguity**: file what is clear; put the rest in `flags` as short questions.
Never guess between two existing contacts.
