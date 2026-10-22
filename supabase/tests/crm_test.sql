-- Behavioral tests for crm_apply_plan and the read helpers.
-- Run against a scratch database that has the migration applied:
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/crm_test.sql
-- Each block raises on failure. Everything runs in one transaction that is
-- rolled back at the end, so it is safe to re-run.

begin;

create function pg_temp.check(ok boolean, msg text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', msg; end if;
end $$;

-- 1. A new person with a new group, an interaction and two hooks.
do $$
declare r jsonb; sam bigint;
begin
  r := crm_apply_plan('{
    "occurred_on": "2026-10-20",
    "groups": [{"ref": "g1", "name": "Brooklyn Boulders", "type": "Club", "abbreviation": "BKB"}],
    "people": [{"ref": "p1", "name": "Sam Rivera",
                "set": {"job": "Urban planner", "relationship_tier": "Building", "how_we_met": "Climbing gym"},
                "add": {"likes_interests": ["bouldering", "mystery novels"], "family_pets": ["Dog: Pickles"]},
                "groups": ["g1"]}],
    "interactions": [{"type": "In Person", "summary": "Climbed together, grabbed tacos",
                      "people": ["p1"],
                      "hooks": [{"text": "Moving to Denver in May"}, {"text": "Job interview at Parks Dept next week"}]}],
    "confirmation": "Added Sam"}'::jsonb);
  sam := (r -> 'people' -> 0 ->> 'id')::bigint;
  perform pg_temp.check((select job from people where id = sam) = 'Urban planner', 'job set on create');
  perform pg_temp.check((select last_contacted from people where id = sam) = '2026-10-20', 'last_contacted set from interaction');
  perform pg_temp.check((select count(*) from hooks) = 2, 'two hooks stored');
  perform pg_temp.check((select count(*) from person_groups where person_id = sam) = 1, 'group linked');
  perform pg_temp.check((select count(*) from changelog) = 1, 'changelog written');
  perform pg_temp.check(jsonb_array_length(r -> 'flags') = 0, 'no flags on clean create');
end $$;

-- 2. Never silently overwrite; flag instead. Overwrite only when asked.
do $$
declare r jsonb; sam bigint := (select id from people where name = 'Sam Rivera');
begin
  r := crm_apply_plan(format('{"people": [{"id": "%s", "set": {"job": "Architect", "location": "Bushwick"}}]}', sam)::jsonb);
  perform pg_temp.check((select job from people where id = sam) = 'Urban planner', 'filled field kept');
  perform pg_temp.check((select location from people where id = sam) = 'Bushwick', 'empty field filled');
  perform pg_temp.check(r ->> 'flags' like '%Kept Sam Rivera''s job%', 'overwrite attempt flagged');

  r := crm_apply_plan(format('{"people": [{"id": "%s", "set": {"job": "Architect"}, "overwrite": ["job"]}]}', sam)::jsonb);
  perform pg_temp.check((select job from people where id = sam) = 'Architect', 'explicit overwrite applied');
  perform pg_temp.check((select actions -> 0 ->> 'previous' from changelog order by id desc limit 1) = 'Urban planner', 'previous value logged');
end $$;

-- 3. Lists only grow, case-insensitively de-duplicated; group links are additive.
do $$
declare sam bigint := (select id from people where name = 'Sam Rivera');
begin
  perform crm_apply_plan(format('{
    "groups": [{"ref": "g2", "name": "Tuesday Trivia", "type": "Friend Group"}, {"ref": "g3", "name": "bkb"}],
    "people": [{"id": %s, "add": {"likes_interests": ["Bouldering", "jazz"]}, "groups": ["g2", "g3"]}]}', sam)::jsonb);
  perform pg_temp.check((select count(*) from groups) = 2, 'abbreviation reused the existing group');
  perform pg_temp.check((select likes_interests from people where id = sam) = array['bouldering', 'mystery novels', 'jazz'], 'list union');
  perform pg_temp.check((select count(*) from person_groups where person_id = sam) = 2, 'group links unioned, abbreviation resolved');
end $$;

-- 4. Last Contacted never moves backward; hooks resolve.
do $$
declare sam bigint := (select id from people where name = 'Sam Rivera'); hid bigint := (select min(id) from hooks);
begin
  perform crm_apply_plan(format('{"interactions": [{"date": "2026-09-01", "type": "Text", "summary": "Old text thread", "people": ["%s"]}],
                                  "resolve_hooks": [{"id": %s, "resolution": "Decided to stay in NYC"}]}', sam, hid)::jsonb);
  perform pg_temp.check((select last_contacted from people where id = sam) = '2026-10-20', 'last_contacted not moved backward');
  perform pg_temp.check((select resolved_on is not null from hooks where id = hid), 'hook resolved');
  perform pg_temp.check(jsonb_array_length(crm_person_card(sam) -> 'open_hooks') = 1, 'card shows one open hook');
end $$;

-- 5. Bad input rolls back the whole plan.
do $$
declare n int := (select count(*) from people);
begin
  begin
    perform crm_apply_plan('{"people": [{"ref": "x", "name": "Should Not Exist"}],
                             "interactions": [{"type": "Carrier Pigeon", "summary": "nope", "people": ["x"]}]}'::jsonb);
    raise exception 'FAILED: invalid type accepted';
  exception when check_violation then null;
  end;
  perform pg_temp.check((select count(*) from people) = n, 'atomic rollback');

  begin
    perform crm_apply_plan('{"interactions": [{"type": "Text", "summary": "x", "people": ["999999"]}]}'::jsonb);
    raise exception 'FAILED: unknown person accepted';
  exception when raise_exception then
    perform pg_temp.check(sqlerrm like 'unknown people reference%', 'unknown ref message: ' || sqlerrm);
  end;

  begin
    perform crm_apply_plan('{"people": [{"name": "Tier Test", "set": {"relationship_tier": "Bestie"}}]}'::jsonb);
    raise exception 'FAILED: bad tier accepted';
  exception when raise_exception then
    perform pg_temp.check(sqlerrm like 'unknown relationship_tier%', 'bad tier message');
  end;

  begin
    perform crm_apply_plan('{"rosters": [{"name": "No anchor", "names": ["A"]}]}'::jsonb);
    raise exception 'FAILED: anchorless roster accepted';
  exception when check_violation then null;
  end;
end $$;

-- 6. Rosters: exact matches auto-link, ambiguous ones are flagged, and a
--    later-added contact picks up earlier roster history.
do $$
declare r jsonb; g bigint := (select id from groups where abbreviation = 'BKB'); jo bigint;
begin
  perform crm_apply_plan('{"people": [{"name": "Chris Park"}, {"name": "Chris Park"}]}'::jsonb);
  r := crm_apply_plan(format('{"rosters": [{"name": "BKB comp sign-up 2026-03-02", "date": "2026-03-02", "source": "Event sign-up",
                               "anchor_group": "%s", "names": ["sam rivera", "Chris Park", "Jo Okafor — belayer"]}]}', g)::jsonb);
  perform pg_temp.check((select count(*) from roster_people) = 1, 'only the unambiguous match linked');
  perform pg_temp.check(r ->> 'flags' like '%matches several contacts%', 'ambiguous match flagged');

  r := crm_apply_plan('{"people": [{"ref": "j", "name": "Jo Okafor"}]}'::jsonb);
  jo := (r -> 'people' -> 0 ->> 'id')::bigint;
  perform pg_temp.check((select known_since from people where id = jo) = '2026-03-02', 'known_since from earliest roster');
  perform pg_temp.check(r ->> 'info' like '%earlier name list%', 'roster history reported');
end $$;

-- 7. Partners link both ways; duplicate-name creation is flagged.
do $$
declare r jsonb; sam bigint := (select id from people where name = 'Sam Rivera');
begin
  r := crm_apply_plan(format('{"people": [{"ref": "a", "name": "Alex Kim", "partner": "%s"}]}', sam)::jsonb);
  perform pg_temp.check((select partner_id from people where id = sam) = (r -> 'people' -> 0 ->> 'id')::bigint, 'partner set on both');
  perform pg_temp.check(exists (select 1 from changelog, unnest(flags) f where f like 'Created a new "Chris Park"%'), 'duplicate name flagged');
end $$;

-- 8. Read helpers.
do $$
declare sam bigint := (select id from people where name = 'Sam Rivera');
begin
  perform pg_temp.check((select id from crm_find_people('sam rivra') limit 1) = sam, 'fuzzy find with typo');
  perform pg_temp.check((select id from crm_find_people('Rivera') limit 1) = sam, 'find by last name');
  perform pg_temp.check(exists (select 1 from crm_search('Denver') where kind = 'interaction'), 'full-text search finds hook text');
  perform pg_temp.check(exists (select 1 from crm_people_due(null, '2026-12-01') where id = sam and due), 'Building with no cadence is due after 30d');
  perform pg_temp.check(not exists (select 1 from crm_people_due(null, '2026-10-25') where id = sam and due), 'not due yet');
  perform pg_temp.check((select count(*) from crm_search_rosters('Jo Okafor')) = 1, 'roster search');
  perform pg_temp.check((select count(*) from crm_directory()) = 5, 'directory lists everyone');
  perform pg_temp.check(crm_person_text(sam) like '%bouldering%', 'person text for embeddings');
  perform pg_temp.check((select count(*) from crm_recent_interactions('2026-10-01')) = 1, 'recent interactions window');
  perform pg_temp.check((select open_hooks[1] from crm_recent_interactions('2026-10-01')) like 'Job interview%', 'recent interactions carry open hooks');
  update people set birthday = '1904-11-03' where id = sam;
  perform pg_temp.check((select turning is null from crm_upcoming_birthdays(30, '2026-10-22') where id = sam), 'unknown birth year => no age');
  perform pg_temp.check((select next_birthday from crm_upcoming_birthdays(30, '2026-10-22') where id = sam) = '2026-11-03', 'next birthday computed');
  update people set embedding = array_fill(0.1, array[384])::extensions.vector where id = sam;
  perform pg_temp.check((select id from crm_search('no keyword overlap', array_fill(0.1, array[384])::extensions.vector) where kind = 'person' limit 1) = sam,
                        'vector search finds semantically similar person without keyword match');
end $$;

-- 9. Voice note status bookkeeping.
do $$
declare nid bigint;
begin
  insert into voice_notes (transcript) values ('test') returning id into nid;
  perform crm_apply_plan('{"people": [{"name": "Pat Lee"}], "flags": ["Which Pat?"], "confirmation": "Added Pat"}'::jsonb, nid);
  perform pg_temp.check((select status from voice_notes where id = nid) = 'needs_review', 'flags => needs_review');
  perform pg_temp.check((select result_summary from voice_notes where id = nid) = 'Added Pat', 'confirmation stored');
end $$;

-- 10. Lockdown: anon and authenticated can read nothing and call nothing.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    perform pg_temp.check(not has_table_privilege('anon', 'public.people', 'select'), 'anon cannot select people');
    perform pg_temp.check(not has_table_privilege('authenticated', 'public.voice_notes', 'select'), 'authenticated cannot select notes');
    perform pg_temp.check(not has_function_privilege('anon', 'public.crm_apply_plan(jsonb, bigint, text)', 'execute'), 'anon cannot apply plans');
    perform pg_temp.check(has_function_privilege('service_role', 'public.crm_apply_plan(jsonb, bigint, text)', 'execute'), 'service_role can apply plans');
  end if;
  perform pg_temp.check((select bool_and(rowsecurity) from pg_tables where schemaname = 'public'), 'RLS on every table');
end $$;

select 'ALL CRM TESTS PASSED' as result;
rollback;
