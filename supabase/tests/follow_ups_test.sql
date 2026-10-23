-- Behavioral tests for proactive follow-ups (second migration).
-- Run after both migrations:  psql -v ON_ERROR_STOP=1 -f supabase/tests/follow_ups_test.sql
-- Rolled back at the end; safe to re-run.

begin;

create function pg_temp.check(ok boolean, msg text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', msg; end if;
end $$;

-- Seed: Sam (Close Friend, phone), Dana (Acquaintance), Maya (birthday Oct 30).
do $$
declare r jsonb;
begin
  r := crm_apply_plan('{
    "occurred_on": "2026-10-20",
    "people": [
      {"ref": "s", "name": "Sam Rivera", "set": {"relationship_tier": "Close Friend", "phone": "+15550001"}},
      {"ref": "d", "name": "Dana Okafor", "set": {"relationship_tier": "Acquaintance"}},
      {"ref": "m", "name": "Maya Chen", "set": {"birthday": "1996-10-30", "relationship_tier": "Friend"},
       "dates": [{"label": "Wedding anniversary", "date": "2019-11-02", "remind_days_before": 3},
                 {"label": "Daughter Ellie''s birthday", "date": "1904-10-25"}]}
    ],
    "interactions": [
      {"type": "In Person", "summary": "Climbing", "people": ["s", "d"], "hooks": [
        {"text": "Gunks climbing trip", "person": "s", "kind": "trip", "happens_on": "2026-11-06", "happens_until": "2026-11-08", "date_precision": "exact"},
        {"text": "Nursing school application", "person": "d"},
        {"text": "Kitchen renovation", "kind": "other", "follow_up_on": "2026-10-25"}
      ]}
    ],
    "confirmation": "seed"}'::jsonb);
  perform pg_temp.check(r ->> 'info' like '%Reminder Nov 10: Gunks climbing trip%', 'reminder date reported back: ' || (r ->> 'info'));
end $$;

-- 1. Default follow-up dates.
do $$
begin
  perform pg_temp.check((select follow_up_on from hooks where hook = 'Gunks climbing trip') = '2026-11-10', 'trip: 2 days after it ends');
  perform pg_temp.check((select follow_up_on from hooks where hook = 'Nursing school application') = '2026-11-10', 'undated: 21 days after raised');
  perform pg_temp.check((select follow_up_on from hooks where hook = 'Kitchen renovation') = '2026-10-25', 'explicit follow_up_on wins');
  perform pg_temp.check((select count(*) from important_dates) = 2, 'important dates stored');
end $$;

-- 2. What is due on a given day.
do $$
begin
  perform pg_temp.check(not exists (select 1 from crm_due_reminders('2026-10-24', true)), 'nothing due on Oct 24');
  -- Oct 25: kitchen (shared by Sam & Dana, no single phone) + Ellie's birthday.
  perform pg_temp.check((select count(*) from crm_due_reminders('2026-10-25', true)) = 2, 'two items Oct 25');
  perform pg_temp.check((select people from crm_due_reminders('2026-10-25', true) where kind = 'follow_up') = 'Dana Okafor & Sam Rivera',
                        'shared hook names both people');
  perform pg_temp.check((select phone from crm_due_reminders('2026-10-25', true) where kind = 'follow_up') is null, 'no phone for a group item');
  perform pg_temp.check((select what from crm_due_reminders('2026-10-25', true) where kind = 'date') = 'Daughter Ellie''s birthday today', 'unknown-year date fires');
  perform pg_temp.check((select what from crm_due_reminders('2026-10-30', true) where kind = 'birthday') = 'Birthday today (turning 30)', 'birthday with age');
  perform pg_temp.check((select what from crm_due_reminders('2026-10-30', true) where kind = 'date') = 'Wedding anniversary on Mon Nov 2', 'reminds days before');
  -- Nov 10: items involving a Close Friend (Sam) sort before Acquaintance-only ones (Dana's application).
  perform pg_temp.check((select array_agg(what) from crm_due_reminders('2026-11-10', true)) = array['Kitchen renovation', 'Gunks climbing trip', 'Nursing school application'],
                        'closest relationships first, then the rest: ' || (select array_agg(what)::text from crm_due_reminders('2026-11-10', true)));
  perform pg_temp.check((select detail from crm_due_reminders('2026-11-10', true) where what = 'Gunks climbing trip') = 'was Nov 6–Nov 8; came up Oct 20', 'detail text');
  perform pg_temp.check((select phone from crm_due_reminders('2026-11-10', true) where what = 'Gunks climbing trip') = '+15550001', 'single-person phone');
end $$;

-- 3. Anti-nag: at most two pushes, three days apart; the list still shows it.
do $$
declare k bigint := (select id from hooks where hook = 'Kitchen renovation');
begin
  perform crm_mark_reminded(array[k], '2026-10-25');
  perform pg_temp.check(not exists (select 1 from crm_due_reminders('2026-10-26', true) where id = k and kind = 'follow_up'), 'not re-pushed next day');
  perform pg_temp.check(exists (select 1 from crm_due_reminders('2026-10-26', false) where id = k and kind = 'follow_up'), 'still listed in the Shortcut');
  perform pg_temp.check(exists (select 1 from crm_due_reminders('2026-10-28', true) where id = k and kind = 'follow_up'), 'second push after 3 days');
  perform crm_mark_reminded(array[k], '2026-10-28');
  perform pg_temp.check(not exists (select 1 from crm_due_reminders('2026-11-20', true) where id = k and kind = 'follow_up'), 'never a third push');
  perform pg_temp.check(exists (select 1 from jsonb_array_elements(crm_person_card((select id from people where name = 'Sam Rivera')) -> 'open_hooks') x
                               where x ->> 'hook' = 'Kitchen renovation'),
                        'still open for recaps');
end $$;

-- 4. Shortcut actions.
do $$
declare
  k bigint := (select id from hooks where hook = 'Kitchen renovation');
  t bigint := (select id from hooks where hook = 'Gunks climbing trip');
  a bigint := (select id from hooks where hook = 'Nursing school application');
  sam bigint := (select id from people where name = 'Sam Rivera');
  maya bigint := (select id from people where name = 'Maya Chen');
  r jsonb;
begin
  r := crm_follow_up_action('follow_up', k, 'snooze', '2026-11-20');
  perform pg_temp.check((select follow_up_on from hooks where id = k) = '2026-11-27' and (select reminded_count from hooks where id = k) = 0, 'snooze moves a week, resets count');
  perform pg_temp.check(r ->> 'message' = 'Snoozed until Fri Nov 27.', 'snooze message: ' || (r ->> 'message'));

  perform crm_follow_up_action('follow_up', t, 'texted', '2026-11-10');
  perform pg_temp.check((select closed_reason from hooks where id = t) = 'asked', 'texted closes as asked');
  perform pg_temp.check((select last_contacted from people where id = sam) = '2026-11-10', 'texting counts as contact');
  perform pg_temp.check(exists (select 1 from interactions where summary = 'Followed up about: Gunks climbing trip' and type = 'Text'), 'interaction logged');

  perform crm_follow_up_action('follow_up', a, 'dismiss', '2026-11-10');
  perform pg_temp.check((select closed_reason from hooks where id = a) = 'dismissed', 'dismissed');
  perform pg_temp.check(exists (select 1 from changelog where summary = 'Dismiss follow-up: Nursing school application'), 'dismiss audited');

  perform crm_follow_up_action('birthday', maya, 'called', '2026-10-30');
  perform pg_temp.check(exists (select 1 from interactions where summary = 'Birthday phone call'), 'birthday call logged');
  perform pg_temp.check((select last_contacted from people where id = maya) = '2026-10-30', 'birthday call counts as contact');

  begin
    perform crm_follow_up_action('follow_up', k, 'send_text_for_me', '2026-11-20');
    raise exception 'FAILED: unknown action accepted';
  exception when raise_exception then
    perform pg_temp.check(sqlerrm like 'unknown action%', 'unknown action rejected');
  end;
end $$;

-- 5. Plans can reschedule follow-ups, and choice lists are enforced.
do $$
declare k bigint := (select id from hooks where hook = 'Kitchen renovation'); r jsonb;
begin
  r := crm_apply_plan(format('{"occurred_on": "2026-11-21", "update_hooks": [{"id": %s, "happens_on": "2026-12-01", "happens_until": "2026-12-15", "kind": "move"}], "confirmation": "x"}', k)::jsonb);
  perform pg_temp.check((select follow_up_on from hooks where id = k) = '2026-12-22', 'new dates recompute the reminder (move: +7)');
  perform pg_temp.check(r ->> 'info' like '%Reminder moved to Dec 22%', 'move reported');

  r := crm_apply_plan(format('{"update_hooks": [{"id": %s, "follow_up_on": "2026-12-05"}], "confirmation": "x"}', k)::jsonb);
  perform pg_temp.check((select follow_up_on from hooks where id = k) = '2026-12-05', 'explicit reschedule');

  r := crm_apply_plan(format('{"people": [{"id": %s, "dates": [{"label": "wedding anniversary", "date": "2019-11-03"}]}], "confirmation": "x"}',
                             (select id from people where name = 'Maya Chen'))::jsonb);
  perform pg_temp.check(r -> 'flags' ->> 0 like 'Kept Maya Chen''s "wedding anniversary" date%', 'conflicting date flagged, not overwritten');

  begin
    perform crm_apply_plan(format('{"interactions": [{"type": "Text", "summary": "x", "people": ["%s"], "hooks": [{"text": "y", "kind": "vacation"}]}]}',
                                  (select id from people where name = 'Sam Rivera'))::jsonb);
    raise exception 'FAILED: bad kind accepted';
  exception when raise_exception then
    perform pg_temp.check(sqlerrm like 'unknown hook kind%', 'bad kind message');
  end;
end $$;

-- 6. Upcoming list, next-occurrence edge cases, lockdown.
do $$
begin
  perform pg_temp.check((select count(*) from crm_upcoming_follow_ups('2026-11-30', 14)) = 1, 'upcoming window');
  perform pg_temp.check(crm_next_occurrence('2000-02-29', '2027-02-01') = '2027-02-28', 'Feb 29 in a non-leap year');
  perform pg_temp.check(crm_next_occurrence('2000-02-29', '2028-02-01') = '2028-02-29', 'Feb 29 in a leap year');
  perform pg_temp.check(crm_next_occurrence('1990-01-05', '2026-12-31') = '2027-01-05', 'wraps to next year');
  if exists (select 1 from pg_roles where rolname = 'anon') then
    perform pg_temp.check(not has_table_privilege('anon', 'public.important_dates', 'select'), 'anon locked out of new tables');
    perform pg_temp.check(not has_function_privilege('anon', 'public.crm_follow_up_action(text, bigint, text, date)', 'execute'), 'anon cannot act');
  end if;
  perform pg_temp.check((select bool_and(rowsecurity) from pg_tables where schemaname = 'public'), 'RLS on every table');
end $$;

select 'ALL FOLLOW-UP TESTS PASSED' as result;
rollback;
