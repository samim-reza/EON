-- Security: default-deny everywhere, the one-and-only God, audit chain, rate limiting.

------------------------------------------------------------------------------
-- Default deny: RLS enabled + forced on every table, no policies, no grants
------------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select schemaname, tablename from pg_tables
    where schemaname in ('sim', 'social', 'app', 'llm', 'secrets')
  loop
    execute format('alter table %I.%I enable row level security', r.schemaname, r.tablename);
    execute format('alter table %I.%I force row level security', r.schemaname, r.tablename);
    execute format('revoke all on %I.%I from public, anon, authenticated', r.schemaname, r.tablename);
  end loop;
end $$;

-- New tables created later in these schemas get RLS automatically.
create or replace function app.enforce_rls_on_new_tables() returns event_trigger
language plpgsql security definer set search_path = '' as $$
declare obj record;
begin
  for obj in select * from pg_event_trigger_ddl_commands() where command_tag = 'CREATE TABLE'
  loop
    if obj.schema_name in ('sim', 'social', 'app', 'llm', 'secrets') then
      execute format('alter table %s enable row level security', obj.object_identity);
      execute format('alter table %s force row level security', obj.object_identity);
    end if;
  end loop;
end $$;

drop event trigger if exists eon_enforce_rls;
create event trigger eon_enforce_rls on ddl_command_end
  when tag in ('CREATE TABLE') execute function app.enforce_rls_on_new_tables();

------------------------------------------------------------------------------
-- The one God. Exactly one row may ever exist, bound to one email hash.
------------------------------------------------------------------------------
create table app.god (
  one          boolean primary key default true check (one),
  user_id      uuid not null unique references auth.users on delete restrict,
  email_sha256 text not null check (email_sha256 = 'acb1ea974d4bb00df88786912bc80fabf1cc57a99acfd5f3b7d489ecb68f6e86'),
  claimed_at   timestamptz not null default now()
);
alter table app.god enable row level security;
alter table app.god force row level security;
revoke all on app.god from public, anon, authenticated;

create or replace function app.god_is_immutable() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'The God of EON cannot be changed or removed' using errcode = '42501';
end $$;

create trigger god_no_update before update or delete on app.god
  for each row execute function app.god_is_immutable();
create trigger god_no_truncate before truncate on app.god
  for each statement execute function app.god_is_immutable();

-- sha256 of the one God email (the plaintext address is never stored in the repo or database).
create or replace function app.god_email_sha256() returns text
language sql immutable set search_path = '' as $$
  select 'acb1ea974d4bb00df88786912bc80fabf1cc57a99acfd5f3b7d489ecb68f6e86'::text;
$$;

-- Claim God for the locked email once it is confirmed (insert or update on auth.users).
create or replace function app.claim_god_if_eligible() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email_confirmed_at is not null
     and encode(extensions.digest(lower(new.email), 'sha256'), 'hex') = app.god_email_sha256()
     and not exists (select 1 from app.god) then
    insert into app.god (user_id, email_sha256)
    values (new.id, encode(extensions.digest(lower(new.email), 'sha256'), 'hex'));
  end if;
  return new;
end $$;

create trigger eon_claim_god_ins after insert on auth.users
  for each row execute function app.claim_god_if_eligible();
create trigger eon_claim_god_upd after update of email_confirmed_at on auth.users
  for each row execute function app.claim_god_if_eligible();

-- God's auth user can never change email or be deleted.
create or replace function app.protect_god_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from app.god g where g.user_id = old.id) then
    if tg_op = 'DELETE' then
      raise exception 'The God account cannot be deleted' using errcode = '42501';
    end if;
    if new.email is distinct from old.email then
      raise exception 'The God account email cannot be changed' using errcode = '42501';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger eon_protect_god_upd before update of email on auth.users
  for each row execute function app.protect_god_user();
create trigger eon_protect_god_del before delete on auth.users
  for each row execute function app.protect_god_user();

