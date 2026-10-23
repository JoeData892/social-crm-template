-- Proactive follow-ups: timing on hooks, important dates, and the queries the
-- daily push and the Follow-ups Shortcut run. Nothing here contacts anyone;
-- it only decides what to remind the user about.

-- ---------------------------------------------------------------------------
-- Hook kinds: how long after the thing happens to check in
-- ---------------------------------------------------------------------------

create table hook_kinds (
  name        text primary key,
  days_after  int  not null check (days_after between 0 and 60),
  description text not null
);

insert into hook_kinds (name, days_after, description) values
  ('trip',      2, 'Travel or a getaway; check in after they are back'),
  ('interview', 1, 'Job or school interview'),
  ('medical',   2, 'Surgery, appointment, test results, recovery'),
  ('move',      7, 'Moving home or city'),
  ('baby',      7, 'Due date or adoption'),
  ('wedding',   3, 'Their own or one they are part of'),
  ('new_job',   7, 'Starting a new job or role'),
  ('exam',      1, 'Test, exam, licensing, defense'),
  ('event',     2, 'Race, show, party, game, or other one-off'),
  ('other',     2, 'Anything else with a date');

-- Undated hooks are followed up this long after they came up.
create function crm_default_follow_up(p_kind text, p_on date, p_until date, p_raised date) returns date
language sql stable set search_path = public as $$
  select case
    when coalesce(p_until, p_on) is not null
      then coalesce(p_until, p_on) + coalesce((select days_after from hook_kinds where name = p_kind), 2)
    else p_raised + 21
  end
$$;

alter table hooks
  add column kind             text references hook_kinds (name) on update cascade,
  add column happens_on       date,
  add column happens_until    date,
  add column date_precision   text check (date_precision in ('exact', 'week', 'month', 'approx')),
  add column follow_up_on     date,
  add column reminded_count   int not null default 0,
  add column last_reminded_on date,
  add column closed_reason    text check (closed_reason in ('resolved', 'asked', 'dismissed')),
  add constraint hooks_dates_ordered check (happens_until is null or happens_on is null or happens_until >= happens_on);

update hooks set closed_reason = 'resolved' where resolved_on is not null;
update hooks set follow_up_on = crm_default_follow_up(kind, happens_on, happens_until, raised_on) where follow_up_on is null;

create function crm_hooks_default_follow_up() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.follow_up_on is null then
    new.follow_up_on := crm_default_follow_up(new.kind, new.happens_on, new.happens_until, new.raised_on);
  end if;
  return new;
end $$;

create trigger hooks_default_follow_up before insert on hooks
  for each row execute function crm_hooks_default_follow_up();

create index hooks_follow_up_idx on hooks (follow_up_on) where resolved_on is null;

