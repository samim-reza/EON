-- Prayers, souls and possession. Nothing here ever waits for God: the world answers prayers and
-- gives waiting souls a family on its own after six real hours, and possession wears off by itself.

alter table sim.agents add column possessed_until integer;
create unique index pregnancies_one_soul on sim.pregnancies (soul_id) where soul_id is not null;

create table app.prayers (
  id            bigserial primary key,
  tick          integer not null,
  agent_id      bigint not null,
  settlement_id integer,
  need          text not null check (need in ('health', 'food', 'child', 'safety')),
  status        text not null default 'open' check (status in ('open', 'granted', 'denied')),
  answered_tick integer,
  answered_by   text check (answered_by in ('god', 'autopilot'))
);
create index on app.prayers (tick) where status = 'open';
create index on app.prayers (agent_id) where status = 'open';

create table app.souls (
  id             bigserial primary key,
  user_id        uuid not null references auth.users on delete cascade,
  status         text not null default 'waiting' check (status in ('waiting', 'assigned', 'living', 'ended')),
  requested_tick integer not null,
  pregnancy_id   bigint,
  agent_id       bigint,
  assigned_by    text check (assigned_by in ('god', 'autopilot')),
  ended_tick     integer
);
create unique index souls_one_life on app.souls (user_id) where status in ('waiting', 'assigned', 'living');
create index on app.souls (requested_tick) where status = 'waiting';

