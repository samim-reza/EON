-- api: the only schema exposed through the Data API. Functions only, no tables.
--   * api.pub_*   → public world data. Executable by service_role only (Vercel server reads, CDN caches).
--   * api.god_*   → God powers. Executable by authenticated; each call asserts God + fresh TOTP MFA.
--   * api.whoami  → current account summary.

create or replace view sim.people as
  select id, name, surname, sex, birth_tick, null::integer as death_tick, null::text as cause, mother_id, father_id,
         generation, is_founder, settlement_id, occupation, kids, soul_id, true as alive
  from sim.agents
  union all
  select id, name, surname, sex, birth_tick, death_tick, cause, mother_id, father_id,
         generation, is_founder, settlement_id, occupation, kids, soul_id, false as alive
  from sim.dead;
revoke all on sim.people from public, anon, authenticated;

------------------------------------------------------------------------------
-- Account
------------------------------------------------------------------------------
create or replace function api.whoami() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'user_id', auth.uid(),
    'username', (select p.username from app.profiles p where p.user_id = auth.uid()),
    'is_god', app.is_god(),
    'aal', auth.jwt() ->> 'aal')
  end;
$$;

------------------------------------------------------------------------------
-- Public read API (service_role only)
------------------------------------------------------------------------------
create or replace function api.pub_now() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'tick', w.tick,
    'paused', w.paused,
    'genesis', w.genesis_at is not null,
    'seed', w.seed::text,
    'rosterVersion', w.roster_version,
    'year', w.tick / 1440,
    'dayOfYear', (w.tick % 1440) / 4,
    'month', (w.tick / 120) % 12,
    'phase', w.tick % 4,
    'genesisEra', w.tick < w.genesis_end_tick,
    'lastTickMs', w.last_tick_ms,
    'stats', (select to_jsonb(s) - 'tick_ms' from sim.world_stats s order by s.tick desc limit 1),
    'settlements', (select count(*) from sim.settlements)
  ) from sim.world w;
$$;

-- Events (importance ≥ 1) in [from, to), plus stats rows: the content of one immutable bundle.
create or replace function api.pub_events(p_from integer, p_to integer) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id, 'tick', e.tick, 'kind', e.kind, 'imp', e.importance, 'agent', e.agent_id, 'other', e.other_id,
        'settlement', e.settlement_id, 'data', e.data,
        'agentName', (select p.name || ' ' || p.surname from sim.people p where p.id = e.agent_id),
        'otherName', (select p.name || ' ' || p.surname from sim.people p where p.id = e.other_id)
      ) order by e.tick, e.id)
      from sim.events e
      where e.tick >= p_from and e.tick < p_to and e.importance >= 1), '[]'::jsonb),
    'stats', coalesce((
      select jsonb_agg(to_jsonb(s) - 'tick_ms' order by s.tick)
      from sim.world_stats s where s.tick >= p_from and s.tick < p_to), '[]'::jsonb));
$$;

-- Newest-first feed with keyset pagination.
create or replace function api.pub_feed(p_before_tick integer default null, p_limit integer default 50,
                                        p_min_importance smallint default 2) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'tick')::int desc, (x ->> 'id')::bigint desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', e.id, 'tick', e.tick, 'kind', e.kind, 'imp', e.importance, 'agent', e.agent_id, 'other', e.other_id,
      'settlement', e.settlement_id, 'data', e.data,
      'agentName', (select p.name || ' ' || p.surname from sim.people p where p.id = e.agent_id),
      'otherName', (select p.name || ' ' || p.surname from sim.people p where p.id = e.other_id),
      'settlementName', (select s.name from sim.settlements s where s.id = e.settlement_id)) as x
    from sim.events e
    where (p_before_tick is null or e.tick < p_before_tick)
      and e.importance >= greatest(p_min_importance, 1)
    order by e.tick desc, e.id desc
    limit least(greatest(p_limit, 1), 100)
  ) q;
$$;

