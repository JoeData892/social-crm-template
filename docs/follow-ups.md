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

New Shortcut named exactly **Follow-ups** (the notification opens it by name).

**How to read the values below:**

- ⌨️ **typed**: type exactly the text shown.
- 🔵 **variable**: don't type it. Tap the field, then pick the blue token from
  the bar above the keyboard, or tap **Select Variable** and tap the action that
  produces it. A typed word that looks like a variable name ("Chosen Item")
  is just text, and the Shortcut will silently get nothing.

**Names differ between iOS versions.** The output of Choose from List is
**Selected Item** on newer iOS (**Chosen Item** on older). **Show Content** is
the newer name for **Show Result**. When a token is just called **Dictionary
Value**, it means the most recent Get Dictionary Value above it. Tap the token
to see which action it highlights, and re-select it if it's the wrong one.

#### Part A: fetch today's list

| # | Action | Settings |
|---|---|---|
| 1 | **Date** (may be called **Current Date**) | 🔵 **Current Date** |
| 2 | **Format Date** | input 🔵 **Date**; Date Format **ISO 8601**; Include ISO 8601 Time **on** |
| 3 | **Set Variable** | name ⌨️ `Now`; input 🔵 **Formatted Date** |
| 4 | **Get Contents of URL** | URL ⌨️ `https://YOUR_PROJECT_REF.supabase.co/functions/v1/followups`; Method **POST**; Header key ⌨️ `x-crm-key`, value ⌨️ your shared secret; Request Body **JSON**: Text field key ⌨️ `action` = ⌨️ `list`, Text field key ⌨️ `now` = 🔵 **Now** |
| 5 | **Set Variable** | name ⌨️ `Response`; input 🔵 **Contents of URL** |

#### Part B: stop if nothing is due

| # | Action | Settings |
|---|---|---|
| 6 | **Get Dictionary Value** | **Value** for key ⌨️ `count` in 🔵 **Response** |
| 7 | **If** | 🔵 **Dictionary Value** (from 6) **is** ⌨️ `0`. If "is" with a number isn't offered, tap the token and set its type to **Number**. |
| 7a | ↳ **Show Notification** (inside the If) | ⌨️ `Nothing to follow up on today.` |
| 7b | ↳ **Stop This Shortcut** (inside the If) | none |
| | **Otherwise** / **End If** | leave Otherwise empty; everything below goes after End If |

#### Part C: pick an item

| # | Action | Settings |
|---|---|---|
| 8 | **Get Dictionary Value** | **Value** for key ⌨️ `menu` in 🔵 **Response** |
| 9 | **Set Variable** | name ⌨️ `Menu`; input 🔵 **Dictionary Value** (from 8) |
| 10 | **Get Dictionary Value** | **All Keys** in 🔵 **Menu** (no key field) |
| 11 | **Choose from List** | input 🔵 output of 10 (**Keys** / **Dictionary Value**); prompt ⌨️ `Follow up on…` (optional); Select Multiple **off** |
| 12 | **Get Dictionary Value** | **Value** for key 🔵 **Selected Item** (from 11; **Chosen Item** on older iOS) in 🔵 **Menu** |
| 13 | **Set Variable** | name ⌨️ `Item`; input 🔵 **Dictionary Value** (from 12) |
| 14 | **Get Dictionary Value** | **Value** for key ⌨️ `kind` in 🔵 **Item** |
| 15 | **Set Variable** | name ⌨️ `Kind`; input 🔵 **Dictionary Value** (from 14) |
| 16 | **Get Dictionary Value** | **Value** for key ⌨️ `id` in 🔵 **Item** |
| 17 | **Set Variable** | name ⌨️ `Id`; input 🔵 **Dictionary Value** (from 16) |
| 18 | **Get Dictionary Value** | **Value** for key ⌨️ `sms_url` in 🔵 **Item** |
| 19 | **Set Variable** | name ⌨️ `Sms`; input 🔵 **Dictionary Value** (from 18) |
| 20 | **Get Dictionary Value** | **Value** for key ⌨️ `tel_url` in 🔵 **Item** |
| 21 | **Set Variable** | name ⌨️ `Tel`; input 🔵 **Dictionary Value** (from 20) |

