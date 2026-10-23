-- Birthdays and important dates handled from the Follow-ups Shortcut. They
-- are due for a single day, so acting on one (Done, Snooze, Not relevant, Text,
-- Call) hides it for the rest of that day instead of leaving it in the list,
-- where a second tap would log the same text or call twice.

create table date_reminders_handled (
  kind       text   not null check (kind in ('birthday', 'date')),
  ref_id     bigint not null,  -- people.id for a birthday, important_dates.id for a date
  on_date    date   not null,
  action     text   not null,
  created_at timestamptz not null default now(),
  primary key (kind, ref_id, on_date)
);

alter table date_reminders_handled enable row level security;
revoke all on date_reminders_handled from public;

create or replace function crm_due_reminders(p_today date default current_date, p_for_push boolean default false)
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
    and not exists (select 1 from date_reminders_handled x where x.kind = 'birthday' and x.ref_id = p.id and x.on_date = p_today)
  union all
  select 'date', d.id, p.name, array[p.id], p.phone,
         d.label || case when d.remind_days_before = 0 then ' today'
                         else ' on ' || to_char(case when d.yearly then crm_next_occurrence(d.date, p_today) else d.date end, 'Dy Mon FMDD') end,
         null, 6
  from important_dates d join people p on p.id = d.person_id
  where (case when d.yearly then crm_next_occurrence(d.date, p_today) else d.date end) - d.remind_days_before = p_today
    and not exists (select 1 from date_reminders_handled x where x.kind = 'date' and x.ref_id = d.id and x.on_date = p_today)
  order by 8, 3
$$;

create or replace function crm_follow_up_action(p_kind text, p_id bigint, p_action text, p_today date default current_date)
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

  -- Birthdays and dates are due for one day; any action clears them for that day.
  -- A second tap on the same day (the list was stale) logs nothing new.
  if p_kind <> 'follow_up' then
    insert into date_reminders_handled (kind, ref_id, on_date, action)
    values (p_kind, p_id, p_today, p_action)
    on conflict do nothing;
    if not found then
      return jsonb_build_object('ok', true, 'message', 'Already handled today.');
    end if;
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
    return jsonb_build_object('ok', true, 'message', 'Cleared for today.');
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

revoke execute on function crm_due_reminders(date, boolean), crm_follow_up_action(text, bigint, text, date) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on date_reminders_handled from anon, authenticated';
    execute 'revoke execute on function crm_due_reminders(date, boolean), crm_follow_up_action(text, bigint, text, date) from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on date_reminders_handled to service_role';
    execute 'grant execute on function crm_due_reminders(date, boolean), crm_follow_up_action(text, bigint, text, date) to service_role';
  end if;
end $$;
