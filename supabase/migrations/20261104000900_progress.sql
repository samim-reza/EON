-- Progress: people start with nothing and work everything out, step by step.
--
-- A world used to begin with a school, a market and a clinic for two people. Now a village is a
-- gathering place, and everything else waits on sim.discoveries: fire before shelter, tools before
-- farming, writing before schools, roads before towns connect. Knowledge grows with the number of
-- minds and how much they have been taught, so a larger, better-taught world learns faster.
--
-- Effects stay away from the life table. Discoveries improve harvests and slow disease, while
-- lifespans stay as calibrated.

alter table sim.world
  add column knowledge  double precision not null default 0,
  add column crop_bonus real not null default 1,
  add column medicine   real not null default 1;

alter table sim.buildings add column built_tick integer default 0; -- null: planned, not built yet
alter table sim.buildings drop constraint buildings_kind_check;
alter table sim.buildings add constraint buildings_kind_check check (kind in (
  'home', 'hall', 'farm', 'workshop', 'clinic', 'market', 'temple', 'school', 'smithy', 'mill', 'library', 'factory', 'station'));

create or replace function sim.civic_kinds() returns text[]
language sql immutable parallel safe set search_path = '' as $$
  select array['hall', 'farm', 'workshop', 'clinic', 'market', 'temple', 'school', 'smithy', 'mill', 'library', 'factory', 'station'];
$$;

create table sim.discoveries (
  id         text primary key,
  name       text not null,
  age        smallint not null,            -- which age of history it belongs to
  cost       real not null,                -- total knowledge the world needs first
  min_pop    integer not null default 0,   -- some things take more people than a family
  needs      text[] not null default '{}',
  builds     text,                         -- the building it makes possible
  build_pop  integer not null default 0,   -- how large a settlement must be to raise it
  story      text not null,                -- finishes "<name> ..."
  crop       real not null default 0,      -- added to harvests
  healing    real not null default 0,      -- share of disease it removes
  found_tick integer,
  found_by   bigint,
  found_at   integer
);

insert into sim.discoveries (id, name, age, cost, min_pop, needs, builds, build_pop, story, crop, healing) values
  ('fire',      'Fire',                1, 5,      2,    '{}',                   null,       0,   'learned to keep a fire alive', 0, 0),
  ('shelter',   'Shelter',             1, 12,     2,    '{fire}',               null,       0,   'built the first real shelter', 0, 0),
  ('worship',   'A place of worship',  1, 18,     2,    '{fire}',               'temple',   6,   'set aside a place for prayer', 0, 0),
  ('tools',     'Stone tools',         1, 25,     2,    '{fire}',               'workshop', 4,   'shaped the first stone tools', 0, 0),
  ('herbs',     'Healing herbs',       1, 40,     4,    '{fire}',               'clinic',   10,  'found which plants heal', 0, 0.1),
  ('farming',   'Farming',             2, 60,     4,    '{tools}',              'farm',     2,   'planted the first field', 0.15, 0),
  ('animals',   'Herding',             2, 110,    8,    '{farming}',            null,       0,   'tamed the first herd', 0.05, 0),
  ('pottery',   'Pottery',             2, 160,    10,   '{fire,farming}',       null,       0,   'fired the first clay pots to store grain', 0.05, 0),
  ('weaving',   'Weaving',             2, 220,    12,   '{farming}',            null,       0,   'wove the first cloth', 0, 0),
  ('counting',  'Counting',            3, 320,    20,   '{pottery}',            null,       0,   'worked out how to count and measure', 0, 0),
  ('writing',   'Writing',             3, 500,    30,   '{counting}',           'school',   15,  'wrote the first words', 0, 0),
  ('trade',     'Trade',               3, 650,    30,   '{pottery}',            'market',   20,  'opened the first market', 0, 0),
  ('wheel',     'The wheel',           3, 850,    40,   '{tools,pottery}',      null,       0,   'made the first wheel', 0.05, 0),
  ('roads',     'Roads',               3, 1100,   40,   '{wheel}',              null,       0,   'cut the first real road', 0, 0),
  ('bronze',    'Bronze',              4, 1500,   60,   '{wheel}',              null,       0,   'smelted the first bronze', 0, 0),
  ('iron',      'Iron',                4, 2600,   80,   '{bronze}',             'smithy',   40,  'forged the first iron', 0.05, 0),
  ('masonry',   'Stone masonry',       4, 3500,   100,  '{tools,iron}',         null,       0,   'raised the first stone walls', 0, 0),
  ('mills',     'Water mills',         4, 4500,   120,  '{wheel,iron}',         'mill',     60,  'harnessed a river to grind grain', 0.1, 0),
  ('irrigation','Irrigation',          4, 5000,   120,  '{mills}',              null,       0,   'dug the first canals', 0.15, 0),
  ('coin',      'Coinage',             4, 6000,   150,  '{iron,trade}',         null,       0,   'struck the first coins', 0, 0),
  ('law',       'Written law',         4, 7000,   150,  '{writing,coin}',       null,       0,   'wrote down the first laws', 0, 0),
  ('paving',    'Paved roads',         4, 9000,   200,  '{roads,masonry}',      null,       0,   'laid the first paved road', 0, 0),
  ('printing',  'Printing',            5, 14000,  300,  '{writing,iron}',       'library',  100, 'printed the first book', 0, 0.05),
  ('science',   'Science',             5, 20000,  400,  '{printing}',           null,       0,   'began testing ideas by experiment', 0, 0.05),
  ('medicine',  'Medicine',            5, 26000,  500,  '{science,herbs}',      null,       0,   'founded the first true medicine', 0, 0.2),
  ('steam',     'The steam engine',    5, 34000,  600,  '{science,iron}',       'factory',  200, 'built the first steam engine', 0.1, 0),
  ('railways',  'Railways',            5, 45000,  800,  '{steam,paving}',       'station',  300, 'laid the first railway', 0, 0),
  ('electric',  'Electricity',         6, 60000,  1000, '{steam}',              null,       0,   'lit the first electric lamp', 0, 0),
  ('engines',   'Motor vehicles',      6, 80000,  1200, '{electric,railways}',  null,       0,   'drove the first motor car', 0, 0),
  ('vaccines',  'Vaccines',            6, 100000, 1400, '{medicine}',           null,       0,   'made the first vaccine', 0, 0.3),
  ('computers', 'Computers',           6, 140000, 1600, '{electric}',           null,       0,   'built the first computer', 0, 0);