create or replace function sim.p_births(p_tick integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  p jsonb := (select value from sim.params where key = 'demography');
  pg record; m sim.agents; f record;
  n integer := 0; k integer; nkids integer; child bigint; sx char; tr smallint[];
begin
  select * into w from sim.world where id = 1;
  for pg in select * from sim.pregnancies where outcome is null and due_tick <= p_tick order by id loop
    select * into m from sim.agents where id = pg.mother_id;
    if not found then
      update sim.pregnancies set outcome = 'lost' where id = pg.id;
      update app.souls set status = 'waiting', pregnancy_id = null, assigned_by = null where pregnancy_id = pg.id; -- back in the queue
      continue;
    end if;
    select id, surname, lineage, generation, trait_o, trait_c, trait_e, trait_a, trait_n, piety, honesty into f
      from sim.agents where id = pg.father_id;
    if not found then
      select d.id, d.surname, d.lineage, d.generation,
             50::smallint as trait_o, 50::smallint as trait_c, 50::smallint as trait_e, 50::smallint as trait_a,
             50::smallint as trait_n, 50::smallint as piety, 50::smallint as honesty
        into f from sim.dead d where d.id = pg.father_id;
    end if;
    nkids := case when sim.rnd(w.seed, 'twin', pg.id) < (p -> 'fertility' ->> 'twinChance')::float8 then 2 else 1 end;
    for k in 1 .. nkids loop
      sx := case when sim.rnd(w.seed, 'sex', pg.id, k) < w.female_ratio then 'F' else 'M' end;
      tr := array[
        sim.clamp100((m.trait_o + f.trait_o) / 2.0 + 12 * sim.rnorm(w.seed, 't1', pg.id, k)),
        sim.clamp100((m.trait_c + f.trait_c) / 2.0 + 12 * sim.rnorm(w.seed, 't2', pg.id, k)),
        sim.clamp100((m.trait_e + f.trait_e) / 2.0 + 12 * sim.rnorm(w.seed, 't3', pg.id, k)),
        sim.clamp100((m.trait_a + f.trait_a) / 2.0 + 12 * sim.rnorm(w.seed, 't4', pg.id, k)),
        sim.clamp100((m.trait_n + f.trait_n) / 2.0 + 12 * sim.rnorm(w.seed, 't5', pg.id, k)),
        sim.clamp100((m.piety + f.piety) / 2.0 + 12 * sim.rnorm(w.seed, 't6', pg.id, k)),
        sim.clamp100((m.honesty + f.honesty) / 2.0 + 12 * sim.rnorm(w.seed, 't7', pg.id, k))]::smallint[];
      child := sim.spawn_agent(
        p_tick, sim.make_name(sx, sim.rnd(w.seed, 'n1', pg.id, k), sim.rnd(w.seed, 'n2', pg.id, k)), f.surname, sx, p_tick,
        m.id, f.id, array[m.id, f.id] || m.lineage[1:2] || f.lineage[1:2],
        (greatest(m.generation, f.generation) + 1)::smallint, false, m.settlement_id, m.home_id, tr, 0);
      perform sim.log(p_tick, 'birth', 2::smallint, child, m.id, m.settlement_id,
                      jsonb_build_object('father', f.id, 'twins', nkids > 1));
      if k = 1 and pg.soul_id is not null then
        update sim.agents set soul_id = pg.soul_id, controller = 'soul' where id = child;
        update app.souls set status = 'living', agent_id = child where id = pg.soul_id;
        update sim.world set roster_version = roster_version + 1 where id = 1;
      end if;
      n := n + 1;
    end loop;
    update sim.pregnancies set outcome = 'born' where id = pg.id;
    update sim.agents ag set kids = ag.kids + nkids,
                          fertile_after_tick = case when ag.id = m.id then p_tick + (p -> 'fertility' ->> 'postpartumMonths')::int * 120 else ag.fertile_after_tick end,
                          happiness = least(100, ag.happiness + 10)
     where ag.id in (m.id, f.id);
  end loop;
  return n;
end $$;

create or replace function sim.kill(p_tick integer, p_id bigint, p_cause text) returns void
language plpgsql security definer set search_path = '' as $$
declare ag sim.agents;
begin
  delete from sim.agents where id = p_id returning * into ag;
  if not found then return; end if;
  insert into sim.dead (id, name, surname, sex, birth_tick, death_tick, cause, mother_id, father_id, lineage,
                        generation, is_founder, settlement_id, occupation, kids, soul_id, notable)
  values (ag.id, ag.name, ag.surname, ag.sex, ag.birth_tick, p_tick, p_cause, ag.mother_id, ag.father_id, ag.lineage,
          ag.generation, ag.is_founder, ag.settlement_id, ag.occupation, ag.kids, ag.soul_id,
          ag.is_founder or ag.soul_id is not null or ag.kids >= 8);
  if ag.partner_id is not null then
    update sim.unions set end_tick = p_tick, end_reason = 'death'
     where end_tick is null and (female_id = ag.id or male_id = ag.id);
    update sim.agents set partner_id = null, happiness = greatest(0, happiness - 25) where id = ag.partner_id;
  end if;
  update app.souls set status = 'waiting', pregnancy_id = null, assigned_by = null
   where pregnancy_id in (select g.id from sim.pregnancies g where g.mother_id = ag.id and g.outcome is null);
  update sim.pregnancies set outcome = 'lost', soul_id = null where mother_id = ag.id and outcome is null;
  update app.souls set status = 'ended', ended_tick = p_tick where agent_id = ag.id;
  delete from sim.infections where agent_id = ag.id;
  delete from sim.relationships where sim.relationships.a = p_id or sim.relationships.b = p_id;
  update sim.world set roster_version = roster_version + 1 where id = 1;
  perform sim.log(p_tick, 'death', (case when ag.is_founder or ag.soul_id is not null then 3 else 2 end)::smallint,
                  ag.id, ag.partner_id, ag.settlement_id,
                  jsonb_build_object('cause', p_cause, 'age', round(((p_tick - ag.birth_tick) / 1440.0)::numeric, 1),
                                     'name', ag.name || ' ' || ag.surname));
end $$;

-- What an answered prayer does. It eases a life; it never rewrites the fate drawn at birth.
create or replace function sim.answer_prayer(p_prayer bigint, p_grant boolean, p_by text, p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p app.prayers;
  a sim.agents;
begin
  update app.prayers set status = case when p_grant then 'granted' else 'denied' end, answered_tick = p_tick, answered_by = p_by
   where id = p_prayer and status = 'open' returning * into p;
  if not found or not p_grant then return; end if;
  select * into a from sim.agents where id = p.agent_id;
  if not found then return; end if;
  case p.need
    when 'health' then
      update sim.infections set until_tick = p_tick where agent_id = a.id and until_tick > p_tick;
      update sim.agents set health = least(100, health + 20) where id = a.id;
    when 'food' then
      update sim.settlements set food = least(1.4, food + 0.1) where id = a.settlement_id;
      update sim.agents set wealth = wealth + 50 where id = a.id;
    when 'child' then
      update sim.agents set fertile_after_tick = p_tick, desired_kids = greatest(desired_kids, 1) where id in (a.id, a.partner_id);
    else
      update sim.agents set happiness = least(100, happiness + 10) where id = a.id;
  end case;
  perform sim.log(p_tick, 'prayer_answered', 1::smallint, a.id, null, a.settlement_id, jsonb_build_object('need', p.need));
end $$;

-- People pray when something is wrong, and the devout pray sooner. Runs on each tick's bucket, so
-- everyone is considered once a month.
create or replace function sim.p_prayers(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  b smallint := (p_tick % 120)::smallint;
  r record;
begin
  select * into w from sim.world where id = 1;
  for r in
    select a.id, a.settlement_id,
      case
        when a.diagnosed is not null or exists (select 1 from sim.infections i where i.agent_id = a.id and i.until_tick > p_tick) then 'health'
        when s.food < 0.7 or a.wealth < 0 then 'food'
        when a.sex = 'F' and a.partner_id is not null and a.kids = 0 and p_tick - a.birth_tick between 20 * 1440 and 44 * 1440
             and not exists (select 1 from sim.pregnancies g where g.mother_id = a.id and g.outcome is null) then 'child'
        when s.wx_kind in ('blizzard', 'thunderstorm', 'sandstorm', 'downpour') then 'safety'
      end as need
    from sim.agents a join sim.settlements s on s.id = a.settlement_id
    where a.bucket = b and p_tick - a.birth_tick >= 7 * 1440
      and sim.rnd(w.seed, 'pray', a.id, p_tick) < a.piety / 200.0
      and not exists (select 1 from app.prayers p where p.agent_id = a.id and p.status = 'open')
  loop
    continue when r.need is null;
    insert into app.prayers (tick, agent_id, settlement_id, need) values (p_tick, r.id, r.settlement_id, r.need);
    perform sim.log(p_tick, 'prayer', 1::smallint, r.id, null, r.settlement_id, jsonb_build_object('need', r.need));
  end loop;

  -- A prayer left unanswered for six real hours is answered anyway: more often for the faithful.
  if w.autopilot then
    for r in
      select p.id, a.piety from app.prayers p left join sim.agents a on a.id = p.agent_id
      where p.status = 'open' and p.tick <= p_tick - 360 order by p.tick limit 50
    loop
      perform sim.answer_prayer(r.id, r.piety is not null and sim.rnd(w.seed, 'grant', r.id) < 0.2 + 0.5 * r.piety / 100.0, 'autopilot', p_tick);
    end loop;
  end if;
  delete from app.prayers where status <> 'open' and answered_tick < p_tick - 30 * 1440;
end $$;

-- Souls left waiting six real hours join the family whose baby is due soonest. Possession wears off.
create or replace function sim.p_souls(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; family bigint;
begin
  if (select w.autopilot from sim.world w where w.id = 1) then
    for r in select o.id from app.souls o where o.status = 'waiting' and o.requested_tick <= p_tick - 360 order by o.requested_tick, o.id limit 20 loop
      select g.id into family from sim.pregnancies g where g.outcome is null and g.soul_id is null order by g.due_tick limit 1;
      exit when family is null; -- nobody is expecting: the souls keep waiting for the next pregnancy
      update sim.pregnancies set soul_id = r.id where id = family;
      update app.souls set status = 'assigned', pregnancy_id = family, assigned_by = 'autopilot' where id = r.id;
    end loop;
  end if;
  update sim.agents set controller = 'auto', possessed_until = null where controller = 'god' and possessed_until <= p_tick;
end $$;

------------------------------------------------------------------------------
-- Players
------------------------------------------------------------------------------
create or replace function api.request_life() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t integer := (select w.tick from sim.world w where w.id = 1);
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
  insert into app.souls (user_id, requested_tick) values (uid, t);
  return api.my_soul();
end $$;

create or replace function api.my_soul() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('status', o.status, 'agent', o.agent_id,
    'dueTick', g.due_tick, 'mother', m.name || ' ' || m.surname, 'father', f.name || ' ' || f.surname, 'place', s.name,
    'name', (select p.name || ' ' || p.surname from sim.people p where p.id = o.agent_id))
  from app.souls o
  left join sim.pregnancies g on g.id = o.pregnancy_id
  left join sim.agents m on m.id = g.mother_id
  left join sim.agents f on f.id = g.father_id
  left join sim.settlements s on s.id = m.settlement_id
  where o.user_id = auth.uid() order by o.id desc limit 1;
$$;

------------------------------------------------------------------------------
-- God. All of these are optional: the world never waits for them.
------------------------------------------------------------------------------
create or replace function api.god_answer_prayer(p_prayer bigint, p_grant boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare t integer := (select w.tick from sim.world w where w.id = 1);
begin
  perform app.assert_god();
  perform app.hit('god:prayer', 240, interval '1 hour');
  if not exists (select 1 from app.prayers p where p.id = p_prayer and p.status = 'open') then raise exception 'That prayer has already been answered'; end if;
  perform sim.answer_prayer(p_prayer, p_grant, 'god', t);
  perform app.audit('god', 'answer_prayer', p_prayer::text, jsonb_build_object('grant', p_grant));
end $$;

create or replace function api.god_assign_soul(p_soul bigint, p_pregnancy bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.assert_god();
  perform app.hit('god:soul', 120, interval '1 hour');
  if not exists (select 1 from app.souls o where o.id = p_soul and o.status = 'waiting') then raise exception 'That soul is no longer waiting'; end if;
  if not exists (select 1 from sim.pregnancies g where g.id = p_pregnancy and g.outcome is null and g.soul_id is null) then
    raise exception 'That child already has a soul';
  end if;
  update sim.pregnancies set soul_id = p_soul where id = p_pregnancy;
  update app.souls set status = 'assigned', pregnancy_id = p_pregnancy, assigned_by = 'god' where id = p_soul;
  perform app.audit('god', 'assign_soul', p_soul::text, jsonb_build_object('pregnancy', p_pregnancy));
end $$;

-- Act through someone for one EON year. A life that belongs to a player is never taken over.
create or replace function api.god_possess(p_agent bigint, p_job text default null, p_say text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t integer := (select w.tick from sim.world w where w.id = 1);
  a sim.agents;
  words text := nullif(trim(coalesce(p_say, '')), '');
begin
  perform app.assert_god();
  perform app.hit('god:possess', 120, interval '1 hour');
  select * into a from sim.agents where id = p_agent;
  if not found then raise exception 'No living soul has that id'; end if;
  if a.soul_id is not null then raise exception 'That life belongs to a player'; end if;
  if p_job is not null and p_job not in ('farmer', 'builder', 'healer') then raise exception 'Unknown job'; end if;
  if p_job is not null and t - a.birth_tick < 16 * 1440 then raise exception 'They are too young to work'; end if;
  if char_length(coalesce(words, '')) > 200 then raise exception 'Keep it under 200 characters'; end if;
  update sim.agents set controller = 'god', possessed_until = t + 1440, occupation = coalesce(p_job, occupation) where id = p_agent;
  if p_job is not null then update sim.world set roster_version = roster_version + 1 where id = 1; end if;
  if words is not null then
    insert into social.posts (tick, agent_id, kind, body, source) values (t, p_agent, 'post', words, 'god');
    perform sim.log(t, 'spoke', 1::smallint, p_agent, null, a.settlement_id, jsonb_build_object('said', words));
  end if;
  perform app.audit('god', 'possess', p_agent::text, jsonb_build_object('job', p_job, 'said', words));
end $$;

create or replace function api.god_release(p_agent bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.assert_god();
  update sim.agents set controller = 'auto', possessed_until = null where id = p_agent and controller = 'god';
  perform app.audit('god', 'release', p_agent::text, '{}');
end $$;

revoke all on all functions in schema sim from public, anon, authenticated;
revoke all on function api.request_life(), api.my_soul(), api.god_answer_prayer(bigint, boolean), api.god_assign_soul(bigint, bigint),
                       api.god_possess(bigint, text, text), api.god_release(bigint) from public, anon, authenticated;
grant execute on function api.request_life(), api.my_soul(), api.god_answer_prayer(bigint, boolean), api.god_assign_soul(bigint, bigint),
                          api.god_possess(bigint, text, text), api.god_release(bigint) to authenticated;

create or replace function sim.step(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t0 timestamptz := clock_timestamp();
  nd integer; nb integer; ms integer;
begin
  perform sim.ensure_event_partitions(p_tick);
  nd := sim.p_deaths(p_tick);
  nb := sim.p_births(p_tick);
  perform sim.p_bucket(p_tick);
  perform sim.p_prayers(p_tick);
  if p_tick % 4 = 0 then
    perform sim.p_weather(p_tick);
    perform sim.p_daily(p_tick);
    perform sim.p_souls(p_tick);
  end if;
  if p_tick % 120 = 0 then perform sim.p_progress(p_tick); end if;
  if p_tick % 1440 = 0 then
    perform sim.p_annals(p_tick);
    perform sim.p_yearly(p_tick);
  end if;
  ms := (extract(epoch from clock_timestamp() - t0) * 1000)::int;
  insert into sim.world_stats (tick, population, births, deaths, pregnant, sick, avg_wealth, tick_ms)
  select p_tick, count(*), nb, nd,
         (select count(*) from sim.pregnancies where outcome is null),
         (select count(distinct agent_id) from sim.infections where until_tick > p_tick),
         coalesce(avg(wealth), 0)::int, ms
  from sim.agents
  on conflict (tick) do nothing;
  update sim.world set last_tick_ms = ms, updated_at = now() where id = 1;
end $$;

create or replace function api.god_state() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.assert_god();
  return (select jsonb_build_object(
    'world', to_jsonb(w) - 'seed' || jsonb_build_object('seed', w.seed::text),
    'population', (select count(*) from sim.agents),
    'dead', (select count(*) from sim.dead),
    'pregnant', (select count(*) from sim.pregnancies where outcome is null),
    'sick', (select count(distinct agent_id) from sim.infections where until_tick > w.tick),
    'settlements', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'kind', s.kind,
                      'pop', (select count(*) from sim.agents a where a.settlement_id = s.id)) order by s.id), '[]') from sim.settlements s),
    'sites', (select coalesce(jsonb_agg(f), '[]') from (
                select g.id, g.x, g.y, g.biome, g.river, g.coast from sim.sites g where not g.taken
                order by sim.habitability(g.biome, g.river, g.coast) desc, g.id limit 40) f),
    'prayers', (select coalesce(jsonb_agg(q), '[]') from (
                  select p.id, p.need, p.tick, a.name || ' ' || a.surname as agent, a.id as "agentId", s.name as place
                  from app.prayers p join sim.agents a on a.id = p.agent_id left join sim.settlements s on s.id = p.settlement_id
                  where p.status = 'open' order by p.tick limit 30) q),
    'souls', (select coalesce(jsonb_agg(q), '[]') from (
                  select o.id, o.requested_tick as tick, u.username from app.souls o join app.profiles u on u.user_id = o.user_id
                  where o.status = 'waiting' order by o.id limit 30) q),
    'families', (select coalesce(jsonb_agg(q), '[]') from (
                  select g.id, g.due_tick as due, m.name || ' ' || m.surname as mother, s.name as place
                  from sim.pregnancies g join sim.agents m on m.id = g.mother_id left join sim.settlements s on s.id = m.settlement_id
                  where g.outcome is null and g.soul_id is null order by g.due_tick limit 30) q),
    'possessed', (select coalesce(jsonb_agg(q), '[]') from (
                  select a.id, a.name || ' ' || a.surname as name, a.possessed_until as until from sim.agents a
                  where a.controller = 'god' order by a.id limit 30) q),
    'pyramid', (select coalesce(jsonb_agg(jsonb_build_object('band', band, 'F', f, 'M', m) order by band), '[]') from (
                  select least(((w.tick - a.birth_tick) / 1440) / 10, 10) * 10 as band,
                         count(*) filter (where a.sex = 'F') as f, count(*) filter (where a.sex = 'M') as m
                  from sim.agents a group by 1) pyr),
    'dbBytes', pg_database_size(current_database()),
    'audit', (select coalesce(jsonb_agg(to_jsonb(g) - 'prev_hash' order by g.id desc), '[]')
              from (select * from app.god_actions order by id desc limit 20) g))
    from sim.world w where w.id = 1);
end $$;
