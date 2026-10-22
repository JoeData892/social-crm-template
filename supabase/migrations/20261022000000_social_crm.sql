-- Social CRM schema for Supabase (Postgres + pgvector).
--
-- Every write from the voice pipeline and the Claude skill goes through
-- crm_apply_plan(), which enforces the data-quality rules in one transaction:
-- never silently overwrite a filled field, links only ever grow, rosters need
-- an anchor, Last Contacted never moves backward, every change is logged.
--
-- Security model: Row Level Security is enabled on every table with NO
-- policies, and anon/authenticated lose all privileges. Only the service role
-- (used by the Edge Functions) and the database owner can read or write.

create schema if not exists extensions;
create extension if not exists vector with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;

-- ---------------------------------------------------------------------------
-- Choice lists (data, not CHECK constraints, so they can change without DDL)
-- ---------------------------------------------------------------------------

create table relationship_tiers (
  name        text primary key,
  description text not null,
  sort_order  int  not null
);

insert into relationship_tiers (name, description, sort_order) values
  ('Close Friend', 'Inner circle', 1),
  ('Friend',       'A real friend', 2),
  ('Building',     'Someone you are actively turning into a friend; not a friend yet. Give them a follow-up cadence.', 3),
  ('Old Friend',   'Was close once; the relationship is now dormant or long-distance', 4),
  ('Acquaintance', 'Know them, not friends', 5),
  ('Work Contact', 'Primarily professional', 6),
  ('Family',       'Relatives', 7);

create table follow_up_cadences (
  name text primary key,
  days int  -- null = never auto-surfaces
);

insert into follow_up_cadences (name, days) values
  ('Weekly', 7),
  ('Every 2 weeks', 14),
  ('Monthly', 30),
  ('Every 6 weeks', 42),
  ('Quarterly', 90),
  ('Twice a year', 182),
  ('Yearly', 365),
  ('As needed', null);

-- ---------------------------------------------------------------------------
-- Core tables
-- ---------------------------------------------------------------------------

create table voice_notes (
  id             bigint generated always as identity primary key,
  received_at    timestamptz not null default now(),
  spoken_at      timestamptz,             -- phone's clock when recorded
  transcript     text not null check (length(transcript) between 1 and 20000),
  status         text not null default 'received'
                 check (status in ('received', 'processing', 'done', 'needs_review', 'error')),
  result_summary text,
  flags          text[] not null default '{}',
  error          text,
  processed_at   timestamptz,
  embedding      extensions.vector(384)
);

create table groups (
  id             bigint generated always as identity primary key,
  name           text not null check (btrim(name) <> ''),
  type           text check (type in ('Friend Group', 'Social Circle', 'Group Chat', 'Club', 'Community', 'Workplace', 'Other')),
  subtype        text,   -- free text, e.g. Book Club, Running Club
  abbreviation   text,   -- the short form you actually say
  last_contacted date,
  notes          text,
  created_at     timestamptz not null default now()
);
create unique index groups_name_key on groups (lower(btrim(name)));

