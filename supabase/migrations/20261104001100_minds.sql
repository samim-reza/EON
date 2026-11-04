-- Minds: the people of EON find their voice.
--
-- The rules decide everything that happens; Claude only writes words about it. Text is attached to
-- events that already exist, so if the budget runs out or the API fails, the plain line simply stays.
--
-- Jobs queue here. Every two minutes, if there is work, the database signs a request to wake the
-- worker in Vercel. The worker claims jobs, each claim reserving its cost against the day's cap
-- first, so concurrent runs can never overspend, and settles the real cost when Claude answers.

create extension if not exists pg_net;

alter table social.posts alter column agent_id drop not null;
alter table sim.world add column llm_cap real not null default 0.5 check (llm_cap between 0 and 5);

create table llm.jobs (
  id            bigserial primary key,
  kind          text not null check (kind in ('obituary', 'birth', 'discovery', 'prayer', 'story', 'diary', 'news')),
  priority      smallint not null default 5,  -- 1 first
  tick          integer not null,
  event_id      bigint,                       -- the event this gives a voice to, if any
  event_tick    integer,
  agent_id      bigint,
  other_id      bigint,
  settlement_id integer,
  context       jsonb not null default '{}',
  status        text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed')),
  reserved      numeric(10, 6) not null default 0,
  claimed_at    timestamptz,
  created_at    timestamptz not null default now()
);
create index on llm.jobs (priority, id) where status = 'queued';
create index on llm.jobs (claimed_at) where status = 'running';

create table llm.budget (
  day        date primary key,
  reserved   numeric(10, 6) not null default 0,
  spent      numeric(10, 6) not null default 0,
  lines      integer not null default 0,
  tokens_in  bigint not null default 0,
  tokens_out bigint not null default 0
);

-- Where to wake the worker, and the secret to sign with. That secret can only wake the worker: it
-- reads nothing and writes nothing. It is set once by scripts/setup-minds.ts, never in a migration.
create table llm.config (
  id     smallint primary key default 1 check (id = 1),
  url    text not null check (url ~ '^https://'),
  secret text not null check (char_length(secret) >= 32)
);

