-- Hardening after a security review: sign-in gets a rate limit of its own, a username is taken
-- only once an address is confirmed, abandoned sign-ups are cleared away, a proof-of-work
-- solution works once, the public story queries get the indexes they were missing, and the AI
-- never sees words God spoke through someone in its news digest.

------------------------------------------------------------------------------
-- 1. Sign-in attempts are limited per network and per account. Supabase Auth only sees the
--    server's address, so without this one attacker could spend everyone's shared sign-in budget.
------------------------------------------------------------------------------
create or replace function api.login_gate(p_client text, p_email text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_client !~ '^[0-9a-f]{64}$' then
    raise exception 'Bad client key' using errcode = '22023';
  end if;
  perform app.hit('login:' || p_client, 20, interval '15 minutes');
  perform app.hit('login-acct:' || encode(extensions.digest(lower(trim(p_email)), 'sha256'), 'hex'), 10, interval '15 minutes');
end $$;

revoke all on function api.login_gate(text, text) from public, anon, authenticated;
grant execute on function api.login_gate(text, text) to service_role;

------------------------------------------------------------------------------
-- 2. A profile, and so a username, exists only for a confirmed address. A script calling the Auth
--    API directly can no longer reserve names it never confirms.
------------------------------------------------------------------------------
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  base text;
  uname text;
  n int := 0;
  is_god boolean := encode(extensions.digest(lower(new.email), 'sha256'), 'hex') = app.god_email_sha256();
begin
  if exists (select 1 from app.profiles p where p.user_id = new.id) then return new; end if;
  base := lower(regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1)), '[^a-zA-Z0-9_]', '', 'g'));
  if app.is_reserved_username(base) and not is_god then base := 'soul_' || base; end if;
  if char_length(base) < 3 then base := 'soul' || base; end if;
  base := left(base, 20);
  uname := base;
  while exists (select 1 from app.profiles p where p.username = uname) loop
    n := n + 1;
    uname := left(base, 20 - char_length(n::text)) || n::text;
  end loop;
  insert into app.profiles (user_id, username, country)
  values (new.id, uname, left(nullif(trim(new.raw_user_meta_data ->> 'country'), ''), 56));
  return new;
end $$;

drop trigger if exists eon_new_user on auth.users;
create trigger eon_new_user after insert on auth.users
  for each row when (new.email_confirmed_at is not null) execute function app.handle_new_user();
drop trigger if exists eon_confirmed_user on auth.users;
create trigger eon_confirmed_user after update of email_confirmed_at on auth.users
  for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null) execute function app.handle_new_user();

-- Sign-ups that were never confirmed are cleared after a day, so an address is not held hostage.
create or replace function app.purge_unconfirmed() returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer := 0;
begin
  begin
    with gone as (
      delete from auth.users u
       where u.email_confirmed_at is null and u.created_at < now() - interval '1 day'
         and not exists (select 1 from app.god g where g.user_id = u.id)
      returning 1)
    select count(*) into n from gone;
  exception when others then
    n := -1; -- a hosted database may not allow this; the world must not notice
  end;
  return n;
end $$;
revoke all on function app.purge_unconfirmed() from public, anon, authenticated;
select cron.schedule('eon-purge-unconfirmed', '41 * * * *', 'select app.purge_unconfirmed()');

------------------------------------------------------------------------------
-- 3. A proof-of-work solution can be used once. The salt is remembered for the challenge's lifetime.
------------------------------------------------------------------------------
drop function if exists api.signup_gate(text, text, text);
create or replace function api.signup_gate(p_client text, p_username text, p_email text, p_salt text default null) returns text
language plpgsql security definer set search_path = '' as $$
begin
  if p_client !~ '^[0-9a-f]{64}$' then
    raise exception 'Bad client key' using errcode = '22023';
  end if;
  perform app.hit('signup-check:' || p_client, 60, interval '1 hour');
  if p_username !~ '^[a-z0-9_]{3,20}$' then return 'invalid'; end if;
  if app.is_reserved_username(p_username) then return 'reserved'; end if;
  if exists (select 1 from app.profiles p where p.username = p_username) then return 'taken'; end if;
  if encode(extensions.digest(lower(trim(p_email)), 'sha256'), 'hex') = app.god_email_sha256() then return 'refused'; end if;
  if p_salt is not null then
    if p_salt !~ '^[0-9a-f]{24}$' then return 'invalid'; end if;
    begin
      perform app.hit('pow:' || p_salt, 1, interval '30 minutes');
    exception when sqlstate 'P0429' then
      return 'replayed';
    end;
  end if;
  perform app.hit('signup:' || p_client, 10, interval '1 hour');
  return 'ok';
end $$;

revoke all on function api.signup_gate(text, text, text, text) from public, anon, authenticated;
grant execute on function api.signup_gate(text, text, text, text) to service_role;

------------------------------------------------------------------------------
-- 4. The story and map queries get indexes, so a burst of page views cannot slow the world down.
------------------------------------------------------------------------------
create index if not exists events_agent_idx on sim.events (agent_id);
create index if not exists events_other_idx on sim.events (other_id);
create index if not exists agents_settlement_idx on sim.agents (settlement_id);

------------------------------------------------------------------------------
-- 5. Releasing a possessed agent is limited like every other power.
------------------------------------------------------------------------------
create or replace function api.god_release(p_agent bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.assert_god();
  perform app.hit('god:miracle', 60, interval '1 hour');
  update sim.agents set controller = 'auto', possessed_until = null where id = p_agent and controller = 'god';
  perform app.audit('god', 'release', p_agent::text, '{}');
end $$;

------------------------------------------------------------------------------
-- 6. The news digest never carries free text spoken through an agent.
------------------------------------------------------------------------------
create or replace function llm.facts(j llm.jobs) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  t integer := (select w.tick from sim.world w where w.id = 1);
  person jsonb; place jsonb; recent jsonb;
begin
  select jsonb_build_object('name', p.name || ' ' || p.surname, 'sex', p.sex, 'age', ((coalesce(p.death_tick, t) - p.birth_tick) / 1440),
                            'work', p.occupation, 'children', p.kids, 'alive', p.alive) into person
  from sim.people p where p.id = j.agent_id;
  select jsonb_build_object('name', s.name, 'kind', s.kind, 'land', s.biome, 'weather', s.wx_kind, 'people', s.pop) into place
  from sim.settlements s where s.id = coalesce(j.settlement_id, (select a.settlement_id from sim.agents a where a.id = j.agent_id));
  if j.kind = 'news' then
    select coalesce(jsonb_agg(e), '[]') into recent from (
      select v.kind, v.data - 'voice' - 'story' - 'said' as data,
             (select p.name || ' ' || p.surname from sim.people p where p.id = v.agent_id) as who,
             (select s.name from sim.settlements s where s.id = v.settlement_id) as place
      from sim.events v where v.tick >= j.tick - 480 and v.importance >= 1 and v.kind not in ('voice', 'spoke')
      order by v.importance desc, v.tick desc limit 8) e;
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'person', person,
    'other', (select p.name || ' ' || p.surname from sim.people p where p.id = j.other_id),
    'place', place,
    'happened', j.context,
    'recent', recent,
    'year', j.tick / 1440,
    'month', (j.tick / 120) % 12,
    'age', (select coalesce(max(d.age), 1) from sim.discoveries d where d.found_tick is not null),
    'known', (select coalesce(jsonb_agg(d.name order by d.found_tick), '[]') from sim.discoveries d where d.found_tick is not null)));
end $$;