create table people (
  id                  bigint generated always as identity primary key,
  name                text not null check (btrim(name) <> ''),
  community_name      text,
  aliases             text[] not null default '{}',
  phone               text,
  email               text,
  socials             text[] not null default '{}',
  location            text,
  birthday            date,   -- year 1904 = year unknown
  known_since         date,
  relationship_tier   text references relationship_tiers (name) on update cascade,
  follow_up_frequency text references follow_up_cadences (name) on update cascade,
  next_follow_up      date,   -- manual override only
  last_contacted      date,
  tags                text[] not null default '{}',
  likes_interests     text[] not null default '{}',
  family_pets         text[] not null default '{}',  -- 'Relation: Name' per entry
  job                 text,
  how_we_met          text,
  history             text,   -- long-arc backstory, appended with dates
  notes               text,   -- last resort
  partner_id          bigint references people (id) on delete set null,
  embedding           extensions.vector(384),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table person_groups (
  person_id bigint not null references people (id) on delete cascade,
  group_id  bigint not null references groups (id) on delete cascade,
  primary key (person_id, group_id)
);

create table events (
  id             bigint generated always as identity primary key,
  name           text not null check (btrim(name) <> ''),
  date           date,
  location       text,
  notes          text,
  source_note_id bigint references voice_notes (id) on delete set null,
  created_at     timestamptz not null default now()
);

create table event_people (
  event_id  bigint not null references events (id) on delete cascade,
  person_id bigint not null references people (id) on delete cascade,
  primary key (event_id, person_id)
);

create table interactions (
  id             bigint generated always as identity primary key,
  date           date not null,
  type           text not null check (type in ('In Person', 'Phone Call', 'Text', 'Social Media', 'Email', 'Video Call')),
  summary        text not null check (btrim(summary) <> ''),
  location       text,
  notes          text,
  source_note_id bigint references voice_notes (id) on delete set null,
  embedding      extensions.vector(384),
  created_at     timestamptz not null default now()
);

create table interaction_people (
  interaction_id bigint not null references interactions (id) on delete cascade,
  person_id      bigint not null references people (id) on delete cascade,
  primary key (interaction_id, person_id)
);

-- Forward-looking topics worth asking about next time ("follow-up hooks").
-- person_id null = applies to everyone in the interaction.
create table hooks (
  id             bigint generated always as identity primary key,
  interaction_id bigint not null references interactions (id) on delete cascade,
  person_id      bigint references people (id) on delete cascade,
  hook           text not null check (btrim(hook) <> ''),
  raised_on      date not null,
  resolved_on    date,
  resolution     text
);

-- Rosters ("globs"): a raw list of names from an event, kept as text, not
-- contacts. Most names never become People; the list preserves recurrence.
create table rosters (
  id               bigint generated always as identity primary key,
  name             text not null check (btrim(name) <> ''),
  date             date,
  source           text check (source in ('Event sign-up', 'Met in person', 'Online list', 'Friend''s circle', 'Party invite list', 'Other')),
  names            text not null,   -- one name per line, optional note after ' — '
  notes            text,
  anchor_group_id  bigint references groups (id) on delete set null,
  anchor_person_id bigint references people (id) on delete set null,
  event_id         bigint references events (id) on delete set null,
  source_note_id   bigint references voice_notes (id) on delete set null,
  created_at       timestamptz not null default now(),
  check (coalesce(anchor_group_id, anchor_person_id, event_id) is not null)
);

-- People known to appear on a roster (matched or later promoted).
create table roster_people (
  roster_id bigint not null references rosters (id) on delete cascade,
  person_id bigint not null references people (id) on delete cascade,
  primary key (roster_id, person_id)
);

create table changelog (
  id              bigint generated always as identity primary key,
  created_at      timestamptz not null default now(),
  source_note_id  bigint references voice_notes (id) on delete set null,
  requested_by    text not null,
  summary         text,
  actions         jsonb not null default '[]',
  tables_affected text[] not null default '{}',
  records_added   int not null default 0,
  records_updated int not null default 0,
  flags           text[] not null default '{}'
);

create index interaction_people_person_idx on interaction_people (person_id);
create index hooks_open_idx on hooks (interaction_id) where resolved_on is null;
create index interactions_date_idx on interactions (date desc);
create index people_embedding_idx on people using hnsw (embedding extensions.vector_cosine_ops);
create index interactions_embedding_idx on interactions using hnsw (embedding extensions.vector_cosine_ops);
create index voice_notes_embedding_idx on voice_notes using hnsw (embedding extensions.vector_cosine_ops);

create function crm_touch_updated_at() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger people_updated_at before update on people
  for each row execute function crm_touch_updated_at();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Normalize a name for matching: lowercase, strip accents, drop a trailing
-- parenthetical, punctuation to spaces, collapse whitespace.
create function crm_norm(t text) returns text
language sql stable set search_path = public, extensions as $$
  select btrim(regexp_replace(
           regexp_replace(
             regexp_replace(lower(unaccent(coalesce(t, ''))), '\s*\([^)]*\)\s*$', ''),
             '[^a-z0-9]+', ' ', 'g'),
           '\s+', ' ', 'g'))
$$;

-- Text used to embed a person for semantic search.
create function crm_person_text(p_id bigint) returns text
language sql stable set search_path = public as $$
  select concat_ws(E'\n',
    p.name,
    nullif(array_to_string(array_remove(array[p.community_name] || p.aliases, null), ', '), ''),
    p.relationship_tier,
    p.job, p.location, p.how_we_met,
    nullif(array_to_string(p.tags, ', '), ''),
    nullif(array_to_string(p.likes_interests, ', '), ''),
    nullif(array_to_string(p.family_pets, ', '), ''),
    (select string_agg(g.name, ', ') from person_groups pg join groups g on g.id = pg.group_id where pg.person_id = p.id),
    p.history, p.notes)
  from people p where p.id = p_id
$$;

-- Compact directory of everyone, for the model's name resolution.
create function crm_directory()
returns table (id bigint, name text, also_known_as text[], tier text, groups text[], last_contacted date)
language sql stable set search_path = public as $$
  select p.id, p.name,
         array_remove(array[p.community_name] || p.aliases, null),
         p.relationship_tier,
         coalesce((select array_agg(g.name order by g.name) from person_groups pg join groups g on g.id = pg.group_id where pg.person_id = p.id), '{}'),
         p.last_contacted
  from people p
  order by p.name
$$;

-- Fuzzy name lookup (typos, partial names, nicknames).
create function crm_find_people(q text, lim int default 8)
returns table (id bigint, name text, also_known_as text[], tier text, score real)
language sql stable set search_path = public, extensions as $$
  with cand as (
    select p.id, p.name, array_remove(array[p.community_name] || p.aliases, null) as aka, p.relationship_tier as tier,
           greatest(
             similarity(crm_norm(p.name), crm_norm(q)),
             word_similarity(crm_norm(q), crm_norm(p.name)),
             coalesce((select max(greatest(similarity(crm_norm(a), crm_norm(q)), word_similarity(crm_norm(q), crm_norm(a))))
                       from unnest(array_remove(array[p.community_name] || p.aliases, null)) a), 0)
           ) as score
    from people p
  )
  select id, name, aka, tier, score from cand
  where score >= 0.3
  order by score desc, name
  limit lim
$$;

-- Everything known about one person, for recaps and before editing.
create function crm_person_card(p_id bigint) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_strip_nulls(to_jsonb(p) - 'embedding') || jsonb_build_object(
    'groups', coalesce((select jsonb_agg(g.name order by g.name) from person_groups pg join groups g on g.id = pg.group_id where pg.person_id = p.id), '[]'),
    'partner', (select q.name from people q where q.id = p.partner_id),
    'open_hooks', coalesce((
      select jsonb_agg(jsonb_build_object('hook_id', h.id, 'hook', h.hook, 'raised_on', h.raised_on) order by h.raised_on desc)
      from hooks h join interaction_people ip on ip.interaction_id = h.interaction_id
      where ip.person_id = p.id and h.resolved_on is null and (h.person_id is null or h.person_id = p.id)), '[]'),
    'recent_interactions', coalesce((
      select jsonb_agg(x order by x->>'date' desc) from (
        select jsonb_strip_nulls(jsonb_build_object('id', i.id, 'date', i.date, 'type', i.type, 'summary', i.summary, 'notes', i.notes,
                 'with', (select jsonb_agg(o.name) from interaction_people op join people o on o.id = op.person_id where op.interaction_id = i.id and o.id <> p.id))) as x
        from interactions i join interaction_people ip on ip.interaction_id = i.id
        where ip.person_id = p.id
        order by i.date desc, i.id desc limit 5) s), '[]'),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('name', e.name, 'date', e.date) order by e.date desc nulls last)
      from event_people ep join events e on e.id = ep.event_id where ep.person_id = p.id), '[]'),
    'rosters', coalesce((
      select jsonb_agg(jsonb_build_object('roster', r.name, 'date', r.date) order by r.date)
      from roster_people rp join rosters r on r.id = rp.roster_id where rp.person_id = p.id), '[]'))
  from people p where p.id = p_id