-- Existing worlds keep their people and homes. Everything else they were handed for free goes back
-- to being a plan until they discover it.
update sim.buildings set built_tick = null where kind not in ('home', 'hall');

insert into sim.buildings (settlement_id, kind, x, y, capacity, built_tick)
select s.id, k, s.x + 8 * cos(2 * pi() * sim.rnd(w.seed, 'bld', s.id, abs(hashtext(k)))),
       s.y + 8 * sin(2 * pi() * sim.rnd(w.seed, 'bld', s.id, abs(hashtext(k)))), 40, null
from sim.settlements s, sim.world w, unnest(array['smithy', 'mill', 'library', 'factory', 'station']) k;

create or replace function sim.found_settlement(p_tick integer, p_site integer, p_name text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  s sim.sites;
  sid integer;
  c record;
  seed bigint := (select w.seed from sim.world w);
  k text;
  i int := 0;
  nm text := p_name;
begin
  select * into s from sim.sites where id = p_site for update;
  if not found then raise exception 'unknown site %', p_site; end if;
  if s.taken then raise exception 'site % already settled', p_site; end if;
  while nm is null or exists (select 1 from sim.settlements where name = nm) loop
    nm := sim.make_place_name(sim.rnd(seed, 'place1', p_site, i), sim.rnd(seed, 'place2', p_site, i));
    i := i + 1;
  end loop;
  update sim.sites set taken = true where id = p_site;
  select * into c from sim.climate_at(seed, s.x, s.y, coalesce(s.elev, 0.2));
  insert into sim.settlements (name, site_id, x, y, region, founded_tick, elev, biome, temp_mean, temp_swing, wet, rainfall, river, coast)
  values (nm, p_site, s.x, s.y, s.region, p_tick, c.elev, c.biome, c.temp_mean, c.temp_swing, c.wet, c.rainfall, s.river, s.coast) returning id into sid;
  -- A new village is a gathering place and nothing else. The rest is land set aside for what its
  -- people will learn to build; sim.p_progress raises each building once it has been discovered.
  foreach k in array sim.civic_kinds() loop
    insert into sim.buildings (settlement_id, kind, x, y, capacity, built_tick)
    values (sid, k,
      s.x + (case k when 'hall' then 0 else (6 + 4 * sim.rnd(seed, 'bld-r', sid, abs(hashtext(k)))) * cos(2 * pi() * sim.rnd(seed, 'bld', sid, abs(hashtext(k)))) end),
      s.y + (case k when 'hall' then 0 else (6 + 4 * sim.rnd(seed, 'bld-r', sid, abs(hashtext(k)))) * sin(2 * pi() * sim.rnd(seed, 'bld', sid, abs(hashtext(k)))) end),
      40, case when k = 'hall' then p_tick end);
  end loop;
  perform sim.log(p_tick, 'founded', 3::smallint, null, null, sid, jsonb_build_object('name', nm));
  return sid;
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
end $$;

create or replace function sim.p_weather(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  month int := (p_tick / 120) % 12;
  yr int := p_tick / 1440;
  growing boolean := month <= 5;
  s record; x record; rec record;
  v_soil double precision; v_crop double precision; warm double precision; mood double precision;
  wet_days int; event text; severity int;
  best_id integer; best_event text; best_severity int := 0; best_data jsonb;
  dz smallint;
  hot double precision; hot_at text; cold double precision; cold_at text;
begin
  select * into w from sim.world where id = 1;
  for s in
    select st.*, p.people from sim.settlements st
    join (select settlement_id, count(*) as people from sim.agents group by settlement_id) p on p.settlement_id = st.id
    order by st.id
  loop
    select * into x from sim.weather_at(w.seed, 72 - 0.075 * s.y::float8, s.temp_mean, s.temp_swing, s.wet, s.rainfall, s.biome,
                                        s.x, s.y, p_tick, w.temp_shift, w.rain_mult);

    -- Crops need warmth and water; a late frost or a storm sets them back.
    v_soil := greatest(least(1, s.soil * 0.985 + x.rain * 0.06), 0.3 * s.river); -- river water keeps fields alive through a drought
    v_crop := s.crop;
    if growing then
      warm := sim.smooth(4, 16, (x.high + x.low) / 2) * (1 - sim.smooth(34, 42, x.high));
      v_crop := v_crop + warm * least(1, v_soil / 0.3);
      if month >= 1 and x.low < -2 then v_crop := v_crop * 0.92; end if;
      if x.kind = 'thunderstorm' then v_crop := v_crop * 0.98; end if;
    end if;

    -- How the weather feels: people enjoy mild sunny days and tire of long grey ones.
    mood := case when x.kind in ('clear', 'partly') then 4 when x.kind in ('cloudy', 'drizzle') then 0
                 when x.kind in ('overcast', 'fog', 'rain', 'sleet', 'snow') then -2 else -6 end
            - greatest(0, 8 - x.high) / 4 - greatest(0, x.high - 30) / 2;
    mood := greatest(-10, least(10, s.wx_mood * 0.93 + 0.07 * mood * 3));
    wet_days := case when x.rain >= 0.62 then s.wx_wet_days + 1 else 0 end;

    update sim.settlements t set
      pop = s.people, wx_kind = x.kind, wx_high = x.high, wx_low = x.low, wx_rain = x.rain, wx_mood = mood, wx_wet_days = wet_days,
      soil = v_soil, crop = v_crop,
      wx_snow_year = case when x.kind in ('snow', 'blizzard') then yr else t.wx_snow_year end
    where t.id = s.id;

    if hot is null or x.high > hot then hot := x.high; hot_at := s.name; end if;
    if cold is null or x.low < cold then cold := x.low; cold_at := s.name; end if;

    -- Fierce heat and deep cold wear on the frail.
    if x.high >= 40 or x.low <= -20 then
      dz := case when x.high >= 40 then 4 else 5 end;
      insert into sim.infections (agent_id, disease_id, since_tick, until_tick)
      select a.id, dz, p_tick, p_tick + 12 from sim.agents a
      where a.settlement_id = s.id and (p_tick - a.birth_tick < 5 * 1440 or p_tick - a.birth_tick >= 60 * 1440)
        -- A good coat costs money: in the cold, the poor suffer first.
        and sim.rnd(w.seed, 'exposed', a.id, p_tick) < case when dz = 5 and a.wealth < 100 then 0.08 else 0.03 end
      on conflict (agent_id, disease_id) do update set since_tick = excluded.since_tick, until_tick = excluded.until_tick
        where sim.infections.until_tick <= excluded.since_tick;

      update sim.agents a set fate_tick = p_tick + 1 + floor(8 * sim.rnd(w.seed, 'exposure-when', a.id, p_tick))::int,
                              fate_cause = case dz when 4 then 'Thermal Overload' else 'Frozen Servos' end
      where a.settlement_id = s.id and a.fate_cause <> 'Divine Will'
        and a.fate_tick - p_tick between 9 and 360
        and (p_tick - a.birth_tick < 2 * 1440 or p_tick - a.birth_tick >= 65 * 1440)
        and sim.rnd(w.seed, 'exposure', a.id, p_tick) < 0.15;
    end if;

    event := null; severity := 0;
    if x.kind = 'blizzard' then event := 'blizzard'; severity := 5;
    elsif wet_days >= 3 and s.elev < 0.3 then event := 'flood'; severity := 5;
    elsif wet_days >= 2 and s.river > 0 then event := 'flood'; severity := 5; -- rivers burst their banks sooner
    elsif s.coast and x.rain >= 0.62 and sim.spring_tide(w.seed, p_tick) >= 0.8 then event := 'surge'; severity := 5;
    elsif x.heatwave then event := 'heatwave'; severity := 4;
    elsif x.cold_snap then event := 'cold_snap'; severity := 4;
    elsif growing and month >= 2 and v_soil < 0.1 and s.rainfall >= 250 then event := 'drought'; severity := 4;
    elsif x.kind = 'sandstorm' then event := 'sandstorm'; severity := 3;
    elsif x.kind = 'thunderstorm' then event := 'storm'; severity := 3;
    elsif x.kind in ('snow') and s.wx_snow_year <> yr then event := 'first_snow'; severity := 2;
    end if;

    if event in ('flood', 'surge') then
      update sim.settlements t set crop = t.crop * 0.85 where t.id = s.id;
    end if;

    if severity > best_severity and p_tick - s.wx_event_tick >= 120 then
      best_id := s.id; best_event := event; best_severity := severity;
      best_data := jsonb_build_object('kind', event, 'high', round(x.high::numeric), 'low', round(x.low::numeric));
    end if;
  end loop;

  update sim.settlements t set pop = 0 where t.pop > 0 and not exists (select 1 from sim.agents a where a.settlement_id = t.id);

  -- The year's extremes go into its entry in the annals.
  update sim.world set
    year_high = case when year_high is null or hot > year_high then hot else year_high end,
    year_high_at = case when year_high is null or hot > year_high then hot_at else year_high_at end,
    year_low = case when year_low is null or cold < year_low then cold else year_low end,
    year_low_at = case when year_low is null or cold < year_low then cold_at else year_low_at end
  where id = 1 and hot is not null;

  -- The feed gets at most one weather story a day, however large the world grows.
  if best_id is not null then
    update sim.settlements set wx_event_tick = p_tick where id = best_id;
    if best_event in ('flood', 'surge') then
      update sim.agents set wealth = wealth - wealth / 20 where settlement_id = best_id and wealth > 0;
    end if;
    perform sim.log(p_tick, 'weather', (case when best_severity >= 4 then 2 else 1 end)::smallint, null, null, best_id, best_data);
  end if;

  -- Harvest time: the year's crop sets food stores and prices until the next one.
  if p_tick % 1440 = 720 then
    for rec in
      select st.id, st.crop, st.crop_norm from sim.settlements st
      where exists (select 1 from sim.agents a where a.settlement_id = st.id) order by st.id
    loop
      update sim.settlements t set
        -- Foraging and trade keep even the poorest land from zero.
        food = greatest(0.4, least(1.4, 0.3 * t.food + 0.7 * (0.35 + 0.65 * least(1.5, rec.crop * w.crop_bonus / 100)))),
        crop_norm = case when t.crop_norm is null then rec.crop else 0.8 * t.crop_norm + 0.2 * rec.crop end,
        crop = 0
      where t.id = rec.id;
      update sim.settlements t set price_idx = greatest(0.7, least(2.5, 1 / greatest(t.food, 0.4))) where t.id = rec.id;
      if rec.crop_norm > 5 and rec.crop >= rec.crop_norm * 1.2 then
        perform sim.log(p_tick, 'harvest', 1::smallint, null, null, rec.id, jsonb_build_object('good', true));
      elsif rec.crop_norm > 5 and rec.crop <= rec.crop_norm * 0.7 then
        perform sim.log(p_tick, 'harvest', 2::smallint, null, null, rec.id, jsonb_build_object('good', false));
      end if;
    end loop;
  end if;
end $$;

create or replace function sim.p_daily(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  st record; d record;
begin
  select * into w from sim.world where id = 1;
  -- immunity has worn off → forget the infection entirely
  delete from sim.infections i using sim.diseases dz
   where dz.id = i.disease_id and i.until_tick + dz.immunity_ticks <= p_tick;

  -- Fated Rust Flu victims fall ill shortly before their end
  insert into sim.infections (agent_id, disease_id, since_tick, until_tick)
  select a.id, 2, p_tick, a.fate_tick + 1 from sim.agents a
  where a.fate_cause = 'Rust Flu' and a.fate_tick - p_tick between 0 and 28
  on conflict (agent_id, disease_id) do update set since_tick = excluded.since_tick, until_tick = excluded.until_tick
    where sim.infections.until_tick <= excluded.since_tick;

  for st in select s.id, (select count(*) from sim.agents a where a.settlement_id = s.id) as pop,
                    coalesce(s.wx_high, 20) < 10 as cold  -- flu follows the cold, not a date
             from sim.settlements s loop
    continue when st.pop = 0;
    for d in select * from sim.diseases where kind = 'infectious' loop
      -- seeding
      if not exists (select 1 from sim.infections i join sim.agents a on a.id = i.agent_id
                     where i.disease_id = d.id and a.settlement_id = st.id and i.until_tick > p_tick)
         and (not d.winter_only or st.cold)
         and sim.rnd(w.seed, 'seed-' || d.id, st.id, p_tick) < (case d.id when 2 then 0.012 when 1 then 0.004 else 0.001 end) * w.disease_mult * w.medicine
      then
        insert into sim.infections (agent_id, disease_id, since_tick, until_tick)
        select a.id, d.id, p_tick, p_tick + d.duration_ticks from sim.agents a
        where a.settlement_id = st.id and (d.id <> 3 or p_tick - a.birth_tick < 12 * 1440)
          and not exists (select 1 from sim.infections i0 where i0.agent_id = a.id and i0.disease_id = d.id)
        order by sim.rnd(w.seed, 'patient0', a.id, p_tick) limit 1
        on conflict do nothing;
        if found then
          perform sim.log(p_tick, 'outbreak', (case when d.id = 2 then 2 else 1 end)::smallint, null, null, st.id, jsonb_build_object('disease', d.name));
        end if;
      end if;
      -- spread (SIR-style, daily)
      insert into sim.infections (agent_id, disease_id, since_tick, until_tick)
      select a.id, d.id, p_tick, p_tick + d.duration_ticks
      from sim.agents a,
           (select count(*)::float8 as inf from sim.infections i join sim.agents x on x.id = i.agent_id
             where i.disease_id = d.id and x.settlement_id = st.id and i.until_tick > p_tick) c
      where c.inf > 0 and a.settlement_id = st.id
        and (d.id <> 3 or p_tick - a.birth_tick < 12 * 1440)
        and not exists (select 1 from sim.infections i2 where i2.agent_id = a.id and i2.disease_id = d.id)
        and sim.rnd(w.seed, 'spread-' || d.id, a.id, p_tick) < d.beta * w.disease_mult * w.medicine * c.inf / st.pop
      on conflict do nothing;
    end loop;
  end loop;
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
  if p_tick % 4 = 0 then
    perform sim.p_weather(p_tick);
    perform sim.p_daily(p_tick);
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
    'settlements', (select count(*) from sim.settlements),
    'tune', jsonb_build_object('tempShift', w.temp_shift, 'rainMult', w.rain_mult),
    'age', (select coalesce(max(d.age), 1) from sim.discoveries d where d.found_tick is not null),
    'known', coalesce((select jsonb_agg(d.id order by d.found_tick) from sim.discoveries d where d.found_tick is not null), '[]'),
    'places', coalesce((select jsonb_agg(p order by (p ->> 'pop')::int desc) from (
        select jsonb_build_object('id', s.id, 'name', s.name, 'x', s.x, 'y', s.y, 'pop', s.pop) as p
        from sim.settlements s order by s.pop desc, s.id limit 4) top), '[]'),
    'expecting', coalesce((select jsonb_agg(b order by (b ->> 'dueTick')::int) from (
        select jsonb_build_object('id', a.id, 'name', a.name || ' ' || a.surname, 'dueTick', g.due_tick) as b
        from sim.pregnancies g join sim.agents a on a.id = g.mother_id
        where g.outcome is null order by g.due_tick limit 3) soon), '[]')
  ) from sim.world w;
$$;

create or replace function api.pub_geo() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'seed', (select seed::text from sim.world),
    'settlements', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'kind', s.kind, 'x', s.x, 'y', s.y, 'region', s.region, 'founded', s.founded_tick, 'food', round(s.food::numeric, 2),
        'pop', (select count(*) from sim.agents a where a.settlement_id = s.id)) order by s.id)
      from sim.settlements s), '[]'),
    'buildings', coalesce((select jsonb_agg(jsonb_build_array(b.id, b.settlement_id, b.kind, round(b.x::numeric, 1), round(b.y::numeric, 1)) order by b.id)
      from sim.buildings b where b.built_tick is not null), '[]'));