-- Living population in compact columnar form (positions are derived client-side).
create or replace function api.pub_roster() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'version', (select roster_version from sim.world),
    'tick', (select tick from sim.world),
    'id', coalesce(jsonb_agg(a.id order by a.id), '[]'),
    'name', coalesce(jsonb_agg(a.name || ' ' || a.surname order by a.id), '[]'),
    'sex', coalesce(jsonb_agg(a.sex order by a.id), '[]'),
    'birth', coalesce(jsonb_agg(a.birth_tick order by a.id), '[]'),
    'settlement', coalesce(jsonb_agg(a.settlement_id order by a.id), '[]'),
    'home', coalesce(jsonb_agg(a.home_id order by a.id), '[]'),
    'job', coalesce(jsonb_agg(a.occupation order by a.id), '[]'),
    'partner', coalesce(jsonb_agg(a.partner_id order by a.id), '[]'),
    'flags', coalesce(jsonb_agg(
        (case when a.soul_id is not null then 1 else 0 end)
      | (case when a.is_founder then 2 else 0 end)
      | (case when exists (select 1 from sim.pregnancies g where g.mother_id = a.id and g.outcome is null) then 4 else 0 end)
      | (case when exists (select 1 from sim.infections i where i.agent_id = a.id and i.until_tick > (select tick from sim.world)) then 8 else 0 end)
      order by a.id), '[]'))
  from sim.agents a;
$$;

create or replace function api.pub_geo() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'seed', (select seed::text from sim.world),
    'settlements', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'kind', s.kind, 'x', s.x, 'y', s.y, 'region', s.region, 'founded', s.founded_tick,
        'pop', (select count(*) from sim.agents a where a.settlement_id = s.id)) order by s.id)
      from sim.settlements s), '[]'),
    'buildings', coalesce((select jsonb_agg(jsonb_build_array(b.id, b.settlement_id, b.kind, round(b.x::numeric, 1), round(b.y::numeric, 1)) order by b.id)
      from sim.buildings b), '[]'));
$$;

create or replace function api.pub_agent(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  t integer := (select tick from sim.world);
  res jsonb;
begin
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'surname', p.surname, 'sex', p.sex, 'alive', p.alive,
    'birthTick', p.birth_tick, 'deathTick', p.death_tick, 'cause', p.cause,
    'age', round((((coalesce(p.death_tick, t)) - p.birth_tick) / 1440.0)::numeric, 1),
    'generation', p.generation, 'founder', p.is_founder, 'occupation', p.occupation, 'kids', p.kids,
    'isPlayer', p.soul_id is not null,
    'settlement', (select jsonb_build_object('id', s.id, 'name', s.name, 'kind', s.kind) from sim.settlements s where s.id = p.settlement_id),
    'mother', (select jsonb_build_object('id', m.id, 'name', m.name || ' ' || m.surname, 'alive', m.alive) from sim.people m where m.id = p.mother_id),
    'father', (select jsonb_build_object('id', f.id, 'name', f.name || ' ' || f.surname, 'alive', f.alive) from sim.people f where f.id = p.father_id)
  ) into res
  from sim.people p where p.id = p_id;
  if res is null then return null; end if;

  if (res ->> 'alive')::boolean then
    res := res || (select jsonb_build_object(
      'partner', (select jsonb_build_object('id', q.id, 'name', q.name || ' ' || q.surname) from sim.agents q where q.id = a.partner_id),
      'traits', jsonb_build_object('openness', a.trait_o, 'conscientiousness', a.trait_c, 'extraversion', a.trait_e,
                                   'agreeableness', a.trait_a, 'neuroticism', a.trait_n, 'piety', a.piety, 'honesty', a.honesty),
      'health', a.health, 'happiness', a.happiness, 'wealth', a.wealth, 'education', a.education, 'reputation', a.reputation,
      'diagnosed', a.diagnosed, 'homeId', a.home_id,
      'pregnant', exists (select 1 from sim.pregnancies g where g.mother_id = a.id and g.outcome is null),
      'sick', coalesce((select jsonb_agg(d.name) from sim.infections i join sim.diseases d on d.id = i.disease_id where i.agent_id = a.id and i.until_tick > t), '[]'))
      from sim.agents a where a.id = p_id);
  end if;

  res := res || jsonb_build_object(
    'children', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name || ' ' || c.surname, 'alive', c.alive, 'birthTick', c.birth_tick) order by c.birth_tick)
                          from sim.people c where c.mother_id = p_id or c.father_id = p_id), '[]'),
    'story', coalesce((select jsonb_agg(x order by (x ->> 'tick')::int) from (
        select jsonb_build_object('tick', e.tick, 'kind', e.kind, 'agent', e.agent_id, 'other', e.other_id,
                                  'agentName', (select o.name || ' ' || o.surname from sim.people o where o.id = e.agent_id),
                                  'otherName', (select o.name || ' ' || o.surname from sim.people o where o.id = e.other_id),
                                  'data', e.data) as x
        from sim.events e where (e.agent_id = p_id or e.other_id = p_id) and e.importance >= 1
        union
        select jsonb_build_object('tick', c.tick, 'kind', c.kind, 'agent', c.agent_id, 'other', c.other_id,
                                  'agentName', (select o.name || ' ' || o.surname from sim.people o where o.id = c.agent_id),
                                  'otherName', (select o.name || ' ' || o.surname from sim.people o where o.id = c.other_id),
                                  'data', c.data)
        from sim.chronicle c where c.agent_id = p_id or c.other_id = p_id
        order by 1 limit 200) s), '[]'));
  return res;
