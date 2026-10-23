# iPhone Shortcuts

Two Shortcuts: **CRM Note** (talk, and it gets filed) and **Ask CRM** (ask, get
an answer). Build them in the Shortcuts app; each takes about three minutes.

You need your function URL, `https://<project-ref>.supabase.co/functions/v1`, and
your shared secret from setup.

> **Keep the secret private.** It is stored inside each Shortcut. Don't share
> these Shortcuts (a shared iCloud link would include the secret). If one leaks,
> rotate the secret (see setup) and edit both Shortcuts.

In the steps below, ⌨️ means type exactly the text shown, and 🔵 means insert
a variable: tap the field and pick the blue token from the bar above the
keyboard, or **Select Variable**. Never type a variable's name; typed text is
taken literally. Recent iOS renamed a few actions: **Show Result** is now
**Show Content**, and Choose from List's output is **Selected Item**.

## CRM Note

New Shortcut → name it **CRM Note**, then add these actions in order:

1. **Dictate Text**. Tap the arrow to expand it: Language = English, **Stop
   Listening = On Tap** (lets you pause mid-thought; tap Done when finished).
2. **Copy to Clipboard** (input: 🔵 *Dictated Text*). This is a safety net: if you
   have no signal, the words are still on your clipboard.
3. **Current Date**.
4. **Format Date** (input: 🔵 *Date*). Date Format = **ISO 8601**, Include ISO 8601
   Time = **on**. This lets "yesterday" and "on Friday" resolve in your time zone.
5. **Get Contents of URL**
   - URL: ⌨️ `https://<project-ref>.supabase.co/functions/v1/ingest`
   - Method: **POST**
   - Headers: add ⌨️ `x-crm-key` = ⌨️ your shared secret (pasted)
   - Request Body: **JSON**, with two Text fields:
     - key ⌨️ `text` = 🔵 *Dictated Text*
     - key ⌨️ `now` = 🔵 *Formatted Date*
6. **Get Dictionary Value**: Get **Value** for key ⌨️ `message` in 🔵 *Contents of URL*.
7. **Show Notification** (body: 🔵 *Dictionary Value*). Or use **Show Content**
   (formerly **Show Result**) if you want it to stay on screen.

The notification tells you what was filed, plus questions when something was
ambiguous, e.g.

> Added Dana Okafor (Building) · BKB. Logged climbing with Sam & Dana; 1 follow-up.
> ? Is it Dana Okafor or Okafor-Smith?

Answer a question with another note ("Dana's last name is Okafor-Smith"), or later
in Claude with the skill ("review my flagged voice notes").

If filing takes longer than ~45 seconds you'll see *"Still filing this one…"*;
it finishes in the background. Your words are saved before any processing starts,
so a failure never loses a note.

## Ask CRM

New Shortcut → **Ask CRM**:

1. **Dictate Text** (Stop Listening = After Pause).
2. **Current Date** → **Format Date** (ISO 8601, include time), as above.
3. **Get Contents of URL**: URL ⌨️ `…/functions/v1/ask`, Method POST, header
   ⌨️ `x-crm-key` = ⌨️ your secret, JSON body: key ⌨️ `question` = 🔵 *Dictated Text*,
   key ⌨️ `now` = 🔵 *Formatted Date*.
4. **Get Dictionary Value**: **Value** for key ⌨️ `answer` in 🔵 *Contents of URL*.
5. **Show Content** (formerly **Show Result**) with 🔵 *Dictionary Value*, or
   **Speak Text** for hands-free use.

Things to ask: *"Seeing Sam tonight, what should I ask him about?"*, *"Who am I
letting go cold?"*, *"Who did I meet at the climbing gym?"*, *"Any birthdays this
month?"*, *"Who's the friend of Maya's that works in film?"*

## Make them one tap

- **Action Button** (iPhone 15 Pro and later): Settings → Action Button →
  Shortcut → CRM Note. Press and hold, talk, tap Done.
- **Back Tap**: Settings → Accessibility → Touch → Back Tap → Double Tap → CRM Note.
- **Home Screen / Lock Screen widget**: long-press the home screen → add a
  Shortcuts widget.
- **Siri**: "Hey Siri, CRM note" works automatically from the Shortcut's name.

## What to say

Talk the way you'd brief a friend. The more specific, the better it files:

- "Just got coffee with Marcus at Sey. He's interviewing at Stripe next week and
  his daughter Ellie starts kindergarten in September. I want to see him monthly."
- "Met a woman named Priya at Jordan's birthday. She's in the Sunday soccer group,
  works in urban planning, really into ceramics. Want to be friends."
- "Glob this, run club sign-up tonight: Ana, Ben K, Cat, Diego, Eli."
- "Sam's birthday is March 3rd." / "Change Dana's tier to friend."
- "Talked to mom on the phone. Her knee surgery went fine."
