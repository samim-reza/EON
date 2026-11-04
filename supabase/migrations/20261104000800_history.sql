-- History: what visitors can look back on.
--
-- Everyday events are dropped after 14 real days to stay inside the free database. Two things keep
-- the story from being lost with them:
--   * the first time anything happens is history, so it goes in the chronicle forever
--   * every EON year is rolled up into one row of sim.annals, which is never deleted

alter table sim.settlements add column pop integer not null default 0;

alter table sim.world
  add column year_high    real,
  add column year_high_at text,
  add column year_low     real,
  add column year_low_at  text;

create table sim.annals (
  year          integer primary key,
  population    integer not null,
  settlements   integer not null,
  births        integer not null,
  deaths        integer not null,
  weddings      integer not null,
  outbreaks     integer not null,
  weather       integer not null,  -- weather stories told that year
  good_harvests integer not null,
  bad_harvests  integer not null,
  high          real,
  high_at       text,
  low           real,
  low_at        text,
  headline      jsonb              -- the year's biggest story
);

update sim.settlements s set pop = (select count(*) from sim.agents a where a.settlement_id = s.id);

create or replace function sim.log(p_tick integer, p_kind text, p_importance smallint, p_agent bigint,
                                   p_other bigint, p_settlement integer, p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare
  eid bigint := nextval('sim.event_id_seq');
  imp smallint := p_importance;
  body jsonb := coalesce(p_data, '{}');
begin
  -- The first time anything happens is history, however ordinary it later becomes.
  if imp < 3 and p_kind in ('birth', 'death', 'union', 'wedding', 'outbreak', 'weather', 'harvest')
     and not exists (select 1 from sim.chronicle c where c.kind = p_kind
                     and (p_kind <> 'weather' or c.data ->> 'kind' = body ->> 'kind')) then
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

-- Firsts from before this migration: without this, the next ordinary event would claim the title.
insert into sim.chronicle (id, tick, kind, agent_id, other_id, settlement_id, data)
select distinct on (e.kind, e.data ->> 'kind') e.id, e.tick, e.kind, e.agent_id, e.other_id, e.settlement_id, e.data || '{"first": true}'
from sim.events e
where e.kind in ('birth', 'death', 'union', 'wedding', 'outbreak', 'weather', 'harvest')
order by e.kind, e.data ->> 'kind', e.tick, e.id
on conflict (id) do nothing;

-- Rolls the year that just ended into one row, while its everyday events still exist.
create or replace function sim.p_annals(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  y integer := p_tick / 1440 - 1;
  t0 integer := (p_tick / 1440 - 1) * 1440;
  w sim.world;
  head jsonb;
begin
  select * into w from sim.world where id = 1;
  select jsonb_build_object('kind', e.kind, 'data', e.data, 'place', s.name) into head
  from sim.events e left join sim.settlements s on s.id = e.settlement_id
  where e.tick >= t0 and e.tick < p_tick
    and e.kind in ('weather', 'harvest', 'outbreak', 'founded', 'became_town', 'became_city')
  order by e.importance desc, e.tick limit 1;

  insert into sim.annals (year, population, settlements, births, deaths, weddings, outbreaks, weather,
                          good_harvests, bad_harvests, high, high_at, low, low_at, headline)
  select y, (select count(*) from sim.agents), (select count(*) from sim.settlements),
         count(*) filter (where e.kind = 'birth'),
         count(*) filter (where e.kind = 'death'),
         count(*) filter (where e.kind = 'wedding'),
         count(*) filter (where e.kind = 'outbreak'),
         count(*) filter (where e.kind = 'weather'),
         count(*) filter (where e.kind = 'harvest' and (e.data ->> 'good')::boolean),
         count(*) filter (where e.kind = 'harvest' and not (e.data ->> 'good')::boolean),
         w.year_high, w.year_high_at, w.year_low, w.year_low_at, head
  from sim.events e
  where e.tick >= t0 and e.tick < p_tick
  on conflict (year) do nothing;

  update sim.world set year_high = null, year_high_at = null, year_low = null, year_low_at = null where id = 1;
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
        food = greatest(0.4, least(1.4, 0.3 * t.food + 0.7 * (0.35 + 0.65 * least(1.5, rec.crop / 100)))),
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
    'places', coalesce((select jsonb_agg(p order by (p ->> 'pop')::int desc) from (
        select jsonb_build_object('id', s.id, 'name', s.name, 'x', s.x, 'y', s.y, 'pop', s.pop) as p
        from sim.settlements s order by s.pop desc, s.id limit 4) top), '[]'),
    'expecting', coalesce((select jsonb_agg(b order by (b ->> 'dueTick')::int) from (
        select jsonb_build_object('id', a.id, 'name', a.name || ' ' || a.surname, 'dueTick', g.due_tick) as b
        from sim.pregnancies g join sim.agents a on a.id = g.mother_id
        where g.outcome is null order by g.due_tick limit 3) soon), '[]')
  ) from sim.world w;
$$;

create or replace function api.pub_annals(p_limit integer default 120) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(a) order by a.year desc), '[]'::jsonb)
  from (select * from sim.annals order by year desc limit least(greatest(p_limit, 1), 500)) a;
$$;

revoke all on all functions in schema sim from public, anon, authenticated;
revoke all on function api.pub_annals(integer) from public, anon, authenticated;
grant execute on function api.pub_annals(integer) to service_role;
