-- A soul should never wait days for a body. When souls are waiting and no young child is free, a
-- new family arrives at a village with their newborn, and the waiting soul becomes that baby at
-- once. At most 20 families arrive in a real day, so the world keeps its balance; beyond that,
-- souls wait for the next baby as before.

create or replace function sim.arrivals_today(p_tick integer) returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::int from sim.events e where e.kind = 'family_arrives' and e.tick > p_tick - 1440;
$$;

-- A young couple arrives at the smallest village with their newborn. Returns the baby.
create or replace function sim.arriving_family(p_tick integer, p_key bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  p jsonb := (select value from sim.params where key = 'demography');
  amin double precision := (p -> 'genesis' ->> 'founderAgeMin')::float8;
  aspan double precision := (p -> 'genesis' ->> 'founderAgeMax')::float8 - amin;
  k bigint := p_key * 7919 + p_tick;
  st integer; sname text; f bigint; m bigint; baby bigint; mom sim.agents; dad sim.agents; sx char;
begin
  select * into w from sim.world where id = 1;
  if sim.arrivals_today(p_tick) >= 20 then return null; end if;
  select s.id into st from sim.settlements s
   order by (select count(*) from sim.agents a where a.settlement_id = s.id), s.id limit 1;
  if st is null then return null; end if;
  sname := sim.make_surname(sim.rnd(w.seed, 'asur', k));
  f := sim.spawn_agent(p_tick, sim.make_name('F', sim.rnd(w.seed, 'afn1', k), sim.rnd(w.seed, 'afn2', k)),
                       sim.make_surname(sim.rnd(w.seed, 'asurf', k)), 'F',
                       p_tick - ((amin + aspan * sim.rnd(w.seed, 'afage', k)) * 1440)::int,
                       null, null, '{}', 0::smallint, false, st, null, sim.random_traits(k * 2), 150);
  m := sim.spawn_agent(p_tick, sim.make_name('M', sim.rnd(w.seed, 'amn1', k), sim.rnd(w.seed, 'amn2', k)),
                       sname, 'M',
                       p_tick - ((amin + aspan * sim.rnd(w.seed, 'amage', k)) * 1440)::int,
                       null, null, '{}', 0::smallint, false, st, null, sim.random_traits(k * 2 + 1), 150);
  perform sim.unite(p_tick, f, m);
  select * into mom from sim.agents x where x.id = f;
  select * into dad from sim.agents x where x.id = m;
  sx := case when sim.rnd(w.seed, 'asex', k) < w.female_ratio then 'F' else 'M' end;
  baby := sim.spawn_agent(p_tick, sim.make_name(sx, sim.rnd(w.seed, 'abn1', k), sim.rnd(w.seed, 'abn2', k)), sname, sx, p_tick,
    f, m, array[f, m], 1::smallint, false, st, mom.home_id,
    array[
      sim.clamp100((mom.trait_o + dad.trait_o) / 2.0 + 12 * sim.rnorm(w.seed, 'at1', k)),
      sim.clamp100((mom.trait_c + dad.trait_c) / 2.0 + 12 * sim.rnorm(w.seed, 'at2', k)),
      sim.clamp100((mom.trait_e + dad.trait_e) / 2.0 + 12 * sim.rnorm(w.seed, 'at3', k)),
      sim.clamp100((mom.trait_a + dad.trait_a) / 2.0 + 12 * sim.rnorm(w.seed, 'at4', k)),
      sim.clamp100((mom.trait_n + dad.trait_n) / 2.0 + 12 * sim.rnorm(w.seed, 'at5', k)),
      sim.clamp100((mom.piety + dad.piety) / 2.0 + 12 * sim.rnorm(w.seed, 'at6', k)),
      sim.clamp100((mom.honesty + dad.honesty) / 2.0 + 12 * sim.rnorm(w.seed, 'at7', k))]::smallint[], 0);
  update sim.agents set kids = kids + 1,
         fertile_after_tick = case when id = f then p_tick + (p -> 'fertility' ->> 'postpartumMonths')::int * 120 else fertile_after_tick end
   where id in (f, m);
  perform sim.log(p_tick, 'family_arrives', 2::smallint, f, m, st, jsonb_build_object('child', baby));
  return baby;
end $$;

-- Gives a waiting soul a young child if one is free, or else a newborn in a family that has just arrived.
create or replace function app.find_body(p_soul bigint, p_tick integer) returns boolean
language plpgsql security definer set search_path = '' as $$
declare child bigint;
begin
  child := sim.unclaimed_child(p_tick);
  if child is null then child := sim.arriving_family(p_tick, p_soul); end if;
  if child is null then return false; end if;
  return app.give_child(p_soul, child, 'autopilot');
end $$;

create or replace function api.request_life() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t integer := (select w.tick from sim.world w where w.id = 1);
  sid bigint;
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
  if (select w.autopilot from sim.world w where w.id = 1) then perform app.find_body(sid, t); end if;
  return api.my_soul();
end $$;

create or replace function sim.p_souls(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; family bigint;
begin
  if (select w.autopilot from sim.world w where w.id = 1) then
    -- A young child with no soul, or a family just arrived, takes a waiting soul at once.
    for r in select o.id from app.souls o where o.status = 'waiting' order by o.requested_tick, o.id limit 20 loop
      exit when not app.find_body(r.id, p_tick);
    end loop;
    -- Otherwise, after six hours, the baby due soonest.
    for r in select o.id from app.souls o where o.status = 'waiting' and o.requested_tick <= p_tick - 360 order by o.requested_tick, o.id limit 20 loop
      select g.id into family from sim.pregnancies g where g.outcome is null and g.soul_id is null order by g.due_tick limit 1;
      exit when family is null;
      update sim.pregnancies set soul_id = r.id where id = family;
      update app.souls set status = 'assigned', pregnancy_id = family, assigned_by = 'autopilot' where id = r.id;
    end loop;
  end if;
  update sim.agents set controller = case when soul_id is null then 'auto' else 'soul' end, possessed_until = null
   where controller = 'god' and possessed_until <= p_tick;

  insert into llm.jobs (kind, priority, tick, agent_id, soul_id)
  select 'mind_day', 7, p_tick, o.agent_id, o.id from app.souls o
  where o.status = 'living' and app.soul_mind(o.id, p_tick) <> 'none'
    and not exists (select 1 from llm.jobs j where j.soul_id = o.id and j.kind = 'mind_day' and j.tick > p_tick - 720);

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

revoke all on function sim.arrivals_today(integer), sim.arriving_family(integer, bigint), app.find_body(bigint, integer) from public, anon, authenticated;
revoke all on function api.request_life() from public, anon;
grant execute on function api.request_life() to authenticated;
