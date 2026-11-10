-- A soul need not wait for a newborn. When a child under three has no soul yet, a new player
-- becomes that child at once, and the player's three free days start from that moment (the
-- eon_soul_born trigger sets them whenever a soul starts living). Otherwise the soul waits for
-- the next baby, as before. God can also give a waiting soul a young child by hand.

-- The youngest child under three who has no soul and is not being acted through.
create or replace function sim.unclaimed_child(p_tick integer) returns bigint
language sql stable security definer set search_path = '' as $$
  select a.id from sim.agents a
  where a.soul_id is null and a.controller = 'auto' and p_tick - a.birth_tick < 3 * 1440
  order by a.birth_tick desc, a.id limit 1;
$$;

-- Gives a waiting soul a child who is already alive.
create or replace function app.give_child(p_soul bigint, p_agent bigint, p_by text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from app.souls o where o.id = p_soul and o.status = 'waiting') then return false; end if;
  update sim.agents set soul_id = p_soul, controller = 'soul' where id = p_agent and soul_id is null and controller = 'auto';
  if not found then return false; end if;
  update app.souls set status = 'living', agent_id = p_agent, assigned_by = p_by, pregnancy_id = null where id = p_soul;
  update sim.world set roster_version = roster_version + 1 where id = 1;
  return true;
end $$;

create or replace function api.request_life() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t integer := (select w.tick from sim.world w where w.id = 1);
  sid bigint; child bigint;
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if app.is_god() then raise exception 'That is not for you' using errcode = '42501'; end if;
  perform app.hit('life:' || uid::text, 5, interval '1 hour');
  if (select w.genesis_at from sim.world w where w.id = 1) is null then raise exception 'The world has not begun'; end if;
  if exists (select 1 from app.souls s where s.user_id = uid and s.status in ('waiting', 'assigned', 'living')) then
    raise exception 'You already have a life, or are waiting for one';
  end if;
  if exists (select 1 from app.souls s where s.user_id = uid and s.status = 'ended' and s.ended_tick > t - 60) then
    raise exception 'Rest a while: you can ask again an hour after a life ends';
  end if;
  if exists (select 1 from app.souls s where s.user_id = uid and s.trial_until is not null)
     and not exists (select 1 from secrets.ai_keys k where k.user_id = uid and k.status <> 'invalid') then
    raise exception 'Your free days are used: connect your own AI to ask for another life';
  end if;
  insert into app.souls (user_id, requested_tick) values (uid, t) returning id into sid;
  -- A young child who has no soul yet is given one at once; otherwise the soul waits for the next baby.
  if (select w.autopilot from sim.world w where w.id = 1) then
    child := sim.unclaimed_child(t);
    if child is not null then perform app.give_child(sid, child, 'autopilot'); end if;
  end if;
  return api.my_soul();
end $$;