Line 10 matters: given a dictionary, Choose from List shows each entry's
contents (raw JSON) on some iOS versions, so the Shortcut lists the keys
(labels) instead and looks the chosen one up in line 12.

#### Part D: what you did

| # | Action | Settings |
|---|---|---|
| 22 | **Choose from Menu** | prompt ⌨️ `What did you do?`; options ⌨️ `Text`, `Call`, `Done`, `Snooze a week`, `Not relevant` |

Under **each** option, add the same three actions. Build them once under Text,
then long-press each → **Duplicate** and drag the copies into the other options.

| Action | Settings |
|---|---|
| **Dictionary** | four items: Text ⌨️ `action` = ⌨️ *(see table below)*; Text ⌨️ `kind` = 🔵 **Kind**; Number ⌨️ `id` = 🔵 **Id**; Text ⌨️ `now` = 🔵 **Now** |
| **Get Contents of URL** | URL and `x-crm-key` header as in line 4; Method **POST**; Request Body **File** = 🔵 **Dictionary** (from the action above); optional header ⌨️ `Content-Type` = ⌨️ `application/json` |
| **Get Dictionary Value** | **Value** for key ⌨️ `message` in 🔵 **Contents of URL** |

The ⌨️ `action` value for each option:

| Option | `action` |
|---|---|
| Text | `texted` |
| Call | `called` |
| Done | `done` |
| Snooze a week | `snooze` |
| Not relevant | `dismiss` |

Then finish each option:

- **Text:** **If** 🔵 **Sms** **has any value** → **Open URLs** 🔵 **Sms**;
  **Otherwise** → **Show Notification** ⌨️ `No single number on file. Reach out another way.`
  Opening the URL starts a message in Messages; you write it and send it.
- **Call:** same as Text, with 🔵 **Tel**.
- **Done, Snooze a week, Not relevant:** **Show Notification** 🔵
  **Dictionary Value** (the `message`). Show the message, not 🔵 **Contents of
  URL**, or you'll see raw JSON.

#### Test and troubleshoot

Run the Shortcut, pick an item, choose **Done**: you should see **"Marked
done."**, and the item is gone the next time you run it. If not:

- **See what's being sent.** Add **Show Content** with input 🔵
  **Dictionary** right before that option's Get Contents of URL. It should
  show `kind: follow_up` and a real `id`. If `kind` is blank and `id` is 0,
  🔵 **Item** is empty. Check line 12: the key must be the 🔵 **Selected
  Item** token, not typed text, and the dictionary must be 🔵 **Menu**.
- **Read the server's message.** `Couldn't understand kind "" …` names the
  field that arrived empty or wrong. `Unauthorized.` means the `x-crm-key`
  value doesn't match your secret.
- **Rule out the phone.** Send the same request from Terminal. If this
  works, the server is fine and the problem is in the Shortcut:
  ```sh
  curl -s -X POST https://YOUR_PROJECT_REF.supabase.co/functions/v1/followups \
    -H "x-crm-key: $KEY" -H 'content-type: application/json' \
    -d '{"action":"done","kind":"follow_up","id":6}'
  ```

Text and Call record that you reached out (it counts as contact and closes the
follow-up), so you don't need to record a note too. When a follow-up involves
two people or a contact has no phone number, the URL is empty; pick Done after
you've reached out another way. Birthdays and other dates are only due on the
day; any choice clears one from the list for the rest of that day. If nothing
is due, line 7 shows "Nothing to follow up on today." and stops.

Asking works too: *"What follow-ups are coming up this week?"* in Ask CRM.

## Changing things

- **Reminder hour:** `CRM_NUDGE_HOUR` (e.g. `10`), then `supabase secrets set`.
- **Days after each kind:** edit the `hook_kinds` table in the dashboard's
  Table Editor.
- **Turn it off:** `select cron.unschedule('crm-morning-reminders');` in the SQL
  Editor.
- **Did it run?** `select * from nudge_runs order by run_date desc;` shows each
  day's decision (`sent`, `nothing_due`).
