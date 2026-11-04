-- LOCAL DEVELOPMENT ONLY. Lets you be God on your own machine, as god@eon.local.
-- It re-points the God lock at a throwaway address. Never run this against a deployed database.
--
--   docker exec -i supabase_db_EON psql -U postgres -d postgres < scripts/dev-god.sql
--   GOD_EMAIL=god@eon.local node --env-file=.env.development.local scripts/create-god.mjs god-login.txt
do $$
begin
  if exists (select 1 from app.god) then
    raise exception 'A God already exists here: this script is for a fresh local database';
  end if;
end $$;

create or replace function app.god_email_sha256() returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest('god@eon.local', 'sha256'), 'hex');
$$;

alter table app.god drop constraint god_email_sha256_check;
alter table app.god add constraint god_email_sha256_check
  check (email_sha256 = encode(extensions.digest('god@eon.local', 'sha256'), 'hex'));