create or replace function sim.p_souls(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; family bigint; child bigint;
begin
  if (select w.autopilot from sim.world w where w.id = 1) then
    -- A young child with no soul takes a waiting soul at once.
    for r in select o.id from app.souls o where o.status = 'waiting' order by o.requested_tick, o.id limit 20 loop
      child := sim.unclaimed_child(p_tick);
      exit when child is null;
      perform app.give_child(r.id, child, 'autopilot');
    end loop;
    -- Otherwise, after six hours, the baby due soonest.
    for r in select o.id from app.souls o where o.status = 'waiting' and o.requested_tick <= p_tick - 360 order by o.requested_tick, o.id limit 20 loop
      select g.id into family from sim.pregnancies g where g.outcome is null and g.soul_id is null order by g.due_tick limit 1;
      exit when family is null; -- nobody is expecting: the souls keep waiting for the next pregnancy
      update sim.pregnancies set soul_id = r.id where id = family;
      update app.souls set status = 'assigned', pregnancy_id = family, assigned_by = 'autopilot' where id = r.id;
    end loop;
  end if;
  -- Possession wears off. A life that has a soul goes back to its soul.
  update sim.agents set controller = case when soul_id is null then 'auto' else 'soul' end, possessed_until = null
   where controller = 'god' and possessed_until <= p_tick;

  -- Every living soul with a mind thinks a thought about twice a real day.
  insert into llm.jobs (kind, priority, tick, agent_id, soul_id)
  select 'mind_day', 7, p_tick, o.agent_id, o.id from app.souls o
  where o.status = 'living' and app.soul_mind(o.id, p_tick) <> 'none'
    and not exists (select 1 from llm.jobs j where j.soul_id = o.id and j.kind = 'mind_day' and j.tick > p_tick - 720);

  -- The free days are over and there is no key: the player hears about it once.
  insert into app.outbox (user_id, soul_id, kind)
  select o.user_id, o.id, 'trial_over' from app.souls o
  where o.status = 'living' and o.trial_until is not null and o.trial_until <= p_tick and o.trial_until > p_tick - 60
    and not exists (select 1 from secrets.ai_keys k where k.user_id = o.user_id and k.status <> 'invalid')
  on conflict do nothing;

  if p_tick % 1440 = 0 then
    delete from app.choices where status in ('settled', 'void') and settled_tick < p_tick - 30 * 1440;
    delete from app.thoughts where tick < p_tick - 60 * 1440;
    delete from app.outbox where status in ('sent', 'failed') and created_at < now() - interval '30 days';
  end if;
end $$;

-- God may give a waiting soul a young child by hand.
create or replace function api.god_give_child(p_soul bigint, p_agent bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare t integer := (select w.tick from sim.world w where w.id = 1);
begin
  perform app.assert_god();
  perform app.hit('god:soul', 120, interval '1 hour');
  if not exists (select 1 from sim.agents a where a.id = p_agent and a.soul_id is null and a.controller = 'auto' and t - a.birth_tick < 3 * 1440) then
    raise exception 'That child is not free to take a soul';
  end if;
  if not app.give_child(p_soul, p_agent, 'god') then raise exception 'That soul is no longer waiting'; end if;
  perform app.audit('god', 'give_child', p_soul::text, jsonb_build_object('agent', p_agent));
end $$;

-- Young children who could take a soul, for the God console.
create or replace function api.god_children() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare t integer := (select w.tick from sim.world w where w.id = 1);
begin
  perform app.assert_god();
  return (select coalesce(jsonb_agg(q), '[]') from (
    select a.id, a.name || ' ' || a.surname as name, (t - a.birth_tick) / 120 as months, s.name as place
    from sim.agents a left join sim.settlements s on s.id = a.settlement_id
    where a.soul_id is null and a.controller = 'auto' and t - a.birth_tick < 3 * 1440
    order by a.birth_tick desc limit 30) q);
end $$;

-- The welcome email says whether the person was just born or is a young child already.
create or replace function api.outbox_claim(p_limit integer default 10) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; batch jsonb := '[]';
begin
  update app.outbox set status = 'queued', claimed_at = null where status = 'sending' and claimed_at < now() - interval '10 minutes';
  for r in select x.* from app.outbox x where x.status = 'queued' order by x.id limit least(greatest(p_limit, 1), 20) for update skip locked loop
    update app.outbox set status = 'sending', claimed_at = now(), tries = tries + 1 where id = r.id;
    batch := batch || jsonb_strip_nulls(jsonb_build_object('id', r.id, 'kind', r.kind,
      'email', (select u.email from auth.users u where u.id = r.user_id and u.email_confirmed_at is not null),
      'username', (select p.username from app.profiles p where p.user_id = r.user_id),
      'name', (select pe.name || ' ' || pe.surname from app.souls o join sim.people pe on pe.id = o.agent_id where o.id = r.soul_id),
      'mother', (select m.name || ' ' || m.surname from app.souls o join sim.people pe on pe.id = o.agent_id join sim.people m on m.id = pe.mother_id where o.id = r.soul_id),
      'father', (select f.name || ' ' || f.surname from app.souls o join sim.people pe on pe.id = o.agent_id join sim.people f on f.id = pe.father_id where o.id = r.soul_id),
      'place', (select s.name from app.souls o join sim.people pe on pe.id = o.agent_id join sim.settlements s on s.id = pe.settlement_id where o.id = r.soul_id),
      'ageTicks', (select o.born_tick - pe.birth_tick from app.souls o join sim.people pe on pe.id = o.agent_id where o.id = r.soul_id)));
  end loop;
  return batch;
end $$;

revoke all on function sim.unclaimed_child(integer), app.give_child(bigint, bigint, text) from public, anon, authenticated;
revoke all on function api.request_life(), api.god_give_child(bigint, bigint), api.god_children(), api.outbox_claim(integer)
  from public, anon, authenticated;
grant execute on function api.request_life(), api.god_give_child(bigint, bigint), api.god_children() to authenticated;
grant execute on function api.outbox_claim(integer) to service_role;