$$;

-- Who is due for a reach-out, per their own cadence.
-- Unset cadence counts as 30 days for Building people and is skipped otherwise.
create function crm_people_due(p_tiers text[] default null, p_today date default current_date)
returns table (id bigint, name text, tier text, cadence text, cadence_days int, last_contacted date,
               days_since int, days_overdue int, phone text, due boolean)
language sql stable set search_path = public as $$
  with base as (
    select p.*, coalesce(c.days, case when p.relationship_tier = 'Building' and p.follow_up_frequency is null then 30 end) as cd
    from people p left join follow_up_cadences c on c.name = p.follow_up_frequency
    where (p_tiers is null or p.relationship_tier = any(p_tiers))
  )
  select id, name, relationship_tier, follow_up_frequency, cd, last_contacted,
         (p_today - last_contacted), (p_today - last_contacted) - cd, phone,
         last_contacted is null or (p_today - last_contacted) >= cd
  from base
  where cd is not null
  order by (last_contacted is null) desc, ((p_today - last_contacted) - cd) desc nulls first, name
$$;

create function crm_upcoming_birthdays(p_days int default 30, p_today date default current_date)
returns table (id bigint, name text, birthday date, next_birthday date, turning int)
language sql stable set search_path = public as $$
  with b as (
    select p.id, p.name, p.birthday,
           case when make_date(extract(year from p_today)::int, extract(month from p.birthday)::int,
                               least(extract(day from p.birthday)::int, case when extract(month from p.birthday) = 2 then 28 else 31 end)) >= p_today
                then make_date(extract(year from p_today)::int, extract(month from p.birthday)::int,
                               least(extract(day from p.birthday)::int, case when extract(month from p.birthday) = 2 then 28 else 31 end))
                else make_date(extract(year from p_today)::int + 1, extract(month from p.birthday)::int,
                               least(extract(day from p.birthday)::int, case when extract(month from p.birthday) = 2 then 28 else 31 end))
           end as nb
    from people p where p.birthday is not null
  )
  select id, name, birthday, nb,
         case when extract(year from birthday) <> 1904 then extract(year from nb)::int - extract(year from birthday)::int end
  from b where nb <= p_today + p_days
  order by nb
$$;

create function crm_recent_interactions(p_since date, lim int default 30)
returns table (id bigint, date date, type text, summary text, people text[], open_hooks text[])
language sql stable set search_path = public as $$
  select i.id, i.date, i.type, i.summary,
         (select array_agg(p.name order by p.name) from interaction_people ip join people p on p.id = ip.person_id where ip.interaction_id = i.id),
         (select array_agg(h.hook order by h.id) from hooks h where h.interaction_id = i.id and h.resolved_on is null)
  from interactions i
  where i.date >= p_since
  order by i.date desc, i.id desc
  limit lim
$$;