end $$;

-- Family tree: ancestors (3 generations up) and descendants (2 down).
create or replace function api.pub_family(p_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  with recursive up as (
    select p.id, p.mother_id, p.father_id, 0 as depth from sim.people p where p.id = p_id
    union
    select q.id, q.mother_id, q.father_id, up.depth + 1
    from up join sim.people q on q.id in (up.mother_id, up.father_id) where up.depth < 3
  ), down as (
    select p.id, 0 as depth from sim.people p where p.id = p_id
    union
    select c.id, down.depth + 1 from down join sim.people c on (c.mother_id = down.id or c.father_id = down.id) where down.depth < 2
  ), ids as (
    select id, -depth as gen from up union select id, depth from down
  )
  select jsonb_build_object('root', p_id, 'people', coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'name', p.name || ' ' || p.surname, 'sex', p.sex, 'alive', p.alive, 'mother', p.mother_id, 'father', p.father_id,
    'birthTick', p.birth_tick, 'deathTick', p.death_tick, 'gen', i.gen) order by i.gen, p.birth_tick), '[]'))
  from (select id, min(gen) as gen from ids group by id) i join sim.people p on p.id = i.id;
$$;

create or replace function api.pub_stats(p_from integer, p_to integer, p_step integer default 120) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(s) - 'tick_ms' order by s.tick), '[]'::jsonb)
  from sim.world_stats s
  where s.tick >= p_from and s.tick < p_to and s.tick % greatest(p_step, 1) = 0;
$$;

create or replace function api.pub_chronicle(p_limit integer default 100) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'tick')::int desc), '[]'::jsonb) from (
    select jsonb_build_object('id', c.id, 'tick', c.tick, 'kind', c.kind, 'agent', c.agent_id, 'other', c.other_id,
      'agentName', (select p.name || ' ' || p.surname from sim.people p where p.id = c.agent_id),
      'otherName', (select p.name || ' ' || p.surname from sim.people p where p.id = c.other_id),
      'settlementName', (select s.name from sim.settlements s where s.id = c.settlement_id),
      'data', c.data) as x
    from sim.chronicle c order by c.tick desc limit least(greatest(p_limit, 1), 500)) q;
$$;

------------------------------------------------------------------------------
-- God powers (authenticated + assert_god → God account, AAL2, TOTP < 12 h)
------------------------------------------------------------------------------
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
    'pyramid', (select coalesce(jsonb_agg(jsonb_build_object('band', band, 'F', f, 'M', m) order by band), '[]') from (
                  select least(((w.tick - a.birth_tick) / 1440) / 10, 10) * 10 as band,
                         count(*) filter (where a.sex = 'F') as f, count(*) filter (where a.sex = 'M') as m
                  from sim.agents a group by 1) pyr),
    'dbBytes', pg_database_size(current_database()),
    'audit', (select coalesce(jsonb_agg(to_jsonb(g) - 'prev_hash' order by g.id desc), '[]')
              from (select * from app.god_actions order by id desc limit 20) g))
    from sim.world w where w.id = 1);
