# Voice Social CRM

A personal CRM for the people in your life that you fill in by talking. Press a
button on your iPhone, say what happened (*"Had coffee with Marcus. He's
interviewing at Stripe next week and his daughter Ellie starts kindergarten in
September"*), and Claude files it: Marcus's record updated, Ellie added to his
family, the coffee logged, and "Stripe interview" and "Ellie starting
kindergarten" saved as follow-ups to ask about next time. A second button
answers questions: *"Seeing Marcus tonight, what should I ask him?"*

Built on [social-crm-template](https://github.com/dtiger1889-ops/social-crm-template)
(Airtable + agent skill), rebuilt on Supabase for voice capture.

## How it works

```
iPhone Shortcut ── dictated text + phone clock ──▶ Edge Function `ingest`
                                                      │ 1. save raw transcript (never lost)
                                                      │ 2. Claude: resolve names, build a plan
                                                      │ 3. crm_apply_plan(): one transaction,
                                                      │    rules enforced in the database
                                                      ▼
◀── notification: what was filed + questions ──  Postgres (Supabase) + pgvector

iPhone Shortcut ── question ──▶ Edge Function `ask` (read-only tools) ──▶ answer
Claude (chat) ── social-crm skill ──▶ same database, same crm_apply_plan()
```

- **Capture** (`supabase/functions/ingest`): stores your words first, then gives
  Claude your contact directory, groups and recent events so it can resolve
  "Sam", "BKB" or a misheard "Shawn". Claude can look people up, then submits one
  structured **plan** for the whole note.
- **Rules live in the database** (`crm_apply_plan` in the migration), not just in
  a prompt. Filled fields are never overwritten unless you're explicitly
  correcting them (otherwise it asks you). Lists and links only grow. Last
  Contacted never moves backward. Name lists need an anchor. Every change is
  logged with its source note. A plan that breaks a rule is rejected as a whole,
  and Claude gets the error and fixes the plan.
- **Ambiguity is a question, not a guess.** Two Chrises → it files everything
  else and asks you which one in the notification.
- **Retrieval** (`supabase/functions/ask`) combines keyword search and search by
  meaning over interactions, follow-ups, original transcripts and profiles, plus
  tools for "who's overdue", birthdays, recent interactions and name lists.

## Data model

| Table | What |
|---|---|
| `people` | One per person: contact info, job, location, birthday, how you met, relationship tier, follow-up cadence, interests, family and pets, history |
| `groups` | Clubs, teams, friend groups, group chats, workplaces, linked to people |
| `events` | Parties, trips, weddings, with who was there |
| `interactions` | Dated log of real contact (in person, call, text…) with participants |
| `hooks` | Follow-ups from an interaction ("moving to Denver in May"), open until resolved |
| `rosters` | Name lists from events, kept as text so 40 sign-ups don't become 40 contacts; recurring names surface for promotion |
| `voice_notes` | Every transcript, its status (`done`, `needs_review`, `error`) and the reply you got |
| `changelog` | Audit trail of every change and why |
| `relationship_tiers`, `follow_up_cadences` | Editable choice lists (Close Friend … Building …; Weekly … Yearly) |

Changes from the template: Supabase instead of Airtable (no record or API-call
caps, search by meaning, an atomic write path); follow-ups have their own table;
raw transcripts are kept; the romantic-interest field was removed; first meetings
are also logged as interactions so follow-ups from them aren't lost.

## Setup

[docs/setup.md](docs/setup.md) covers the Supabase project, keys and deploy, then
[docs/iphone-shortcuts.md](docs/iphone-shortcuts.md) covers the two buttons.
Optional: the [Claude skill](skill/social-crm/SKILL.md) for asking and editing in
a regular Claude chat.

## Cost

Supabase's free tier covers the database and functions. Claude API usage is
pay-per-use. With the default model (Claude Opus 5.5 at medium effort), expect
roughly **$0.10–0.20 per voice note** and a few cents per question; the cost grows
slowly with the size of your contact list. Set `CRM_MODEL` to a smaller model,
or `CRM_INGEST_EFFORT=low`, to trade some filing quality for cost. Set a spend
limit in the Anthropic console either way.

## Security and privacy

- **Locked database.** Row-level security is on for every table with no policies,
  and the public `anon`/`authenticated` roles have no privileges. Only the Edge
  Functions (service role) and you (dashboard or owner connection) can read or
  write.
- **Endpoint auth.** Every request must carry your shared secret in `x-crm-key`,
  compared in constant time. Bodies are size-limited. No CORS, so web pages can't
  call it from a browser.
- **Secrets.** Keys live in Supabase function secrets, never in the repo
  (`.env` is git-ignored). The secret is also stored in your two Shortcuts, so
  don't share them.
- **Least privilege.** `ask` has read-only tools. `ingest` has exactly one write
  path, the validated plan.
- **Logs.** Functions log errors, never transcripts.
- **What leaves your phone.** The dictated text (Apple's dictation runs
  on-device or with Apple, per your iPhone settings) goes to your Supabase
  project and, for processing, to the Anthropic API. It is about real people;
  treat the database accordingly.

## Tests

`supabase/tests/run.sh` runs the database behavior tests and end-to-end tests of
both endpoints (Docker Postgres/pgvector + PostgREST, scripted Claude stand-in;
no keys needed).

## License

MIT. See [LICENSE](LICENSE). Original template © 2026 Daniel Mack.