$$;

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
    'pyramid', (select coalesce(jsonb_agg(jsonb_build_object('band', band, 'F', f, 'M', m) order by band), '[]') from (
                  select least(((w.tick - a.birth_tick) / 1440) / 10, 10) * 10 as band,
                         count(*) filter (where a.sex = 'F') as f, count(*) filter (where a.sex = 'M') as m
                  from sim.agents a group by 1) pyr),
    'dbBytes', pg_database_size(current_database()),
    'audit', (select coalesce(jsonb_agg(to_jsonb(g) - 'prev_hash' order by g.id desc), '[]')
              from (select * from app.god_actions order by id desc limit 20) g))
    from sim.world w where w.id = 1);
end $$;

-- Runs once per EON month: the world learns, and what it has learned gets built.
create or replace function sim.p_progress(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  people integer; taught double precision;
  d sim.discoveries;
  who bigint; place integer;
  r record; hid bigint; changed boolean := false;
begin
  select count(*), coalesce(avg(education), 0) into people, taught from sim.agents;
  if people = 0 then return; end if;
  -- Twice the minds is not twice the ideas, and teaching multiplies what they can do.
  update sim.world set knowledge = knowledge + 0.6 * sqrt(people) * (1 + taught / 100) where id = 1 returning * into w;

  select x.* into d from sim.discoveries x
  where x.found_tick is null and x.cost <= w.knowledge and x.min_pop <= people
    and not exists (select 1 from unnest(x.needs) n join sim.discoveries y on y.id = n where y.found_tick is null)
  order by x.cost limit 1;
  if d.id is not null then
    -- Someone has the idea: usually the best taught, but not always.
    select a.id, a.settlement_id into who, place from sim.agents a
    where p_tick - a.birth_tick >= 12 * 1440
    order by a.education + 60 * sim.rnd(w.seed, 'discover', a.id, p_tick) desc limit 1;
    update sim.discoveries set found_tick = p_tick, found_by = who, found_at = place where id = d.id;
    update sim.world set crop_bonus = crop_bonus + d.crop, medicine = medicine * (1 - d.healing) where id = 1;
    perform sim.log(p_tick, 'discovery', 3::smallint, who, null, place,
                    jsonb_build_object('tech', d.id, 'name', d.name, 'age', d.age, 'story', d.story));
  end if;

  -- Each settlement raises what it knows how to build, once it is large enough. One a month keeps it gradual.
  for r in
    select distinct on (b.settlement_id) b.id, b.settlement_id, b.kind
    from sim.buildings b
    join sim.discoveries x on x.builds = b.kind and x.found_tick is not null
    join sim.settlements s on s.id = b.settlement_id
    where b.built_tick is null and s.pop >= x.build_pop
    order by b.settlement_id, x.cost
  loop
    update sim.buildings set built_tick = p_tick where id = r.id;
    perform sim.log(p_tick, 'built', 1::smallint, null, null, r.settlement_id, jsonb_build_object('building', r.kind));
    changed := true;
  end loop;

  -- Once shelter is known nobody sleeps in the open.
  if exists (select 1 from sim.discoveries x where x.id = 'shelter' and x.found_tick is not null) then
    for r in
      select a.id, a.settlement_id from sim.agents a
      where a.home_id is null and p_tick - a.birth_tick >= 16 * 1440 order by a.id limit 25
    loop
      hid := sim.new_home(r.settlement_id, 1000000 + r.id);
      update sim.agents set home_id = hid where id = r.id;
      changed := true;
    end loop;
  end if;
  if changed then update sim.world set roster_version = roster_version + 1 where id = 1; end if;
end $$;

-- God: found a settlement on a chosen site.
create or replace function api.god_found_settlement(p_site integer, p_name text) returns integer
language plpgsql security definer set search_path = '' as $$
declare t integer := (select tick from sim.world); sid integer;
begin
  perform app.assert_god();
  perform app.hit('god:settle', 30, interval '1 hour');
  if char_length(coalesce(p_name, '')) not between 2 and 24 then raise exception 'A settlement name must be 2–24 characters'; end if;
  if exists (select 1 from sim.settlements where name = p_name) then raise exception 'That name is already taken'; end if;
  if not exists (select 1 from sim.sites where id = p_site and not taken) then raise exception 'That site is already settled'; end if;
  sid := sim.found_settlement(t, p_site, p_name);
  update sim.world set roster_version = roster_version + 1 where id = 1;
  perform app.audit('god', 'found_settlement', sid::text, jsonb_build_object('site', p_site, 'name', p_name));
  return sid;
end $$;

-- God: lead someone to another settlement, with their partner and their young children.
create or replace function api.god_move_agent(p_agent bigint, p_settlement integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  t integer := (select tick from sim.world);
  a sim.agents; hid bigint; n integer;
begin
  perform app.assert_god();
  perform app.hit('god:move', 60, interval '1 hour');
  select * into a from sim.agents where id = p_agent;
  if not found then raise exception 'No living soul has that id'; end if;
  if not exists (select 1 from sim.settlements where id = p_settlement) then raise exception 'unknown settlement'; end if;
  if a.settlement_id = p_settlement then raise exception 'They already live there'; end if;
  hid := case when a.home_id is null and a.partner_id is null then null else sim.new_home(p_settlement, 2000000 + p_agent) end;
  update sim.agents c set settlement_id = p_settlement, home_id = hid
  where c.id = p_agent or c.id = a.partner_id
     or ((c.mother_id = p_agent or c.father_id = p_agent) and t - c.birth_tick < 16 * 1440 and c.home_id is not distinct from a.home_id);
  get diagnostics n = row_count;
  update sim.world set roster_version = roster_version + 1 where id = 1;
  perform sim.log(t, 'moved', 1::smallint, p_agent, a.partner_id, p_settlement, jsonb_build_object('people', n));
  perform app.audit('god', 'move_agent', p_agent::text, jsonb_build_object('to', p_settlement, 'people', n));
  return n;
end $$;

-- Everything the world knows and has yet to learn, for the history page.
create or replace function api.pub_progress() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'knowledge', (select knowledge from sim.world),
    'discoveries', coalesce((select jsonb_agg(jsonb_build_object(
        'id', d.id, 'name', d.name, 'age', d.age, 'cost', d.cost, 'story', d.story, 'tick', d.found_tick,
        'by', (select p.name || ' ' || p.surname from sim.people p where p.id = d.found_by),
        'byId', d.found_by,
        'place', (select s.name from sim.settlements s where s.id = d.found_at)) order by d.cost)
      from sim.discoveries d), '[]'));
$$;

-- A world already underway has been thinking since Genesis.
update sim.world w set knowledge = 0.6 * sqrt(greatest(1, (select count(*) from sim.agents))) * (w.tick / 120);

revoke all on all functions in schema sim from public, anon, authenticated;
revoke all on function api.god_found_settlement(integer, text), api.god_move_agent(bigint, integer), api.pub_progress() from public, anon, authenticated;
grant execute on function api.god_found_settlement(integer, text), api.god_move_agent(bigint, integer) to authenticated;
grant execute on function api.pub_progress() to service_role;