-- ---------------------------------------------------------------------------
-- Important dates beyond birthdays (anniversaries, kids' birthdays, ...)
-- ---------------------------------------------------------------------------

create table important_dates (
  id                 bigint generated always as identity primary key,
  person_id          bigint not null references people (id) on delete cascade,
  label              text not null check (btrim(label) <> ''),
  date               date not null,  -- year 1904 = year unknown
  yearly             boolean not null default true,
  remind_days_before int not null default 0 check (remind_days_before between 0 and 60),
  created_at         timestamptz not null default now()
);
create unique index important_dates_label_key on important_dates (person_id, lower(label));

-- Next occurrence of a month/day on or after p_from (Feb 29 -> Feb 28 in other years).
create function crm_next_occurrence(p_date date, p_from date) returns date
language sql immutable as $$
  with y(yr) as (values (extract(year from p_from)::int), (extract(year from p_from)::int + 1))
  select min(d) from (
    select make_date(yr, extract(month from p_date)::int,
                     least(extract(day from p_date)::int,
                           extract(day from (make_date(yr, extract(month from p_date)::int, 1) + interval '1 month - 1 day'))::int)) d
    from y) s
  where d >= p_from
$$;

-- One row per day the morning push ran, so it sends at most once a day.
create table nudge_runs (
  run_date   date primary key,
  status     text not null check (status in ('sending', 'sent', 'nothing_due')),
  item_count int not null default 0,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- What is due
-- ---------------------------------------------------------------------------

-- Due items for a day. p_for_push applies the anti-nag rules (each follow-up is
-- pushed at most twice, at least 3 days apart); the Follow-ups Shortcut lists
-- everything open and due. Ordered closest relationships first.
create function crm_due_reminders(p_today date default current_date, p_for_push boolean default false)
returns table (kind text, id bigint, people text, person_ids bigint[], phone text, what text, detail text, sort_key int)
language sql stable set search_path = public as $$
  with follow_ups as (
    select h.id, h.hook, h.kind, h.happens_on, h.happens_until, h.raised_on, h.follow_up_on,
           array_agg(p.id order by p.name) as ids, array_agg(p.name order by p.name) as names,
           min(p.phone) filter (where p.phone is not null) as phone, count(*) as n,
           min(case p.relationship_tier when 'Close Friend' then 1 when 'Family' then 1 when 'Friend' then 2
                                         when 'Building' then 2 else 3 end) as tier_rank
    from hooks h
    join interaction_people ip on ip.interaction_id = h.interaction_id
    join people p on p.id = ip.person_id and (h.person_id is null or h.person_id = p.id)
    where h.resolved_on is null
      and h.follow_up_on <= p_today
      and (not p_for_push
           or (h.reminded_count < 2 and (h.last_reminded_on is null or h.last_reminded_on <= p_today - 3)))
    group by h.id
  )
  select 'follow_up', f.id, array_to_string(f.names, ' & '), f.ids, case when f.n = 1 then f.phone end,
         f.hook,
         concat_ws('; ',
           case when f.happens_until is not null and f.happens_until <> f.happens_on
                  then 'was ' || to_char(f.happens_on, 'Mon FMDD') || '–' || to_char(f.happens_until, 'Mon FMDD')
                when f.happens_on is not null then 'was ' || to_char(f.happens_on, 'Mon FMDD') end,
           'came up ' || to_char(f.raised_on, 'Mon FMDD')),
         f.tier_rank * 10
  from follow_ups f
  union all
  select 'birthday', p.id, p.name, array[p.id], p.phone,
         'Birthday today' || case when extract(year from p.birthday) <> 1904
                                  then ' (turning ' || (extract(year from p_today)::int - extract(year from p.birthday)::int) || ')' else '' end,
         null, 5
  from people p
  where p.birthday is not null and crm_next_occurrence(p.birthday, p_today) = p_today
  union all
  select 'date', d.id, p.name, array[p.id], p.phone,
         d.label || case when d.remind_days_before = 0 then ' today'
                         else ' on ' || to_char(case when d.yearly then crm_next_occurrence(d.date, p_today) else d.date end, 'Dy Mon FMDD') end,
         null, 6
  from important_dates d join people p on p.id = d.person_id
  where (case when d.yearly then crm_next_occurrence(d.date, p_today) else d.date end) - d.remind_days_before = p_today
  order by 8, 3
$$;

create function crm_upcoming_follow_ups(p_today date default current_date, p_days int default 14)
returns table (id bigint, follow_up_on date, people text, what text, kind text, happens_on date, happens_until date)
language sql stable set search_path = public as $$
  select h.id, h.follow_up_on,
         (select string_agg(p.name, ' & ' order by p.name) from interaction_people ip join people p on p.id = ip.person_id
          where ip.interaction_id = h.interaction_id and (h.person_id is null or h.person_id = p.id)),
         h.hook, h.kind, h.happens_on, h.happens_until
  from hooks h
  where h.resolved_on is null and h.follow_up_on <= p_today + p_days
  order by h.follow_up_on, h.id
$$;

create function crm_mark_reminded(p_hook_ids bigint[], p_today date default current_date) returns void
language sql set search_path = public as $$
  update hooks set reminded_count = reminded_count + 1, last_reminded_on = p_today
  where id = any(p_hook_ids) and resolved_on is null
$$;

-- Actions from the Follow-ups Shortcut. texted/called log the contact as an
-- interaction (through crm_apply_plan, so Last Contacted and the audit trail
-- update) and close a follow-up as asked. Nothing here sends anything.
create function crm_follow_up_action(p_kind text, p_id bigint, p_action text, p_today date default current_date)
returns jsonb
language plpgsql set search_path = public as $$
declare
  v_hook hooks;
  v_people bigint[];
  v_label text;
  v_type text;
begin
  if p_action not in ('done', 'snooze', 'dismiss', 'texted', 'called') then
    raise exception 'unknown action "%"', p_action;
  end if;

  if p_kind = 'follow_up' then
    select * into v_hook from hooks where id = p_id;
    if not found then
      raise exception 'no follow-up #%', p_id;
    end if;
    select array_agg(ip.person_id) into v_people from interaction_people ip
    where ip.interaction_id = v_hook.interaction_id and (v_hook.person_id is null or v_hook.person_id = ip.person_id);
    v_label := v_hook.hook;
  elsif p_kind = 'birthday' then
    v_people := array[p_id];
    v_label := 'birthday';
  elsif p_kind = 'date' then
    select array[person_id], label into v_people, v_label from important_dates where id = p_id;
  else
    raise exception 'unknown kind "%"', p_kind;
  end if;
  if v_people is null then
    raise exception 'nothing found for % #%', p_kind, p_id;
  end if;

  if p_action in ('texted', 'called') then
    v_type := case p_action when 'texted' then 'Text' else 'Phone Call' end;
    perform crm_apply_plan(jsonb_build_object(
      'occurred_on', p_today,
      'interactions', jsonb_build_array(jsonb_build_object(
        'type', v_type,
        'summary', case p_kind when 'follow_up' then 'Followed up about: ' || v_label
                               when 'birthday' then 'Birthday ' || lower(v_type)
                               else v_label end,
        'people', to_jsonb(array(select x::text from unnest(v_people) x)))),
      'confirmation', format('%s from Follow-ups: %s', v_type, v_label)), null, 'follow-ups shortcut');
    if p_kind = 'follow_up' then
      update hooks set resolved_on = p_today, closed_reason = 'asked',
                       resolution = coalesce(resolution, 'Asked by ' || lower(v_type))
      where id = p_id and resolved_on is null;
    end if;
    return jsonb_build_object('ok', true, 'message', format('Logged a %s.', lower(v_type)));
  end if;

  if p_kind <> 'follow_up' then
    return jsonb_build_object('ok', true, 'message', 'Nothing to change for a date reminder.');
  end if;

  if p_action = 'snooze' then
    update hooks set follow_up_on = p_today + 7, reminded_count = 0, last_reminded_on = null where id = p_id and resolved_on is null;
  else
    update hooks set resolved_on = p_today, closed_reason = case p_action when 'done' then 'resolved' else 'dismissed' end
    where id = p_id and resolved_on is null;
  end if;
  insert into changelog (requested_by, summary, actions, tables_affected, records_updated)
  values ('follow-ups shortcut', format('%s follow-up: %s', initcap(p_action), v_label),
          jsonb_build_array(jsonb_build_object('action', p_action, 'hook', p_id)), array['interactions'], 1);
  return jsonb_build_object('ok', true, 'message',
    case p_action when 'snooze' then format('Snoozed until %s.', to_char(p_today + 7, 'Dy Mon FMDD'))
                  when 'done' then 'Marked done.' else 'Dismissed.' end);
end $$;

-- ---------------------------------------------------------------------------
-- Person card: add follow-up timing and important dates
-- ---------------------------------------------------------------------------

create or replace function crm_person_card(p_id bigint) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_strip_nulls(to_jsonb(p) - 'embedding') || jsonb_build_object(
    'groups', coalesce((select jsonb_agg(g.name order by g.name) from person_groups pg join groups g on g.id = pg.group_id where pg.person_id = p.id), '[]'),
    'partner', (select q.name from people q where q.id = p.partner_id),
    'open_hooks', coalesce((
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('hook_id', h.id, 'hook', h.hook, 'raised_on', h.raised_on, 'kind', h.kind,
               'happens_on', h.happens_on, 'happens_until', h.happens_until, 'follow_up_on', h.follow_up_on)) order by h.raised_on desc)
      from hooks h join interaction_people ip on ip.interaction_id = h.interaction_id
      where ip.person_id = p.id and h.resolved_on is null and (h.person_id is null or h.person_id = p.id)), '[]'),
    'important_dates', coalesce((
      select jsonb_agg(jsonb_build_object('label', d.label, 'date', d.date, 'yearly', d.yearly) order by d.date)
      from important_dates d where d.person_id = p.id), '[]'),
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

-- ---------------------------------------------------------------------------
-- crm_apply_plan: adds hook timing ("kind", "happens_on", "happens_until",
-- "date_precision", "follow_up_on" on each hook), "update_hooks", and person
-- "dates" (important dates). Everything else is unchanged from the first
-- migration.
-- ---------------------------------------------------------------------------

create or replace function crm_apply_plan(p_plan jsonb, p_note_id bigint default null, p_requested_by text default 'voice note')
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
  e jsonb; h jsonb; d jsonb; kv record; v_fu date;
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

    -- Important dates: added once per label; a different date for a known label is flagged.
    for d in select * from jsonb_array_elements(coalesce(e -> 'dates', '[]')) loop
      continue when btrim(coalesce(d ->> 'label', '')) = '' or nullif(d ->> 'date', '') is null;
      insert into important_dates (person_id, label, date, yearly, remind_days_before)
      values (v_id, btrim(d ->> 'label'), (d ->> 'date')::date, coalesce((d ->> 'yearly')::boolean, true),
              coalesce((d ->> 'remind_days_before')::int, 0))
      on conflict (person_id, lower(label)) do nothing;
      if found then
        v_changed := true;
        v_actions := v_actions || jsonb_build_object('action', 'added date', 'person', v_name, 'label', d ->> 'label', 'date', d ->> 'date');
      elsif exists (select 1 from important_dates x where x.person_id = v_id and lower(x.label) = lower(btrim(d ->> 'label'))
                    and x.date <> (d ->> 'date')::date) then
        v_flags := v_flags || format('Kept %s''s "%s" date as on file (the note said %s).', v_name, d ->> 'label', d ->> 'date');
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
      if nullif(h ->> 'kind', '') is not null and not exists (select 1 from hook_kinds k where k.name = h ->> 'kind') then
        raise exception 'unknown hook kind "%" (allowed: %)', h ->> 'kind', (select string_agg(name, ', ' order by name) from hook_kinds);
      end if;
      insert into hooks (interaction_id, person_id, hook, raised_on, kind, happens_on, happens_until, date_precision, follow_up_on)
      values (v_id, v_other, btrim(h ->> 'text'), coalesce(nullif(e ->> 'date', '')::date, v_on),
              nullif(h ->> 'kind', ''), nullif(h ->> 'happens_on', '')::date, nullif(h ->> 'happens_until', '')::date,
              nullif(h ->> 'date_precision', ''), nullif(h ->> 'follow_up_on', '')::date)
      returning follow_up_on into v_fu;
      v_info := v_info || format('Reminder %s: %s', to_char(v_fu, 'Mon FMDD'), btrim(h ->> 'text'));
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
    update hooks set resolved_on = v_on, resolution = nullif(e ->> 'resolution', ''), closed_reason = 'resolved'
    where id = (e ->> 'id')::bigint and resolved_on is null;
    if found then
      v_updated := v_updated + 1;
      v_actions := v_actions || jsonb_build_object('action', 'resolved hook', 'id', e ->> 'id');
    else
      v_flags := v_flags || format('Follow-up hook #%s was not open, so nothing was resolved.', e ->> 'id');
    end if;
  end loop;

  -- Changed plans ("the trip moved to December", "remind me in two weeks").
  -- New dates recompute the reminder unless follow_up_on is given; the
  -- reminder count resets either way.
  for e in select * from jsonb_array_elements(coalesce(p_plan -> 'update_hooks', '[]')) loop
    if nullif(e ->> 'kind', '') is not null and not exists (select 1 from hook_kinds k where k.name = e ->> 'kind') then
      raise exception 'unknown hook kind "%" (allowed: %)', e ->> 'kind', (select string_agg(name, ', ' order by name) from hook_kinds);
    end if;
    update hooks k set
      kind           = coalesce(nullif(e ->> 'kind', ''), k.kind),
      happens_on     = coalesce(nullif(e ->> 'happens_on', '')::date, k.happens_on),
      happens_until  = coalesce(nullif(e ->> 'happens_until', '')::date, k.happens_until),
      date_precision = coalesce(nullif(e ->> 'date_precision', ''), k.date_precision),
      follow_up_on   = coalesce(nullif(e ->> 'follow_up_on', '')::date,
                         case when coalesce(e ->> 'kind', e ->> 'happens_on', e ->> 'happens_until') is not null
                              then crm_default_follow_up(coalesce(nullif(e ->> 'kind', ''), k.kind),
                                                         coalesce(nullif(e ->> 'happens_on', '')::date, k.happens_on),
                                                         coalesce(nullif(e ->> 'happens_until', '')::date, k.happens_until),
                                                         k.raised_on)
                              else k.follow_up_on end),
      reminded_count = 0,
      last_reminded_on = null
    where k.id = (e ->> 'id')::bigint and k.resolved_on is null
    returning k.follow_up_on into v_fu;
    if found then
      v_updated := v_updated + 1;
      v_info := v_info || format('Reminder moved to %s: %s', to_char(v_fu, 'Mon FMDD'), (select hook from hooks where id = (e ->> 'id')::bigint));
      v_actions := v_actions || jsonb_build_object('action', 'updated hook', 'id', e ->> 'id', 'follow_up_on', v_fu);
    else
      v_flags := v_flags || format('Follow-up hook #%s was not open, so it was not changed.', e ->> 'id');
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
-- Same lockdown as the first migration, for the new tables and functions.
-- ---------------------------------------------------------------------------

alter table hook_kinds enable row level security;
alter table important_dates enable row level security;
alter table nudge_runs enable row level security;

revoke all on hook_kinds, important_dates, nudge_runs from public;
revoke execute on all functions in schema public from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on hook_kinds, important_dates, nudge_runs from anon, authenticated';
    execute 'revoke execute on all functions in schema public from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on hook_kinds, important_dates, nudge_runs to service_role';
    execute 'grant all on all sequences in schema public to service_role';
    execute 'grant execute on all functions in schema public to service_role';
  end if;
end $$;