-- Decides which events are worth words. A large world could produce thousands a day, so everyday
-- ones stop once there are too many people to write about each.
create or replace function llm.on_event(p_id bigint, p_tick integer, p_kind text, p_imp smallint, p_agent bigint,
                                        p_other bigint, p_settlement integer, p_data jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  job text; rank smallint;
  crowded boolean := coalesce((select s.population from sim.world_stats s order by s.tick desc limit 1), 0) > 400;
begin
  case
    when p_kind = 'death' then job := 'obituary'; rank := 1;
    when p_kind = 'discovery' then job := 'discovery'; rank := 2;
    when p_kind = 'birth' and (not crowded or p_imp >= 3) then job := 'birth'; rank := 3;
    when p_kind in ('weather', 'harvest', 'wedding', 'built') and p_imp >= 2 and not crowded then job := 'story'; rank := 4;
    when p_kind = 'prayer' and not crowded then job := 'prayer'; rank := 6;
    else return;
  end case;
  insert into llm.jobs (kind, priority, tick, event_id, event_tick, agent_id, other_id, settlement_id, context)
  values (job, rank, p_tick, p_id, p_tick, p_agent, p_other, p_settlement, jsonb_build_object('event', p_kind, 'data', p_data));
end $$;

-- Someone writes a line now and then, and three times a real day the news goes round.
create or replace function llm.p_voices(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare w sim.world; who record;
begin
  select * into w from sim.world where id = 1;
  select a.id, a.settlement_id into who from sim.agents a
  where p_tick - a.birth_tick >= 10 * 1440 and a.soul_id is null
  order by sim.rnd(w.seed, 'voice', a.id, p_tick) limit 1;
  if who.id is not null then
    insert into llm.jobs (kind, priority, tick, agent_id, settlement_id) values ('diary', 8, p_tick, who.id, who.settlement_id);
  end if;
  if p_tick % 480 = 0 then
    insert into llm.jobs (kind, priority, tick) values ('news', 5, p_tick);
  end if;
end $$;

-- What the writer may know: only facts, and only what this age of the world has discovered.
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
      select v.kind, v.data - 'voice' - 'story' as data,
             (select p.name || ' ' || p.surname from sim.people p where p.id = v.agent_id) as who,
             (select s.name from sim.settlements s where s.id = v.settlement_id) as place
      from sim.events v where v.tick >= j.tick - 480 and v.importance >= 1 and v.kind <> 'voice'
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

create or replace function sim.log(p_tick integer, p_kind text, p_importance smallint, p_agent bigint,
                                   p_other bigint, p_settlement integer, p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare
  eid bigint := nextval('sim.event_id_seq');
  imp smallint := p_importance;
  body jsonb := coalesce(p_data, '{}');
begin
  -- The first time anything happens is history, however ordinary it later becomes.
  if imp < 3 and p_kind in ('birth', 'death', 'union', 'wedding', 'outbreak', 'weather', 'harvest', 'built')
     and not exists (select 1 from sim.chronicle c where c.kind = p_kind
                     and (p_kind <> 'weather' or c.data ->> 'kind' = body ->> 'kind')
                     and (p_kind <> 'built' or c.data ->> 'building' = body ->> 'building')) then
    imp := 3;
    body := body || '{"first": true}';
  end if;
  insert into sim.events (id, tick, kind, importance, agent_id, other_id, settlement_id, data)
  values (eid, p_tick, p_kind, imp, p_agent, p_other, p_settlement, body);
  if imp >= 3 then
    insert into sim.chronicle (id, tick, kind, agent_id, other_id, settlement_id, data)
    values (eid, p_tick, p_kind, p_agent, p_other, p_settlement, body);
  end if;
  perform llm.on_event(eid, p_tick, p_kind, imp, p_agent, p_other, p_settlement, body);
end $$;

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
  if p_tick % 30 = 0 then perform llm.p_voices(p_tick); end if;
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
    'ai', (select jsonb_build_object('spent', coalesce(b.spent, 0), 'lines', coalesce(b.lines, 0), 'cap', w.llm_cap,
                    'waiting', (select count(*) from llm.jobs j where j.status = 'queued'))
           from (select 1) one left join llm.budget b on b.day = current_date),
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
    temp_shift     = coalesce((p ->> 'temp_shift')::real, temp_shift),
    rain_mult      = coalesce((p ->> 'rain_mult')::real, rain_mult),
    llm_cap        = coalesce((p ->> 'llm_cap')::real, llm_cap),
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

-- Every two minutes: nothing to do costs nothing, not even a request.
create or replace function llm.wake() returns void
language plpgsql security definer set search_path = '' as $$
declare
  c llm.config;
  stamp text := extract(epoch from now())::bigint::text;
begin
  delete from llm.jobs where status in ('done', 'failed') and created_at < now() - interval '3 days';
  delete from llm.jobs where status = 'queued' and created_at < now() - interval '1 day';
  select * into c from llm.config where id = 1;
  if not found or not exists (select 1 from llm.jobs where status = 'queued') then return; end if;
  perform net.http_post(
    url := c.url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json',
      'X-EON-Sig', 't=' || stamp || ',v1=' || encode(extensions.hmac(stamp, c.secret, 'sha256'), 'hex')),
    timeout_milliseconds := 55000);
end $$;

create or replace function api.minds_configure(p_url text, p_secret text) returns void
language sql security definer set search_path = '' as $$
  insert into llm.config (id, url, secret) values (1, p_url, p_secret)
  on conflict (id) do update set url = excluded.url, secret = excluded.secret;
$$;

-- Claims work, reserving its cost first. Stops the moment the day's cap would be passed.
create or replace function api.minds_claim(p_limit integer default 6) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  estimate constant numeric := 0.0002;
  cap numeric := (select w.llm_cap from sim.world w where w.id = 1);
  today date := current_date;
  j llm.jobs;
  claimed jsonb := '[]';
  stale record;
begin
  -- A worker that died mid-job hands its reservation back.
  for stale in update llm.jobs set status = 'queued', claimed_at = null where status = 'running' and claimed_at < now() - interval '10 minutes' returning reserved loop
    update llm.budget b set reserved = greatest(0, b.reserved - stale.reserved) where b.day = today;
  end loop;
  insert into llm.budget (day) values (today) on conflict (day) do nothing;
  for j in select * from llm.jobs where status = 'queued' order by priority, id limit least(greatest(p_limit, 1), 12) for update skip locked loop
    update llm.budget b set reserved = b.reserved + estimate where b.day = today and b.spent + b.reserved + estimate <= cap;
    exit when not found;
    update llm.jobs set status = 'running', claimed_at = now(), reserved = estimate where id = j.id;
    claimed := claimed || jsonb_build_object('id', j.id, 'kind', j.kind, 'facts', llm.facts(j));
  end loop;
  return claimed;
end $$;

-- Settles the real cost, and gives the event its voice. Haiku 5.5: $0.10 in, $0.50 out, per million tokens.
create or replace function api.minds_finish(p_job bigint, p_text text, p_in integer, p_out integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  j llm.jobs;
  w sim.world;
  cost numeric := (greatest(p_in, 0) * 0.10 + greatest(p_out, 0) * 0.50) / 1000000;
  words text := nullif(trim(coalesce(p_text, '')), '');
begin
  update llm.jobs set status = case when words is null then 'failed' else 'done' end where id = p_job and status = 'running' returning * into j;
  if not found then return; end if;
  select * into w from sim.world where id = 1;
  if char_length(coalesce(words, '')) > 300 then words := left(words, 300); end if;
  update llm.budget b set reserved = greatest(0, b.reserved - j.reserved), spent = b.spent + cost,
                          lines = b.lines + case when words is null then 0 else 1 end,
                          tokens_in = b.tokens_in + greatest(p_in, 0), tokens_out = b.tokens_out + greatest(p_out, 0)
   where b.day = j.claimed_at::date;
  if words is null then return; end if;
  if j.event_id is not null then
    update sim.events e set data = e.data || jsonb_build_object('voice', words) where e.tick = j.event_tick and e.id = j.event_id;
    update sim.chronicle c set data = c.data || jsonb_build_object('voice', words) where c.id = j.event_id;
  else
    perform sim.log(w.tick, 'voice', 1::smallint, j.agent_id, null, j.settlement_id, jsonb_build_object('type', j.kind, 'text', words));
  end if;
  insert into social.posts (tick, agent_id, kind, body, source)
  values (w.tick, j.agent_id, case j.kind when 'obituary' then 'obituary' when 'news' then 'news' when 'prayer' then 'prayer' when 'diary' then 'diary' else 'post' end, words, 'llm');
end $$;

select cron.schedule('eon-minds', '*/2 * * * *', 'select llm.wake()');

revoke all on all functions in schema llm from public, anon, authenticated;
revoke all on all functions in schema sim from public, anon, authenticated;
revoke all on function api.minds_configure(text, text), api.minds_claim(integer), api.minds_finish(bigint, text, integer, integer) from public, anon, authenticated;
grant execute on function api.minds_configure(text, text), api.minds_claim(integer), api.minds_finish(bigint, text, integer, integer) to service_role;