-- Hybrid search over interactions, voice notes and people: full-text plus
-- (when an embedding is supplied) vector similarity, merged by reciprocal rank.
create function crm_search(q text, query_embedding extensions.vector(384) default null, lim int default 10)
returns table (kind text, id bigint, date date, people text[], content text, score double precision)
language sql stable set search_path = public, extensions as $$
  with docs as (
    select 'interaction'::text as kind, i.id, i.date,
           (select array_agg(p.name) from interaction_people ip join people p on p.id = ip.person_id where ip.interaction_id = i.id) as people,
           concat_ws(E'\n', i.type || ': ' || i.summary, i.location, i.notes,
                     (select string_agg('hook: ' || h.hook || coalesce(' (resolved ' || h.resolved_on || ')', ''), E'\n') from hooks h where h.interaction_id = i.id)) as content,
           i.embedding
    from interactions i
    union all
    select 'voice_note', v.id, coalesce(v.spoken_at, v.received_at)::date, null, v.transcript, v.embedding
    from voice_notes v
    union all
    select 'person', p.id, p.last_contacted, array[p.name], crm_person_text(p.id), p.embedding
    from people p
  ),
  fts as (
    select kind, id, row_number() over (order by ts_rank(to_tsvector('english', content), websearch_to_tsquery('english', q)) desc) as r
    from docs
    where to_tsvector('english', content) @@ websearch_to_tsquery('english', q)
    limit 30
  ),
  vec as (
    select kind, id, row_number() over (order by embedding <=> query_embedding) as r
    from docs
    where query_embedding is not null and embedding is not null
    order by embedding <=> query_embedding
    limit 30
  ),
  fused as (
    select kind, id, sum(1.0 / (60 + r)) as score
    from (select * from fts union all select * from vec) u
    group by kind, id
  )
  select d.kind, d.id, d.date, d.people, left(d.content, 1500), f.score
  from fused f join docs d using (kind, id)
  order by f.score desc
  limit lim
$$;

create function crm_search_rosters(q text)
returns table (roster_id bigint, roster text, date date, matching_lines text[], anchor text)
language sql stable set search_path = public, extensions as $$
  select r.id, r.name, r.date,
         array_agg(l order by l),
         concat_ws(' / ', (select g.name from groups g where g.id = r.anchor_group_id),
                          (select p.name from people p where p.id = r.anchor_person_id),
                          (select e.name from events e where e.id = r.event_id))
  from rosters r, regexp_split_to_table(r.names, E'\n') l
  where btrim(l) <> ''
    and (crm_norm(split_part(l, ' — ', 1)) = crm_norm(q)
         or similarity(crm_norm(split_part(l, ' — ', 1)), crm_norm(q)) >= 0.5)
  group by r.id
  order by r.date
$$;

-- Names that keep showing up on rosters but are not contacts yet.
create function crm_roster_recurrence(p_min int default 3)
returns table (name text, appearances int, first_seen date, last_seen date, rosters text[], existing_person_id bigint)
language sql stable set search_path = public, extensions as $$
  with lines as (
    select r.id, r.name as roster, r.date, crm_norm(split_part(l, ' — ', 1)) as n, btrim(split_part(l, ' — ', 1)) as raw
    from rosters r, regexp_split_to_table(r.names, E'\n') l
    where btrim(l) <> ''
  )
  select min(raw), count(distinct id)::int, min(date), max(date), array_agg(distinct roster),
         (select p.id from people p where crm_norm(p.name) = lines.n
             or crm_norm(p.community_name) = lines.n
             or exists (select 1 from unnest(p.aliases) a where crm_norm(a) = lines.n) limit 1)
  from lines
  where n <> ''
  group by n
  having count(distinct id) >= p_min
  order by count(distinct id) desc, min(date)
$$;

-- ---------------------------------------------------------------------------
-- crm_apply_plan: the single write path.
--
-- Plan shape (all keys optional unless noted):
-- {
--   "occurred_on": "YYYY-MM-DD",              -- default for dates below
--   "groups":  [{"ref", "id"?, "name", "type", "subtype", "abbreviation", "notes", "attended_on"}],
--   "people":  [{"ref", "id"? | "name", "set": {field: value}, "overwrite": [field],
--                "add": {aliases|socials|tags|likes_interests|family_pets: [..]},
--                "append": {history|notes: text}, "groups": [ref], "partner": ref}],
--   "events":  [{"ref", "id"?, "name", "date", "location", "notes", "people": [ref]}],
--   "interactions": [{"date", "type"*, "summary"*, "location", "notes", "people"*: [ref],
--                     "hooks": [{"text"*, "person": ref?}]}],
--   "resolve_hooks": [{"id"*, "resolution"}],
--   "rosters": [{"name"*, "date", "source", "names"*: [..], "notes",
--                "anchor_group", "anchor_person", "event", "people": [ref]}],
--   "flags": [text],                          -- open questions for the user
--   "confirmation": text                      -- what the user will be told
-- }
-- A ref is either a "ref" declared in this plan or an existing record id
-- (as a string or number).
-- ---------------------------------------------------------------------------

create function crm_ref(p_map jsonb, p_ref text, p_table text) returns bigint
language plpgsql stable set search_path = public as $$
declare
  v_id bigint;
  v_ok boolean;
begin
  if p_ref is null or btrim(p_ref) = '' then
    return null;
  end if;
  if p_map ? p_ref then
    return (p_map ->> p_ref)::bigint;
  end if;
  if p_ref ~ '^\d+$' then
    v_id := p_ref::bigint;
    execute format('select exists (select 1 from %I where id = $1)', p_table) into v_ok using v_id;
    if v_ok then
      return v_id;
    end if;
  end if;
  raise exception 'unknown % reference "%": use an existing id or a ref declared in this plan', p_table, p_ref;
