-- Run once in the Supabase dashboard's SQL Editor after deploying the
-- `followups` function. Replace the two placeholders first. Not a migration:
-- it stores your shared secret, which must never be committed.
--
-- Every hour at :30 the database calls the function; it only sends a push
-- during your morning window (CRM_NUDGE_HOUR, default 9, in CRM_TIMEZONE),
-- only when something is due, and at most once a day.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Secrets live in Supabase Vault (encrypted), not in the job definition.
select vault.create_secret('https://YOUR_PROJECT_REF.supabase.co/functions/v1/followups', 'crm_followups_url');
select vault.create_secret('YOUR_SHARED_SECRET', 'crm_shared_secret');

select cron.schedule(
  'crm-morning-reminders',
  '30 * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'crm_followups_url'),
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-crm-key', (select decrypted_secret from vault.decrypted_secrets where name = 'crm_shared_secret')),
    body := '{"action": "nudge"}'::jsonb,
    timeout_milliseconds := 30000)
  $$
);

-- Useful later:
--   select * from cron.job_run_details order by start_time desc limit 5;   -- did it run?
--   select * from nudge_runs order by run_date desc limit 7;               -- what it decided each day
--   select cron.unschedule('crm-morning-reminders');                       -- turn it off
-- After rotating the shared secret:
--   select vault.update_secret((select id from vault.secrets where name = 'crm_shared_secret'), 'NEW_SECRET');
