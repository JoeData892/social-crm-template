# Proactive follow-ups

When a note mentions something coming up ("Sam's at the Gunks Nov 6–8",
"Dana's interview is Tuesday", "Maya's due in March"), the CRM works out when
you should check in and reminds you that morning with a push notification.
**It only ever reminds you. It never contacts anyone.**

## How it decides

- **When you record a note**, each follow-up gets a kind and the dates involved.
  The reminder date is then computed:

  | Kind | Reminder |
  |---|---|
  | trip | 2 days after it ends |
  | interview, exam | the next day |
  | medical, event, other dated thing | 2 days after |
  | wedding | 3 days after |
  | move, new job, baby | a week after |
  | no date mentioned | 3 weeks after it came up |

  You'll see the date in the capture notification ("Reminder Nov 10: Gunks
  climbing trip"). Override it by saying so: *"remind me to ask Dana about the
  move in two weeks"*, or *"Sam's trip got pushed to December"*.
- **Important dates** (anniversaries, kids' birthdays) remind you on the day,
  or a few days ahead if you say so (*"remind me 3 days before"*). Contacts'
  birthdays remind you on the day.
- **Every morning** during your window (default 9:00–11:59 local, first check at
  9:30), the database lists what's due. If anything is, you get **one** Pushover
  notification. If nothing is, nothing happens.
- **No nagging.** Each follow-up is pushed at most twice, at least three days
  apart. After that it stays in the Follow-ups list and in "seeing Sam tonight"
  recaps, but it isn't pushed again.

A morning notification looks like:

> **2 follow-ups today**
> • Ask Sam Rivera about Gunks climbing trip (was Nov 6–Nov 8; came up Oct 20)
> • Maya Chen: Birthday today (turning 30)

Tap it to open the Follow-ups Shortcut.

## Setup (about 15 minutes)

### 1. Pushover

1. Install **Pushover** from the App Store and create an account. There's a
   30-day trial, then a one-time purchase.
2. On [pushover.net](https://pushover.net), log in and copy your **User Key**.
3. Create an application at [pushover.net/apps/build](https://pushover.net/apps/build)
   (name: `Social CRM`) and copy its **API Token**.

### 2. Secrets and deploy

In Terminal, from the project folder (`cd social-crm-template`):

```sh
git pull
open -e supabase/functions/.env
```

Add these lines (and set `CRM_TIMEZONE` correctly if you haven't), then save:

```
PUSHOVER_USER=your-user-key
PUSHOVER_TOKEN=your-app-api-token
CRM_NUDGE_HOUR=9
```

```sh
supabase secrets set --env-file supabase/functions/.env
supabase db push
supabase functions deploy ingest --no-verify-jwt
supabase functions deploy ask --no-verify-jwt
supabase functions deploy followups --no-verify-jwt
```

`db push` adds the follow-up tables; existing follow-ups get a reminder date
3 weeks after they came up. Redeploying `ingest` and `ask` teaches them to
record dates and answer "what's coming up".

### 3. Schedule the morning check

1. Open `supabase/setup/schedule_morning_reminders.sql`. Copy its contents into
   the Supabase dashboard → **SQL Editor**.
2. Replace `YOUR_PROJECT_REF` and `YOUR_SHARED_SECRET` (the same secret as in
   your Shortcuts), then click **Run**.

To test right away without waiting for morning (it sends a push only if
something is due today):

```sh
curl -s -X POST https://YOUR_PROJECT_REF.supabase.co/functions/v1/followups \
  -H "x-crm-key: $KEY" -H 'content-type: application/json' \
  -d "{\"action\": \"nudge\", \"now\": \"$(date +%Y-%m-%dT09:30:00)\"}"
```

`"status": "nothing_due"` means it worked and there was nothing to send.

### 4. The Follow-ups Shortcut

New Shortcut named exactly **Follow-ups** (the notification opens it by name):

1. **Current Date** → **Format Date** (ISO 8601, include time).
2. **Get Contents of URL**: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/followups`,
   Method **POST**, header `x-crm-key` = your secret, JSON body: `action` = `list`,
   `now` = *Formatted Date*.
3. **Get Dictionary Value**: key `menu` from *Contents of URL*.
4. **Choose from List** (input: *Dictionary Value*). It shows one line per item.
5. **Get Dictionary Value**: **Value** for key *Chosen Item* in the `menu`
   dictionary from step 3. This gives you the item (with `kind`, `id`,
   `sms_url`, `tel_url`). If your iOS version's Choose from List already
   returns the item rather than its label, skip this step and use *Chosen Item*
   as the item below.
6. **Choose from Menu** with five options: **Text**, **Call**, **Done**,
   **Snooze a week**, **Not relevant**. Under each option, add:
   - **Get Contents of URL** (same URL and header), JSON body: `action` =
     `texted` / `called` / `done` / `snooze` / `dismiss` respectively,
     `kind` = *item*'s `kind`, `id` = *item*'s `id` (Number), `now` =
     *Formatted Date*.
   - Text only: then **Open URLs** with *item*'s `sms_url`. This opens Messages
     to them; you write and send.
   - Call only: then **Open URLs** with *item*'s `tel_url`.
   - Others: **Show Notification** with the `message` from the response.

Text and Call record that you reached out (it counts as contact and closes the
follow-up), so you don't need to record a note too. When a follow-up involves
two people or a contact has no phone number, the URL is empty; pick Done after
you've reached out another way. If nothing is due, step 4 shows an empty list.

Asking works too: *"What follow-ups are coming up this week?"* in Ask CRM.

## Changing things

- **Reminder hour:** `CRM_NUDGE_HOUR` (e.g. `10`), then `supabase secrets set`.
- **Days after each kind:** edit the `hook_kinds` table in the dashboard's
  Table Editor.
- **Turn it off:** `select cron.unschedule('crm-morning-reminders');` in the SQL
  Editor.
- **Did it run?** `select * from nudge_runs order by run_date desc;` shows each
  day's decision (`sent`, `nothing_due`).
