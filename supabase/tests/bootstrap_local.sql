-- Recreates the parts of a Supabase project the migration and functions rely
-- on (API roles, extensions schema) in a plain Postgres + pgvector database.
-- Used only by the local test runner; never run this against Supabase.
create schema if not exists extensions;
create role authenticator login password 'authenticator' noinherit;
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
grant anon, authenticated, service_role to authenticator;
grant usage on schema public, extensions to anon, authenticated, service_role;
