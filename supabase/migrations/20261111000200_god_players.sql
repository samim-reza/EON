-- The Creator sees every player and every person, and can act on each from one place: give more
-- free days, take a soul back, revoke a key, remove a player, and find anyone by name. Every act is
-- God-only (fresh MFA), rate-limited, and written to the audit chain.

-- When a soul is deleted (its account is gone), its person lives on as an ordinary life.
create or replace function app.on_soul_gone() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update sim.agents set soul_id = null, controller = case when controller = 'god' then 'god' else 'auto' end where soul_id = old.id;
  update sim.pregnancies set soul_id = null where soul_id = old.id;
  return old;
end $$;
drop trigger if exists eon_soul_gone on app.souls;
create trigger eon_soul_gone before delete on app.souls for each row execute function app.on_soul_gone();

-- Every player, newest first, with their life, their mind and their key.
create or replace function api.god_players() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare t integer := (select w.tick from sim.world w where w.id = 1);
begin
  perform app.assert_god();
  return (select coalesce(jsonb_agg(to_jsonb(q) order by q.joined desc), '[]') from (
    select u.id as "userId", p.username, u.created_at as joined, u.last_sign_in_at as "lastSeen",
           u.email_confirmed_at is not null as confirmed,
           o.id as soul, o.status, o.trial_until as "trialUntil", o.agent_id as agent,
           case when o.id is not null then app.soul_mind(o.id, t) end as mind,
           (select pe.name || ' ' || pe.surname from sim.people pe where pe.id = o.agent_id) as person,
           (select (coalesce(pe.death_tick, t) - pe.birth_tick) / 1440 from sim.people pe where pe.id = o.agent_id) as age,
           (select s.name from sim.people pe join sim.settlements s on s.id = pe.settlement_id where pe.id = o.agent_id) as place,
           (select k.provider || ' · ' || k.status from secrets.ai_keys k where k.user_id = u.id) as key,
           (select count(*) from app.souls x where x.user_id = u.id) as lives
    from auth.users u join app.profiles p on p.user_id = u.id
    left join lateral (select * from app.souls x where x.user_id = u.id order by x.id desc limit 1) o on true
    where not exists (select 1 from app.god g where g.user_id = u.id)
    order by u.created_at desc limit 200) q);
end $$;

-- More days of EON's own mind, counted from now or from when the current ones end.
create or replace function api.god_extend_free(p_soul bigint, p_days integer) returns void
language plpgsql security definer set search_path = '' as $$
declare t integer := (select w.tick from sim.world w where w.id = 1);
begin
  perform app.assert_god();
  perform app.hit('god:players', 120, interval '1 hour');
  if p_days is null or p_days not between 1 and 30 then raise exception 'Give 1 to 30 days'; end if;
  update app.souls set trial_until = greatest(coalesce(trial_until, t), t) + p_days * 1440 where id = p_soul and status = 'living';
  if not found then raise exception 'That soul is not living'; end if;
  perform app.audit('god', 'extend_free', p_soul::text, jsonb_build_object('days', p_days));
end $$;

-- Takes a soul out of its life. The person lives on by habit; the player may ask for another life later.
create or replace function api.god_take_soul(p_soul bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare t integer := (select w.tick from sim.world w where w.id = 1); o app.souls;
begin
  perform app.assert_god();
  perform app.hit('god:players', 120, interval '1 hour');
  select * into o from app.souls x where x.id = p_soul and x.status in ('waiting', 'assigned', 'living');
  if not found then raise exception 'That soul has no life to take back'; end if;
  update sim.agents set soul_id = null, controller = case when controller = 'god' then 'god' else 'auto' end where soul_id = o.id;
  update sim.pregnancies set soul_id = null where soul_id = o.id;
  update app.choices set status = 'void', settled_tick = t where soul_id = o.id and status in ('open', 'asked', 'chosen');
  update app.souls set status = 'ended', ended_tick = t, pregnancy_id = null where id = o.id;
  update sim.world set roster_version = roster_version + 1 where id = 1;
  perform app.audit('god', 'take_soul', p_soul::text, jsonb_build_object('agent', o.agent_id));
end $$;

create or replace function api.god_revoke_key(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.assert_god();
  perform app.hit('god:players', 120, interval '1 hour');
  delete from secrets.ai_keys where user_id = p_user;
  if not found then raise exception 'That player has no key'; end if;
  perform app.audit('god', 'revoke_key', p_user::text, '{}');
end $$;

-- Removes a player's account entirely. Their person, if any, lives on as an ordinary life.
create or replace function api.god_remove_player(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.assert_god();
  perform app.hit('god:players', 120, interval '1 hour');
  if exists (select 1 from app.god g where g.user_id = p_user) then raise exception 'The Creator cannot be removed'; end if;
  if not exists (select 1 from auth.users u where u.id = p_user) then raise exception 'No such player'; end if;
  perform app.audit('god', 'remove_player', p_user::text, jsonb_build_object('username', (select p.username from app.profiles p where p.user_id = p_user)));
  delete from auth.users where id = p_user;
end $$;

-- Anyone alive, by name or id. Players' people first.
create or replace function api.god_find(p_query text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  t integer := (select w.tick from sim.world w where w.id = 1);
  q text := replace(replace(trim(coalesce(p_query, '')), '%', ''), '_', '');
begin
  perform app.assert_god();
  if char_length(q) > 60 then raise exception 'Search for up to 60 characters'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from (
    select a.id, a.name || ' ' || a.surname as name, a.sex, (t - a.birth_tick) / 1440 as age, a.occupation as work,
           s.name as place, a.health, a.controller,
           (select p.username from app.souls o join app.profiles p on p.user_id = o.user_id where o.id = a.soul_id) as player
    from sim.agents a left join sim.settlements s on s.id = a.settlement_id
    where q = '' or (a.name || ' ' || a.surname) ilike '%' || q || '%' or a.id::text = q
    order by (a.soul_id is not null) desc, a.birth_tick
    limit 40) r);
end $$;

revoke all on function app.on_soul_gone() from public, anon, authenticated;
revoke all on function api.god_players(), api.god_extend_free(bigint, integer), api.god_take_soul(bigint), api.god_revoke_key(uuid),
                       api.god_remove_player(uuid), api.god_find(text) from public, anon, authenticated;
grant execute on function api.god_players(), api.god_extend_free(bigint, integer), api.god_take_soul(bigint), api.god_revoke_key(uuid),
                          api.god_remove_player(uuid), api.god_find(text) to authenticated;