end $$;

create function crm_apply_plan(p_plan jsonb, p_note_id bigint default null, p_requested_by text default 'voice note')
returns jsonb
language plpgsql set search_path = public, extensions as $$
declare
  c_scalar  constant text[] := array['community_name', 'phone', 'email', 'location', 'birthday', 'known_since',
                                     'relationship_tier', 'follow_up_frequency', 'next_follow_up', 'job', 'how_we_met'];
  c_dates   constant text[] := array['birthday', 'known_since', 'next_follow_up'];
  c_arrays  constant text[] := array['aliases', 'socials', 'tags', 'likes_interests', 'family_pets'];
  v_on        date := coalesce(nullif(p_plan ->> 'occurred_on', '')::date, current_date);
  v_people    jsonb := '{}';
  v_groups    jsonb := '{}';
  v_events    jsonb := '{}';
  v_flags     text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p_plan -> 'flags', '[]'))), '{}');
  v_info      text[] := '{}';
  v_actions   jsonb := '[]';
  v_tables    text[] := '{}';
  v_added     int := 0;
  v_updated   int := 0;
  v_touched   bigint[] := '{}';
  v_new_ix    bigint[] := '{}';
  v_out_people jsonb := '[]';
  v_partners  jsonb := '[]';
  e jsonb; h jsonb; kv record;
  v_id bigint; v_other bigint; v_new boolean; v_name text; v_cur text; v_val text; v_cnt int;
  v_names text[]; v_first date; v_changed boolean; v_changelog bigint;
