# Setup

About 20 minutes. You need a computer with a terminal for the deploy step (or a
Claude session with the Supabase connector, which can run steps 3–4 for you).

## 1. Accounts and keys

1. **Supabase**: create a free project at [supabase.com](https://supabase.com).
   Note its **project ref** (the `abcd…` in `https://abcd….supabase.co`).
2. **Anthropic API key**: [console.anthropic.com](https://console.anthropic.com) →
   API Keys → Create key. Set a monthly spend limit while you're there (see the
   cost section of the README).
3. **Shared secret** for your Shortcuts: `openssl rand -hex 32`. Keep it somewhere
   safe (a password manager); you'll paste it into the two Shortcuts.

## 2. Install the Supabase CLI

```sh
brew install supabase/tap/supabase      # macOS; other platforms: see supabase.com/docs/guides/cli
supabase login
```

## 3. Create the database

```sh
git clone https://github.com/JoeData892/social-crm-template.git
cd social-crm-template
supabase link --project-ref <your-project-ref>
supabase db push
```

`db push` applies `supabase/migrations/`. That creates the tables, the helper
functions, and the lockdown (row-level security on, no access for the public
`anon` and `authenticated` roles).

No CLI? Paste the migration file into the dashboard's **SQL Editor** and run it.

## 4. Secrets and functions

```sh
cp supabase/functions/.env.example supabase/functions/.env   # git-ignored
# edit .env: ANTHROPIC_API_KEY, CRM_SHARED_SECRET, CRM_TIMEZONE
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy ingest --no-verify-jwt
supabase functions deploy ask --no-verify-jwt
supabase functions deploy followups --no-verify-jwt
```

`--no-verify-jwt` is required because the Shortcuts authenticate with your
shared secret, not a Supabase login. Every request without the right secret is
rejected before anything else runs.

## 5. Smoke test

```sh
URL=https://<your-project-ref>.supabase.co/functions/v1
KEY=<your shared secret>

curl -s -X POST $URL/ingest -H "x-crm-key: $KEY" -H 'content-type: application/json' \
  -d '{"text": "Met Sam Rivera at the climbing gym tonight, he is an urban planner and wants to climb again next week"}'

curl -s -X POST $URL/ask -H "x-crm-key: $KEY" -H 'content-type: application/json' \
  -d '{"question": "What do I know about Sam?"}'

curl -s -X POST $URL/ask -H 'content-type: application/json' -d '{"question": "x"}'   # → 401
```

## 6. iPhone Shortcuts

Follow [iphone-shortcuts.md](iphone-shortcuts.md).

## 7. Proactive follow-ups (optional)

Morning push reminders to check in about trips, interviews and other things
people mentioned: [follow-ups.md](follow-ups.md).

## 8. The Claude skill (optional)

So you can ask and edit in a normal Claude conversation:

1. Give Claude database access: in claude.ai, add the **Supabase** connector
   (Settings → Connectors) and allow your CRM project. In Claude Code, add the
   Supabase MCP server or give it a `psql` connection string.
2. Install the skill: zip the `skill/social-crm` folder and upload it as a custom
   skill in claude.ai's settings. In Claude Code, copy the folder into
   `~/.claude/skills/`.

Then: *"What do I know about Dana?"*, *"Who am I letting go cold?"*, *"Review my
flagged voice notes."*

## Updating later

`git pull`, then `supabase db push` for new migrations and redeploy the
functions. To rotate the shared secret: `supabase secrets set CRM_SHARED_SECRET=…`
and update both Shortcuts.

## Running the tests

`supabase/tests/run.sh` (needs Docker, `psql` and `deno`). It runs the database
behavior tests and end-to-end tests of both endpoints against a local
Postgres/pgvector + PostgREST, with a scripted stand-in for the Claude API. No
keys are needed and nothing touches your real project.