-- Profiles are created for every new user (username sanitised from signup metadata).
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  base text;
  uname text;
  n int := 0;
begin
  base := lower(regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1)), '[^a-zA-Z0-9_]', '', 'g'));
  if char_length(base) < 3 then base := 'soul' || base; end if;
  base := left(base, 16);
  uname := base;
  while exists (select 1 from app.profiles p where p.username = uname) loop
    n := n + 1;
    uname := left(base, 16) || n::text;
  end loop;
  insert into app.profiles (user_id, username, country)
  values (new.id, uname, left(nullif(trim(new.raw_user_meta_data ->> 'country'), ''), 56));
  return new;
end $$;

create trigger eon_new_user after insert on auth.users
  for each row execute function app.handle_new_user();

------------------------------------------------------------------------------
-- Request context helpers
------------------------------------------------------------------------------
create or replace function app.is_god() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app.god g where g.user_id = auth.uid());
$$;

-- God powers require: the God account + AAL2 (TOTP verified) + TOTP verified within 12 hours.
create or replace function app.assert_god() returns void
language plpgsql stable security definer set search_path = '' as $$
declare
  jwt jsonb := auth.jwt();
  fresh boolean;
begin
  if not app.is_god() then
    raise exception 'Only God may do this' using errcode = '42501';
  end if;
  if coalesce(jwt ->> 'aal', '') <> 'aal2' then
    raise exception 'God must verify with the authenticator app (MFA) first' using errcode = '42501';
  end if;
  select exists (
    select 1 from jsonb_array_elements(coalesce(jwt -> 'amr', '[]'::jsonb)) e
    where e ->> 'method' = 'totp'
      and (e ->> 'timestamp')::bigint > extract(epoch from now())::bigint - 12 * 3600
  ) into fresh;
  if not fresh then
    raise exception 'MFA verification is older than 12 hours; verify again' using errcode = '42501';
  end if;
end $$;

------------------------------------------------------------------------------
-- Append-only, hash-chained audit log for every God / autopilot action
------------------------------------------------------------------------------
create or replace function app.god_actions_chain() returns trigger
language plpgsql security definer set search_path = '' as $$
declare prev text;
begin
  select a.hash into prev from app.god_actions a order by a.id desc limit 1;
  new.prev_hash := coalesce(prev, 'genesis');
  new.hash := encode(extensions.digest(
    new.prev_hash || '|' || new.actor || '|' || new.action || '|' || coalesce(new.target, '') || '|' ||
    new.params::text || '|' || new.tick::text || '|' || new.at::text, 'sha256'), 'hex');
  return new;
end $$;

create trigger god_actions_chain before insert on app.god_actions
  for each row execute function app.god_actions_chain();

create or replace function app.append_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'Audit log is append-only' using errcode = '42501';
end $$;

create trigger god_actions_append_only before update or delete on app.god_actions
  for each row execute function app.append_only();

create or replace function app.audit(p_actor text, p_action text, p_target text, p_params jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into app.god_actions (actor, action, target, params, tick, prev_hash, hash)
  values (p_actor, p_action, p_target, coalesce(p_params, '{}'), (select w.tick from sim.world w), '', '');
$$;

------------------------------------------------------------------------------
-- Rate limiting (fixed window) usable from any RPC
------------------------------------------------------------------------------
create or replace function app.hit(p_key text, p_max integer, p_window interval) returns void
language plpgsql security definer set search_path = '' as $$
declare
  ws timestamptz := to_timestamp(floor(extract(epoch from now()) / extract(epoch from p_window)) * extract(epoch from p_window));
  c integer;
begin
  insert into app.rate_limits as r (key, window_start, count) values (p_key, ws, 1)
  on conflict (key, window_start) do update set count = r.count + 1
  returning r.count into c;
  if c > p_max then
    raise exception 'Slow down — too many requests' using errcode = 'P0429';
  end if;
end $$;

revoke all on all functions in schema app from public, anon, authenticated;