begin
  -- Groups -------------------------------------------------------------------
  for e in select * from jsonb_array_elements(coalesce(p_plan -> 'groups', '[]')) loop
    if nullif(e ->> 'id', '') is not null then
      v_id := crm_ref('{}', e ->> 'id', 'groups');
    else
      v_name := btrim(coalesce(e ->> 'name', ''));
      if v_name = '' then
        raise exception 'group % needs an id or a name', coalesce(e ->> 'ref', '?');
      end if;
      select g.id into v_id from groups g
      where crm_norm(g.name) = crm_norm(v_name) or crm_norm(g.abbreviation) = crm_norm(v_name)
      order by g.id limit 1;
      if v_id is null then
        insert into groups (name, type, subtype, abbreviation, notes)
        values (v_name, nullif(e ->> 'type', ''), nullif(e ->> 'subtype', ''), nullif(e ->> 'abbreviation', ''), nullif(e ->> 'notes', ''))
        returning id into v_id;
        v_added := v_added + 1;
        v_tables := v_tables || 'groups'::text;
        v_actions := v_actions || jsonb_build_object('action', 'created group', 'id', v_id, 'name', v_name);
        e := e - 'type' - 'subtype' - 'abbreviation' - 'notes';
      end if;
    end if;
    update groups g set
      type         = coalesce(g.type, nullif(e ->> 'type', '')),
      subtype      = coalesce(g.subtype, nullif(e ->> 'subtype', '')),
      abbreviation = coalesce(g.abbreviation, nullif(e ->> 'abbreviation', '')),
      notes        = case when nullif(e ->> 'notes', '') is null then g.notes
                          else concat_ws(E'\n', g.notes, e ->> 'notes') end,
      last_contacted = case when nullif(e ->> 'attended_on', '') is null then g.last_contacted
                            else greatest(g.last_contacted, (e ->> 'attended_on')::date) end
    where g.id = v_id;
    if nullif(e ->> 'ref', '') is not null then
      v_groups := v_groups || jsonb_build_object(e ->> 'ref', v_id);
    end if;
    v_id := null;
  end loop;

  -- People -------------------------------------------------------------------
  for e in select * from jsonb_array_elements(coalesce(p_plan -> 'people', '[]')) loop
    v_new := false;
    v_changed := false;
    if nullif(e ->> 'id', '') is not null then
      v_id := crm_ref('{}', e ->> 'id', 'people');
    else
      v_name := btrim(coalesce(e ->> 'name', ''));
      if v_name = '' then
        raise exception 'person % needs an id (existing contact) or a name (new contact)', coalesce(e ->> 'ref', '?');
      end if;
      select p.id into v_other from people p where crm_norm(p.name) = crm_norm(v_name) limit 1;
      if v_other is not null then
        v_flags := v_flags || format('Created a new "%s" although contact #%s has the same name. If they are the same person, say so and I will merge them.', v_name, v_other);
        v_other := null;
      end if;
      insert into people (name) values (v_name) returning id into v_id;
      v_new := true;
      v_added := v_added + 1;
      v_tables := v_tables || 'people'::text;
      v_actions := v_actions || jsonb_build_object('action', 'created person', 'id', v_id, 'name', v_name);
    end if;
    select p.name into v_name from people p where p.id = v_id;
    if nullif(e ->> 'ref', '') is not null then
      v_people := v_people || jsonb_build_object(e ->> 'ref', v_id);
    end if;

    -- Scalar fields: fill empties; change filled ones only when asked to.
    for kv in select key, value from jsonb_each_text(coalesce(e -> 'set', '{}')) loop
      continue when kv.value is null or btrim(kv.value) = '';
      if not kv.key = any(c_scalar) then
        raise exception 'person field "%" cannot be set (allowed: %)', kv.key, array_to_string(c_scalar, ', ');
      end if;
      if kv.key = 'relationship_tier' and not exists (select 1 from relationship_tiers t where t.name = kv.value) then
        raise exception 'unknown relationship_tier "%" (allowed: %)', kv.value, (select string_agg(name, ', ' order by sort_order) from relationship_tiers);
      end if;
      if kv.key = 'follow_up_frequency' and not exists (select 1 from follow_up_cadences c where c.name = kv.value) then
        raise exception 'unknown follow_up_frequency "%" (allowed: %)', kv.value, (select string_agg(name, ', ' order by coalesce(days, 99999)) from follow_up_cadences);
      end if;
      execute format('select %I::text from people where id = $1', kv.key) into v_cur using v_id;
      v_val := btrim(kv.value);
      if v_cur is null or btrim(v_cur) = '' or v_new
         or kv.key = any(array(select jsonb_array_elements_text(coalesce(e -> 'overwrite', '[]')))) then
        if v_cur is not distinct from v_val then
          continue;
        end if;
        execute format('update people set %I = $1::%s where id = $2', kv.key,
                       case when kv.key = any(c_dates) then 'date' else 'text' end)
          using v_val, v_id;
        v_changed := true;
        v_actions := v_actions || jsonb_strip_nulls(jsonb_build_object('action', 'set', 'person', v_name, 'field', kv.key, 'value', v_val, 'previous', v_cur));
      elsif lower(btrim(v_cur)) <> lower(v_val) then
        v_flags := v_flags || format('Kept %s''s %s as "%s" (the note said "%s"). Say "change %s''s %s" to update it.',
                                     v_name, replace(kv.key, '_', ' '), v_cur, v_val, v_name, replace(kv.key, '_', ' '));
      end if;
    end loop;

    -- List fields: union, case-insensitive, never removes.
    for kv in select key, value from jsonb_each(coalesce(e -> 'add', '{}')) loop
      if not kv.key = any(c_arrays) then
        raise exception 'person list field "%" not allowed (allowed: %)', kv.key, array_to_string(c_arrays, ', ');
      end if;
      execute format(
        'update people set %1$I = %1$I || array(
           select distinct on (lower(btrim(x))) btrim(x) from jsonb_array_elements_text($1) x
           where btrim(x) <> '''' and lower(btrim(x)) <> all (select lower(y) from unnest(%1$I) y))
         where id = $2 and exists (
           select 1 from jsonb_array_elements_text($1) x
           where btrim(x) <> '''' and lower(btrim(x)) <> all (select lower(y) from unnest(%1$I) y))', kv.key)
        using kv.value, v_id;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        v_changed := true;
        v_actions := v_actions || jsonb_build_object('action', 'added', 'person', v_name, 'field', kv.key, 'values', kv.value);
      end if;
    end loop;

    -- Long text: append only, dated.
    for kv in select key, value from jsonb_each_text(coalesce(e -> 'append', '{}')) loop
      continue when kv.value is null or btrim(kv.value) = '';
      if kv.key not in ('history', 'notes') then
        raise exception 'person append field "%" not allowed (allowed: history, notes)', kv.key;
      end if;
      execute format('update people set %1$I = concat_ws(E''\n'', %1$I, $1) where id = $2', kv.key)
        using '[' || v_on || '] ' || btrim(kv.value), v_id;
      v_changed := true;
      v_actions := v_actions || jsonb_build_object('action', 'appended', 'person', v_name, 'field', kv.key, 'value', kv.value);
    end loop;

    -- Group links: insert-only, so existing links are never dropped.
    for v_val in select jsonb_array_elements_text(coalesce(e -> 'groups', '[]')) loop
      insert into person_groups (person_id, group_id) values (v_id, crm_ref(v_groups, v_val, 'groups'))
      on conflict do nothing;
      if found then
        v_changed := true;
        v_tables := v_tables || 'groups'::text;
        v_actions := v_actions || jsonb_build_object('action', 'linked group', 'person', v_name,
                                   'group', (select g.name from groups g where g.id = crm_ref(v_groups, v_val, 'groups')));
      end if;
    end loop;

    if nullif(e ->> 'partner', '') is not null then
      v_partners := v_partners || jsonb_build_object('person', v_id, 'partner', e ->> 'partner');
    end if;

    -- New contact: cross-reference earlier rosters for the name and aliases.
    if v_new then
      select array_agg(distinct n) into v_names from (
        select crm_norm(p.name) n from people p where p.id = v_id
        union select crm_norm(p.community_name) from people p where p.id = v_id and p.community_name is not null
        union select crm_norm(a) from people p, unnest(p.aliases) a where p.id = v_id) s where n <> '';
      with hits as (
        select r.id, r.date from rosters r
        where exists (select 1 from regexp_split_to_table(r.names, E'\n') l
                      where crm_norm(split_part(l, ' — ', 1)) = any(v_names)))
      , ins as (insert into roster_people (roster_id, person_id) select id, v_id from hits on conflict do nothing returning roster_id)
      select count(*), min(h2.date) into v_cnt, v_first from hits h2;
      if v_cnt > 0 then
        update people set known_since = v_first where id = v_id and known_since is null;
        v_tables := v_tables || 'rosters'::text;
        v_info := v_info || format('%s is already on %s earlier name list(s), first on %s. Linked them.', v_name, v_cnt, coalesce(v_first::text, 'an undated list'));
      end if;
    elsif v_changed then
      v_updated := v_updated + 1;
      v_tables := v_tables || 'people'::text;
    end if;

    v_touched := v_touched || v_id;
    v_out_people := v_out_people || jsonb_build_object('ref', e ->> 'ref', 'id', v_id, 'name', v_name, 'new', v_new);
    v_id := null;
  end loop;

  -- Partners: set both directions, only where empty.
  for e in select * from jsonb_array_elements(v_partners) loop
    v_id := (e ->> 'person')::bigint;
    v_other := crm_ref(v_people, e ->> 'partner', 'people');
    if v_other = v_id then
      raise exception 'a person cannot be their own partner';
    end if;
    update people set partner_id = v_other where id = v_id and partner_id is null;
    update people set partner_id = v_id where id = v_other and partner_id is null;
    if exists (select 1 from people where id in (v_id, v_other) and partner_id not in (v_id, v_other)) then
      v_flags := v_flags || format('Partner not changed: %s or %s already has a different partner on file.',
                                   (select name from people where id = v_id), (select name from people where id = v_other));
    else
      v_actions := v_actions || jsonb_build_object('action', 'linked partners', 'ids', jsonb_build_array(v_id, v_other));
    end if;
  end loop;

  -- Events -------------------------------------------------------------------
  for e in select * from jsonb_array_elements(coalesce(p_plan -> 'events', '[]')) loop
    if nullif(e ->> 'id', '') is not null then
      v_id := crm_ref('{}', e ->> 'id', 'events');
    else
      if btrim(coalesce(e ->> 'name', '')) = '' then
        raise exception 'event % needs an id or a name', coalesce(e ->> 'ref', '?');
      end if;
      insert into events (name, date, location, notes, source_note_id)
      values (btrim(e ->> 'name'), coalesce(nullif(e ->> 'date', '')::date, v_on), nullif(e ->> 'location', ''), nullif(e ->> 'notes', ''), p_note_id)
      returning id into v_id;
      v_added := v_added + 1;
      v_tables := v_tables || 'events'::text;
      v_actions := v_actions || jsonb_build_object('action', 'created event', 'id', v_id, 'name', e ->> 'name');
    end if;
    if nullif(e ->> 'ref', '') is not null then
      v_events := v_events || jsonb_build_object(e ->> 'ref', v_id);
    end if;
    insert into event_people (event_id, person_id)
    select v_id, crm_ref(v_people, x, 'people') from jsonb_array_elements_text(coalesce(e -> 'people', '[]')) x
    on conflict do nothing;
    v_id := null;
  end loop;

  -- Interactions + follow-up hooks -------------------------------------------
  for e in select * from jsonb_array_elements(coalesce(p_plan -> 'interactions', '[]')) loop
    if jsonb_array_length(coalesce(e -> 'people', '[]')) = 0 then
      raise exception 'interaction "%" must list at least one person', e ->> 'summary';
    end if;
    insert into interactions (date, type, summary, location, notes, source_note_id)
    values (coalesce(nullif(e ->> 'date', '')::date, v_on), e ->> 'type', btrim(e ->> 'summary'),
            nullif(e ->> 'location', ''), nullif(e ->> 'notes', ''), p_note_id)
    returning id into v_id;
    insert into interaction_people (interaction_id, person_id)
    select v_id, crm_ref(v_people, x, 'people') from jsonb_array_elements_text(e -> 'people') x
    on conflict do nothing;
    for h in select * from jsonb_array_elements(coalesce(e -> 'hooks', '[]')) loop
      continue when btrim(coalesce(h ->> 'text', '')) = '';
      v_other := crm_ref(v_people, h ->> 'person', 'people');
      if v_other is not null and not exists (select 1 from interaction_people where interaction_id = v_id and person_id = v_other) then
        raise exception 'hook "%" names a person who is not in that interaction', h ->> 'text';
      end if;
      insert into hooks (interaction_id, person_id, hook, raised_on)
      values (v_id, v_other, btrim(h ->> 'text'), coalesce(nullif(e ->> 'date', '')::date, v_on));
    end loop;
    -- Last Contacted only ever moves forward.
    update people p set last_contacted = greatest(p.last_contacted, i.date)
    from interactions i, interaction_people ip
    where i.id = v_id and ip.interaction_id = i.id and p.id = ip.person_id;
    v_touched := v_touched || array(select person_id from interaction_people where interaction_id = v_id);
    v_new_ix := v_new_ix || v_id;
    v_added := v_added + 1;
    v_tables := v_tables || 'interactions'::text;
    v_actions := v_actions || jsonb_build_object('action', 'logged interaction', 'id', v_id, 'summary', e ->> 'summary',
                                                 'hooks', jsonb_array_length(coalesce(e -> 'hooks', '[]')));
    v_id := null;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p_plan -> 'resolve_hooks', '[]')) loop
    update hooks set resolved_on = v_on, resolution = nullif(e ->> 'resolution', '')
    where id = (e ->> 'id')::bigint and resolved_on is null;
    if found then
      v_updated := v_updated + 1;
      v_actions := v_actions || jsonb_build_object('action', 'resolved hook', 'id', e ->> 'id');
    else
      v_flags := v_flags || format('Follow-up hook #%s was not open, so nothing was resolved.', e ->> 'id');
    end if;
  end loop;

  -- Rosters ------------------------------------------------------------------
  for e in select * from jsonb_array_elements(coalesce(p_plan -> 'rosters', '[]')) loop
    if jsonb_array_length(coalesce(e -> 'names', '[]')) = 0 then
      raise exception 'roster "%" has no names', e ->> 'name';
    end if;
    insert into rosters (name, date, source, names, notes, anchor_group_id, anchor_person_id, event_id, source_note_id)
    values (btrim(e ->> 'name'), coalesce(nullif(e ->> 'date', '')::date, v_on), nullif(e ->> 'source', ''),
            (select string_agg(btrim(x), E'\n') from jsonb_array_elements_text(e -> 'names') x where btrim(x) <> ''),
            nullif(e ->> 'notes', ''),
            crm_ref(v_groups, e ->> 'anchor_group', 'groups'),
            crm_ref(v_people, e ->> 'anchor_person', 'people'),
            crm_ref(v_events, e ->> 'event', 'events'),
            p_note_id)
    returning id into v_id;
    -- Links the model matched (fuzzy, judged) ...
    insert into roster_people (roster_id, person_id)
    select v_id, crm_ref(v_people, x, 'people') from jsonb_array_elements_text(coalesce(e -> 'people', '[]')) x
    on conflict do nothing;
    -- ... plus exact normalized matches that are unambiguous.
    with lines as (
      select distinct crm_norm(split_part(x, ' — ', 1)) n from jsonb_array_elements_text(e -> 'names') x
    ), m as (
      select l.n, p.id from lines l join people p
        on l.n <> '' and (crm_norm(p.name) = l.n or crm_norm(p.community_name) = l.n
                          or exists (select 1 from unnest(p.aliases) a where crm_norm(a) = l.n))
    )
    insert into roster_people (roster_id, person_id)
    select v_id, min(m.id) from m group by m.n having count(distinct m.id) = 1
    on conflict do nothing;
    v_flags := v_flags || array(
      select format('Roster name "%s" matches several contacts (%s); left unlinked.', l.n, string_agg(p.name || ' #' || p.id, ', '))
      from (select distinct crm_norm(split_part(x, ' — ', 1)) n from jsonb_array_elements_text(e -> 'names') x) l
      join people p on l.n <> '' and (crm_norm(p.name) = l.n or crm_norm(p.community_name) = l.n
                                      or exists (select 1 from unnest(p.aliases) a where crm_norm(a) = l.n))
      group by l.n having count(distinct p.id) > 1);
    select count(*) into v_cnt from roster_people where roster_id = v_id;
    v_added := v_added + 1;
    v_tables := v_tables || 'rosters'::text;
    v_actions := v_actions || jsonb_build_object('action', 'created roster', 'id', v_id, 'name', e ->> 'name',
                                                 'names', jsonb_array_length(e -> 'names'), 'linked_contacts', v_cnt);
    v_id := null;
  end loop;

  -- Audit trail --------------------------------------------------------------
  v_tables := array(select distinct t from unnest(v_tables) t order by t);
  if jsonb_array_length(v_actions) > 0 or cardinality(v_flags) > 0 then
    insert into changelog (source_note_id, requested_by, summary, actions, tables_affected, records_added, records_updated, flags)
    values (p_note_id, p_requested_by, nullif(p_plan ->> 'confirmation', ''), v_actions, v_tables, v_added, v_updated, v_flags)
    returning id into v_changelog;
  end if;

  if p_note_id is not null then
    update voice_notes set
      status = case when cardinality(v_flags) > 0 then 'needs_review' else 'done' end,
      flags = v_flags,
      result_summary = nullif(p_plan ->> 'confirmation', ''),
      processed_at = now(),
      error = null
    where id = p_note_id;
  end if;

  return jsonb_build_object(
    'people', v_out_people,
    'interaction_ids', to_jsonb(v_new_ix),
    'touched_people', to_jsonb(array(select distinct x from unnest(v_touched) x)),
    'flags', to_jsonb(v_flags),
    'info', to_jsonb(v_info),
    'records_added', v_added,
    'records_updated', v_updated,
    'changelog_id', v_changelog);
end $$;

-- ---------------------------------------------------------------------------
-- Lock it down: only the service role (Edge Functions) and the owner.
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

revoke all on all tables in schema public from public;
revoke all on all sequences in schema public from public;
revoke execute on all functions in schema public from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema public from anon, authenticated';
    execute 'revoke all on all sequences in schema public from anon, authenticated';
    execute 'revoke execute on all functions in schema public from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on all tables in schema public to service_role';
    execute 'grant all on all sequences in schema public to service_role';
    execute 'grant execute on all functions in schema public to service_role';
  end if;
end $$;