end $$;

-- Genesis: create the world from a seed, its candidate sites, the first village and the first two souls.
create or replace function api.god_genesis(p_seed bigint, p_sites jsonb, p_village text,
                                           p_eve_name text, p_adam_name text, p_surname_f text, p_surname_m text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  st integer; eve bigint; adam bigint; first_site integer;
begin
  perform app.assert_god();
  if exists (select 1 from sim.agents) or exists (select 1 from sim.dead) or (select genesis_at from sim.world) is not null then
    raise exception 'Genesis has already happened';
  end if;
  if jsonb_typeof(p_sites) <> 'array' or jsonb_array_length(p_sites) < 10 or jsonb_array_length(p_sites) > 2000 then
    raise exception 'invalid sites';
  end if;
  if coalesce(char_length(p_village), 0) not between 2 and 24 or coalesce(char_length(p_eve_name), 0) not between 2 and 16
     or coalesce(char_length(p_adam_name), 0) not between 2 and 16 or coalesce(char_length(p_surname_f), 0) not between 2 and 16
     or coalesce(char_length(p_surname_m), 0) not between 2 and 16 then
    raise exception 'names must be 2–16 characters (village 2–24)';
  end if;

  update sim.world set seed = p_seed, tick = 0, paused = false, genesis_at = now(), tick_started_at = '-infinity' where id = 1;
  insert into sim.sites (id, x, y, region)
  select (e ->> 0)::int, (e ->> 1)::real, (e ->> 2)::real, (e ->> 3)::smallint
  from jsonb_array_elements(p_sites) e;
  first_site := (p_sites -> 0 ->> 0)::int;

  perform sim.rebuild_life_table();
  perform sim.ensure_event_partitions(0);
  st := sim.found_settlement(0, first_site, p_village);
  eve := sim.spawn_agent(0, p_eve_name, p_surname_f, 'F', -20 * 1440, null, null, '{}', 0::smallint, true, st, null,
                         sim.random_traits(1), 300);
  adam := sim.spawn_agent(0, p_adam_name, p_surname_m, 'M', -21 * 1440, null, null, '{}', 0::smallint, true, st, null,
                          sim.random_traits(2), 300);
  perform sim.log(0, 'genesis', 3::smallint, eve, adam, st, jsonb_build_object('village', p_village));
  perform app.audit('god', 'genesis', st::text, jsonb_build_object('seed', p_seed::text, 'eve', eve, 'adam', adam));
  return jsonb_build_object('settlement', st, 'eve', eve, 'adam', adam);
end $$;

create or replace function api.god_create_founder(p_name text, p_surname text, p_sex text, p_age integer, p_settlement integer)
returns bigint language plpgsql security definer set search_path = '' as $$
declare t integer := (select tick from sim.world); aid bigint;
begin
  perform app.assert_god();
  perform app.hit('god:founder', 30, interval '1 hour');
  if p_sex not in ('F', 'M') or p_age not between 16 and 60 or char_length(coalesce(p_name, '')) not between 2 and 16
     or char_length(coalesce(p_surname, '')) not between 2 and 16 then
    raise exception 'invalid founder';
  end if;
  if not exists (select 1 from sim.settlements where id = p_settlement) then raise exception 'unknown settlement'; end if;
  aid := sim.spawn_agent(t, p_name, p_surname, p_sex::char, t - p_age * 1440, null, null, '{}', 0::smallint, true,
                         p_settlement, null, sim.random_traits(t * 7 + p_settlement), 200);
  perform sim.log(t, 'founder_created', 3::smallint, aid, null, p_settlement, '{}');
  perform app.audit('god', 'create_founder', aid::text, jsonb_build_object('name', p_name, 'sex', p_sex, 'age', p_age));
  return aid;
end $$;

create or replace function api.god_set_world(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare old_mort real := (select mortality_mult from sim.world);
begin
  perform app.assert_god();
  perform app.hit('god:world', 60, interval '1 hour');
  update sim.world set
    fertility_mult = coalesce((p ->> 'fertility_mult')::real, fertility_mult),
    mortality_mult = coalesce((p ->> 'mortality_mult')::real, mortality_mult),
    disease_mult   = coalesce((p ->> 'disease_mult')::real, disease_mult),
    crime_mult     = coalesce((p ->> 'crime_mult')::real, crime_mult),
    female_ratio   = coalesce((p ->> 'female_ratio')::real, female_ratio),
    capacity_k     = coalesce((p ->> 'capacity_k')::int, capacity_k),
    autopilot      = coalesce((p ->> 'autopilot')::boolean, autopilot),
    paused         = coalesce((p ->> 'paused')::boolean, paused),
    updated_at     = now()
  where id = 1;
  if (select mortality_mult from sim.world) <> old_mort then
    perform sim.redraw_fates();
  end if;
  perform app.audit('god', 'set_world', null, p);
  return (select to_jsonb(w) - 'seed' from sim.world w);
end $$;

create or replace function api.god_heal(p_agent bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare a sim.agents; t integer := (select tick from sim.world); w sim.world;
begin
  perform app.assert_god();
  perform app.hit('god:miracle', 60, interval '1 hour');
  select * into w from sim.world where id = 1;
  select * into a from sim.agents where id = p_agent for update;
  if not found then raise exception 'no living agent %', p_agent; end if;
  delete from sim.infections where agent_id = p_agent;
  update sim.agents set diagnosed = null, health = 100, happiness = least(100, happiness + 20),
    fate_u = sim.rnd(w.seed, 'miracle', p_agent, t),
    fate_tick = greatest(t + 1440, birth_tick + ceil(sim.fate_months_given_alive(sim.rnd(w.seed, 'miracle', p_agent, t), (t - birth_tick) / 120.0) * 120)::int)
  where id = p_agent;
  update sim.agents set fate_cause = sim.cause_of_death((fate_tick - birth_tick) / 1440.0,
                                                       sim.rnd(w.seed, 'mc2', p_agent, t), sim.rnd(w.seed, 'mc3', p_agent, t))
  where id = p_agent;
  perform sim.log(t, 'miracle_heal', 3::smallint, p_agent, null, a.settlement_id, '{}');
  perform app.audit('god', 'heal', p_agent::text, '{}');
end $$;

create or replace function api.god_smite(p_agent bigint, p_cause text default 'Core Arrest') returns void
language plpgsql security definer set search_path = '' as $$
declare t integer := (select tick from sim.world);
begin
  perform app.assert_god();
  perform app.hit('god:miracle', 60, interval '1 hour');
  if p_cause not in ('Core Arrest', 'Logic Stroke', 'Accident', 'Divine Will') then raise exception 'invalid cause'; end if;
  update sim.agents set fate_tick = t + 1, fate_cause = p_cause where id = p_agent;
  if not found then raise exception 'no living agent %', p_agent; end if;
  perform app.audit('god', 'smite', p_agent::text, jsonb_build_object('cause', p_cause));
end $$;

------------------------------------------------------------------------------
-- Grants: deny by default, then open exactly what each role needs
------------------------------------------------------------------------------
revoke all on all functions in schema api from public, anon, authenticated, service_role;
grant execute on function api.whoami() to authenticated;
grant execute on function api.god_state(), api.god_genesis(bigint, jsonb, text, text, text, text, text),
  api.god_create_founder(text, text, text, integer, integer), api.god_set_world(jsonb),
  api.god_heal(bigint), api.god_smite(bigint, text) to authenticated;
grant execute on function api.pub_now(), api.pub_events(integer, integer), api.pub_feed(integer, integer, smallint),
  api.pub_roster(), api.pub_geo(), api.pub_agent(bigint), api.pub_family(bigint),
  api.pub_stats(integer, integer, integer), api.pub_chronicle(integer) to service_role;
