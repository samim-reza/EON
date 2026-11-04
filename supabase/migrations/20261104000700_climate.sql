-- Climate: sun, seasons, weather and biomes, and what they do to people.
--
-- Weather is a pure function of the seed, a place and a time. The browser computes it for the map
-- and the functions below compute it for the simulation, so neither ever sends it to the other.
-- sim.hash3 … sim.weather_at are the twin of src/shared/climate.ts: change one, change both.
-- Golden vectors in supabase/tests and src/shared/climate.test.ts fail if they drift apart.

alter table sim.world
  add column temp_shift real not null default 0 check (temp_shift between -20 and 20), -- God's thermostat
  add column rain_mult  real not null default 1 check (rain_mult between 0 and 4);

alter table sim.sites
  add column elev  real,
  add column biome text,
  add column river real not null default 0,        -- 0 far from a river, 1 beside a great one
  add column coast boolean not null default false; -- close enough to the sea for tides to matter

alter table sim.settlements
  add column elev          real not null default 0.2,
  add column biome         text not null default 'grassland',
  add column temp_mean     real not null default 15,
  add column temp_swing    real not null default 10,
  add column wet           real not null default 0.5,
  add column rainfall      real not null default 800,
  add column river         real not null default 0,
  add column coast         boolean not null default false,
  -- today's weather, refreshed every EON day
  add column wx_kind       text,
  add column wx_high       real,
  add column wx_low        real,
  add column wx_rain       real not null default 0,
  add column wx_mood       real not null default 0,    -- how the weather has felt lately, -10 to 10
  add column wx_wet_days   smallint not null default 0, -- days of heavy rain in a row
  add column wx_event_tick integer not null default -100000,
  add column wx_snow_year  integer not null default -1,
  -- the land
  add column soil          real not null default 0.4,  -- soil moisture, 0 to 1
  add column crop          real not null default 0,    -- growth so far this year
  add column crop_norm     real;                       -- what a normal year yields here

alter table sim.diseases drop constraint diseases_kind_check;
alter table sim.diseases add constraint diseases_kind_check check (kind in ('infectious', 'chronic', 'exposure'));

insert into sim.diseases (id, name, kind, beta, duration_ticks, severity, winter_only, immunity_ticks, description) values
  (4, 'Thermal Overload', 'exposure', 0, 12, 15, false, 0, 'Circuits overheat in fierce sun. The old and the very young suffer first.'),
  (5, 'Frozen Servos',    'exposure', 0, 16, 15, false, 0, 'Joints seize in deep cold. Rest and warmth bring them back.');

------------------------------------------------------------------------------
-- The twin of src/shared/climate.ts
------------------------------------------------------------------------------
create or replace function sim.hash3(p_seed bigint, a bigint, b bigint, c bigint) returns double precision
language plpgsql immutable parallel safe set search_path = '' as $$
declare
  m constant bigint := 4294967295;
  h bigint;
begin
  -- The multipliers stay below 2^31, so 32 bits × multiplier always fits in a bigint.
  h := ((p_seed # a) & m) * 1540483477 & m;
  h := h # (h >> 15);
  h := ((h # b) & m) * 668265261 & m;
  h := h # (h >> 13);
  h := ((h # c) & m) * 374761393 & m;
  h := h # (h >> 16);
  return h::double precision / 4294967296.0::double precision;
end $$;

create or replace function sim.noise3(p_seed bigint, x double precision, y double precision, z double precision)
returns double precision language plpgsql immutable parallel safe set search_path = '' as $$
declare
  x0 bigint := floor(x)::bigint;
  y0 bigint := floor(y)::bigint;
  z0 bigint := floor(z)::bigint;
  fx double precision := x - x0;
  fy double precision := y - y0;
  fz double precision := z - z0;
  u double precision := fx * fx * (3 - 2 * fx);
  v double precision := fy * fy * (3 - 2 * fy);
  w double precision := fz * fz * (3 - 2 * fz);
  a double precision; b double precision; near double precision; far double precision;
begin
  a := sim.hash3(p_seed, x0, y0, z0); a := a + (sim.hash3(p_seed, x0 + 1, y0, z0) - a) * u;
  b := sim.hash3(p_seed, x0, y0 + 1, z0); b := b + (sim.hash3(p_seed, x0 + 1, y0 + 1, z0) - b) * u;
  near := a + (b - a) * v;
  a := sim.hash3(p_seed, x0, y0, z0 + 1); a := a + (sim.hash3(p_seed, x0 + 1, y0, z0 + 1) - a) * u;
  b := sim.hash3(p_seed, x0, y0 + 1, z0 + 1); b := b + (sim.hash3(p_seed, x0 + 1, y0 + 1, z0 + 1) - b) * u;
  far := a + (b - a) * v;
  return near + (far - near) * w;
end $$;

create or replace function sim.clamp01(v double precision) returns double precision
language sql immutable parallel safe set search_path = '' as $$
  select greatest(0::double precision, least(1::double precision, v));
$$;

create or replace function sim.smooth(e0 double precision, e1 double precision, v double precision) returns double precision
language plpgsql immutable parallel safe set search_path = '' as $$
declare t double precision := greatest(0::double precision, least(1::double precision, (v - e0) / (e1 - e0)));
begin
  return t * t * (3 - 2 * t);
end $$;

create or replace function sim.bump(v double precision, centre double precision, width double precision) returns double precision
language sql immutable parallel safe set search_path = '' as $$
  select exp(-power((v - centre) / width, 2));
$$;

create or replace function sim.biome_of(temp_mean double precision, rainfall double precision, elev double precision) returns text
language sql immutable parallel safe set search_path = '' as $$
  select case
    when temp_mean < -9 then 'ice'
    when elev > 0.5 then 'mountain'
    when temp_mean < -2 then 'tundra'
    when temp_mean < 5 then case when rainfall < 220 then 'tundra' else 'taiga' end
    when temp_mean < 18 then case when rainfall < 240 then 'desert' when rainfall < 520 then 'grassland'
                                  when rainfall < 1500 then 'forest' else 'rainforest' end
    else case when rainfall < 300 then 'desert' when rainfall < 850 then 'savanna'
              when rainfall < 1500 then 'forest' else 'jungle' end
  end;
$$;

create or replace function sim.climate_at(
  p_seed bigint, x double precision, y double precision, p_elev double precision,
  out lat double precision, out elev double precision, out temp_mean double precision, out temp_swing double precision,
  out wet double precision, out rainfall double precision, out biome text
) language plpgsql immutable parallel safe set search_path = '' as $$
declare pattern double precision; belts double precision;
begin
  lat := 72 - 0.075 * y;
  elev := greatest(0, p_elev);
  pattern := 0.6 * sim.noise3(p_seed # 5369127, x / 340, y / 340, 0.5) + 0.4 * sim.noise3(p_seed # 1851153, x / 120, y / 120, 7.5);
  belts := 0.34 * sim.bump(lat, 2, 13) - 0.3 * sim.bump(lat, 25, 9) + 0.16 * sim.bump(lat, 50, 12) - 0.12 * sim.bump(lat, 74, 10);
  wet := sim.clamp01((pattern - 0.5) * 2.6 + 0.56 + belts);
  rainfall := 60 + 2700 * power(wet, 2.2);
  temp_mean := 27.5 - 0.0072 * lat * lat - 30 * power(greatest(0, elev - 0.1), 1.3);
  temp_swing := 1 + 0.26 * abs(lat) + 2 * (1 - wet);
  biome := sim.biome_of(temp_mean, rainfall, elev);
end $$;

create or replace function sim.weather_at(
  p_seed bigint, lat double precision, temp_mean double precision, temp_swing double precision, wet double precision,
  rainfall double precision, biome text, x double precision, y double precision, tf double precision,
  p_temp_shift double precision default 0, p_rain_mult double precision default 1,
  out temp double precision, out high double precision, out low double precision, out cloud double precision,
  out rain double precision, out wind double precision, out kind text, out heatwave boolean, out cold_snap boolean
) language plpgsql immutable parallel safe set search_path = '' as $$
declare
  tau constant double precision := 2 * pi();
  days double precision := tf / 4;
  year_frac double precision := (tf - 1440 * floor(tf / 1440)) / 1440;
  season double precision := cos(tau * (year_frac - 0.333));
  hour double precision;
  front double precision; chance double precision; threshold double precision;
  monsoon double precision; dry_peak double precision;
  anomaly double precision; daily double precision; day_range double precision; gust double precision;
begin
  hour := 6 + (tf - 4 * floor(tf / 4)) * 6;
  hour := hour - 24 * floor(hour / 24);
  hour := hour + ((x - 500) / 1000) * 4 + 24;
  hour := hour - 24 * floor(hour / 24);

  front := 0.72 * sim.noise3(p_seed # 3108395, (x - 115 * days) / 260, y / 260, days / 3)
         + 0.28 * sim.noise3(p_seed # 8011153, (x - 115 * days) / 90, y / 90, days / 1.2);
  monsoon := 0.75 * sim.clamp01((26 - lat) / 10);
  dry_peak := -0.6 * sim.clamp01((lat - 28) / 6) * sim.clamp01((48 - lat) / 6);
  chance := greatest(0.002, least(0.85, (0.015 + 0.6 * power(rainfall / 2000, 0.75)) * (1 + (monsoon + dry_peak) * season) * p_rain_mult));
  threshold := 0.5 - 0.088 * ln(chance / (1 - chance));
  cloud := sim.smooth(threshold - 0.22, threshold + 0.02, front);
  rain := sim.smooth(threshold, threshold + 0.3, front);

  anomaly := (sim.noise3(p_seed # 3873877, x / 520, y / 520, days / 14) - 0.5) * 2.8 * (2 + 0.07 * abs(lat));
  daily := temp_mean + p_temp_shift + temp_swing * season + anomaly - 4 * rain;
  day_range := (3 + 6 * (1 - wet)) * (1 - 0.55 * cloud);
  temp := daily + day_range * cos((tau * (hour - 15)) / 24);
  gust := sim.noise3(p_seed # 5081619, x / 300, y / 300, days / 2);
  wind := 6 + 42 * gust * gust + 52 * rain * rain;

  if rain > 0.08 then
    if temp <= 0.5 then kind := case when rain >= 0.82 and wind >= 50 then 'blizzard' else 'snow' end;
    elsif temp <= 2.5 then kind := 'sleet';
    elsif rain < 0.28 then kind := 'drizzle';
    elsif rain < 0.62 then kind := 'rain';
    else kind := case when rain >= 0.82 and temp >= 16 then 'thunderstorm' else 'downpour' end;
    end if;
  elsif biome = 'desert' and wind >= 34 then kind := 'sandstorm';
  elsif wet > 0.32 and wind < 16 and cloud > 0.15 and hour > 3.5 and hour < 8.5 then kind := 'fog';
  else kind := case when cloud > 0.82 then 'overcast' when cloud > 0.45 then 'cloudy' when cloud > 0.18 then 'partly' else 'clear' end;
  end if;

  high := daily + day_range;
  low := daily - day_range;
  heatwave := high >= 38 or (season > 0.3 and anomaly >= 5);
  cold_snap := low <= -18 or (season < -0.3 and anomaly <= -5);
end $$;

-- 1 at new and full moon, when sun and moon pull the sea together; 0 at the quarters.
create or replace function sim.spring_tide(p_seed bigint, tf double precision) returns double precision
language plpgsql immutable parallel safe set search_path = '' as $$
declare phase double precision := tf / 118.12 + sim.hash3(p_seed, 11, 0, 0);
begin
  return abs(cos(2 * pi() * (phase - floor(phase))));
end $$;

------------------------------------------------------------------------------
-- Places
------------------------------------------------------------------------------
-- Rivers and the sea draw people: most of humanity has always lived near water.
create or replace function sim.habitability(p_biome text, p_river double precision default 0, p_coast boolean default false)
returns double precision language sql immutable parallel safe set search_path = '' as $$
  select (case p_biome
    when 'grassland' then 1 when 'forest' then 1 when 'savanna' then 0.8 when 'rainforest' then 0.7
    when 'jungle' then 0.6 when 'taiga' then 0.5 when 'mountain' then 0.25 when 'desert' then 0.25
    when 'tundra' then 0.2 when 'ice' then 0.02 else 0.5 end)
    * (1 + 1.5 * p_river) * (case when p_coast then 1.2 else 1 end);
$$;

-- Works out the climate of every site and settlement from stored elevations.
create or replace function sim.refresh_climate() returns void
language plpgsql security definer set search_path = '' as $$
declare seed bigint := (select w.seed from sim.world w where w.id = 1);
begin
  update sim.sites t set biome = c.biome
  from sim.sites s cross join lateral sim.climate_at(seed, s.x, s.y, coalesce(s.elev, 0.2)) c
  where t.id = s.id;
  update sim.settlements t set elev = c.elev, biome = c.biome, temp_mean = c.temp_mean, temp_swing = c.temp_swing,
                               wet = c.wet, rainfall = c.rainfall, river = coalesce(g.river, 0), coast = coalesce(g.coast, false)
  from sim.settlements s
  left join sim.sites g on g.id = s.site_id
  cross join lateral sim.climate_at(seed, s.x, s.y, coalesce(g.elev, 0.2)) c
  where t.id = s.id;
end $$;

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
  foreach k in array array['hall', 'farm', 'workshop', 'clinic', 'market', 'temple', 'school'] loop
    insert into sim.buildings (settlement_id, kind, x, y, capacity)
    values (sid, k,
      s.x + (case k when 'hall' then 0 else 7 * cos(2 * pi() * sim.rnd(seed, 'bld', sid, ascii(k))) end),
      s.y + (case k when 'hall' then 0 else 7 * sin(2 * pi() * sim.rnd(seed, 'bld', sid, ascii(k))) end),
      40);
  end loop;
  perform sim.log(p_tick, 'founded', 3::smallint, null, null, sid, jsonb_build_object('name', nm));
  return sid;
end $$;

create or replace function sim.spawn_founder_couple(p_tick integer, p_actor text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  p jsonb := (select value from sim.params where key = 'demography');
  amin double precision := (p -> 'genesis' ->> 'founderAgeMin')::float8;
  aspan double precision := (p -> 'genesis' ->> 'founderAgeMax')::float8 - amin;
  st integer; site integer; sname text; k bigint := p_tick; f bigint; m bigint;
begin
  select * into w from sim.world where id = 1;
  if sim.rnd(w.seed, 'newvillage', k) < 0.35 then
    -- Weighted random choice: people settle fertile land far more often than ice or sand.
    select id into site from sim.sites where not taken
     order by -ln(greatest(sim.rnd(w.seed, 'site', id, k), 1e-12)) / sim.habitability(biome, river, coast) limit 1;
  end if;
  if site is not null then
    st := sim.found_settlement(p_tick, site, null);
  else
    select s.id into st from sim.settlements s
     order by (select count(*) from sim.agents a where a.settlement_id = s.id), s.id limit 1;
  end if;
  if st is null then return; end if;
  sname := sim.make_surname(sim.rnd(w.seed, 'fsur', k));
  f := sim.spawn_agent(p_tick, sim.make_name('F', sim.rnd(w.seed, 'fn1', k), sim.rnd(w.seed, 'fn2', k)),
                       sim.make_surname(sim.rnd(w.seed, 'fsurf', k)), 'F',
                       p_tick - ((amin + aspan * sim.rnd(w.seed, 'fage', k)) * 1440)::int,
                       null, null, '{}', 0::smallint, true, st, null, sim.random_traits(k * 2), 200);
  m := sim.spawn_agent(p_tick, sim.make_name('M', sim.rnd(w.seed, 'mn1', k), sim.rnd(w.seed, 'mn2', k)),
                       sname, 'M',
                       p_tick - ((amin + aspan * sim.rnd(w.seed, 'mage', k)) * 1440)::int,
                       null, null, '{}', 0::smallint, true, st, null, sim.random_traits(k * 2 + 1), 200);
  perform sim.log(p_tick, 'founders_arrive', 3::smallint, f, m, st, jsonb_build_object('by', p_actor));
  perform app.audit(p_actor, 'founder_couple', st::text, jsonb_build_object('female', f, 'male', m));
end $$;

------------------------------------------------------------------------------
-- Weather's effect on the land and on people. Runs once per EON day.
--
-- The calibrated life table stays in charge of how long people live: severe weather can only
-- bring forward a death already due within three EON months, so it writes stories without
-- changing life expectancy or endangering a small population.
------------------------------------------------------------------------------
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
begin
  select * into w from sim.world where id = 1;
  for s in
    select st.*, p.pop from sim.settlements st
    join (select settlement_id, count(*) as pop from sim.agents group by settlement_id) p on p.settlement_id = st.id
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
      wx_kind = x.kind, wx_high = x.high, wx_low = x.low, wx_rain = x.rain, wx_mood = mood, wx_wet_days = wet_days,
      soil = v_soil, crop = v_crop,
      wx_snow_year = case when x.kind in ('snow', 'blizzard') then yr else t.wx_snow_year end
    where t.id = s.id;

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

create or replace function sim.p_bucket(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  p jsonb := (select value from sim.params where key = 'demography');
  b smallint := (p_tick % 120)::smallint;
  min_age int := (p -> 'fertility' ->> 'partnerMinAge')::int * 1440;
  gap int := (p -> 'fertility' ->> 'maxAgeGap')::int * 1440;
  chance double precision := (p -> 'fertility' ->> 'matchChanceMonthly')::float8;
  q record; cand bigint; r record;
begin
  select * into w from sim.world where id = 1;

  -- 1. Life stage & work, economy, health, mood
  update sim.agents a set
    occupation = sim.occupation_for_age((p_tick - a.birth_tick) / 1440.0, a.occupation, sim.rnd(w.seed, 'job', a.id, p_tick)),
    education = least(100, a.education + case when (p_tick - a.birth_tick) between 6 * 1440 and 18 * 1440 then 1 else 0 end),
    wealth = a.wealth
      + round(case a.occupation when 'farmer' then 30 * least(1.3, s.food) when 'builder' then 40 when 'healer' then 55 when 'elder' then 8 else 0 end)::bigint
      - round(case when a.occupation in ('farmer', 'builder', 'healer', 'elder')
                   then 25 * s.price_idx + case when coalesce(s.wx_high, 20) < 8 then 4 else 0 end else 0 end)::bigint, -- warm clothes cost money
    health = sim.clamp100(100 - greatest(0, (p_tick - a.birth_tick) / 1440.0 - 50) * 1.4
                          - coalesce((select sum(d.severity) from sim.infections i join sim.diseases d on d.id = i.disease_id
                                      where i.agent_id = a.id and i.until_tick > p_tick), 0)
                          - case when a.diagnosed is not null then 20 else 0 end
                          - greatest(0, 0.6 - s.food) * 50),  -- going hungry
    happiness = sim.clamp100(a.happiness * 0.8 + 0.2 * (
                  45 + case when a.partner_id is not null then 15 else 0 end
                     + least(20, greatest(-20, a.wealth / 50.0))
                     + (a.trait_e - 50) / 5.0 - (a.trait_n - 50) / 5.0
                     + s.wx_mood - greatest(0, 0.8 - s.food) * 25))
  from sim.settlements s
  where a.bucket = b and s.id = a.settlement_id;

  -- 2. Chronic diagnoses appear 1–6 EON years before a chronic fate (foreshadowing)
  for r in
    select a.id, a.fate_cause, a.settlement_id from sim.agents a
    where a.bucket = b and a.diagnosed is null
      and a.fate_cause in ('Battery Rot', 'Memory Leak Syndrome', 'Coolant Lung')
      and a.fate_tick - p_tick <= (case a.fate_cause when 'Memory Leak Syndrome' then 2 + 4 * sim.rnd(w.seed, 'diag', a.id)
                                                    when 'Battery Rot' then 1 + 2 * sim.rnd(w.seed, 'diag', a.id)
                                                    else 0.3 end) * 1440
  loop
    update sim.agents set diagnosed = r.fate_cause where id = r.id;
    perform sim.log(p_tick, 'diagnosis', 1::smallint, r.id, null, r.settlement_id, jsonb_build_object('disease', r.fate_cause));
  end loop;

  -- 3. Partnering (kin-blocked, same settlement, age gap limit)
  for q in
    select a.id, a.sex, a.birth_tick, a.settlement_id, a.lineage from sim.agents a
    where a.bucket = b and a.partner_id is null and p_tick - a.birth_tick >= min_age
      and sim.rnd(w.seed, 'match', a.id, p_tick) < chance
    order by a.id
  loop
    continue when exists (select 1 from sim.agents x where x.id = q.id and x.partner_id is not null);
    select c.id into cand from sim.agents c
     where c.settlement_id = q.settlement_id and c.sex <> q.sex and c.partner_id is null
       and p_tick - c.birth_tick >= min_age and abs(c.birth_tick - q.birth_tick) <= gap
       and not sim.is_close_kin(q.id, q.lineage, c.id, c.lineage)
     order by sim.rnd(w.seed, 'cand', q.id, c.id)
     limit 1;
    if cand is not null then
      perform sim.unite(p_tick, q.id, cand);
    end if;
  end loop;

  -- 4. Weddings: partners for 1+ EON years may marry
  for r in
    select u.id, u.female_id, u.male_id, a.settlement_id from sim.unions u join sim.agents a on a.id = u.female_id
    where a.bucket = b and u.end_tick is null and u.kind = 'partner' and p_tick - u.start_tick >= 1440
      and sim.rnd(w.seed, 'wed', u.id, p_tick) < 0.12
  loop
    update sim.unions set kind = 'married' where id = r.id;
    perform sim.log(p_tick, 'wedding', 2::smallint, r.female_id, r.male_id, r.settlement_id, '{}');
  end loop;

  -- 5. Conception
  for r in
    insert into sim.pregnancies (mother_id, father_id, conceived_tick, due_tick)
    select a.id, a.partner_id, p_tick,
           -- 9 EON months ± 2 weeks, so births land on any day
           p_tick + (p -> 'fertility' ->> 'pregnancyTicks')::int - 60 + floor(120 * sim.rnd(w.seed, 'gest', a.id, p_tick))::int
    from sim.agents a
    where a.bucket = b and a.sex = 'F' and a.partner_id is not null and a.fertile_after_tick <= p_tick
      and a.kids < a.desired_kids
      and not exists (select 1 from sim.pregnancies g where g.mother_id = a.id and g.outcome is null)
      and sim.rnd(w.seed, 'conceive', a.id, p_tick) < sim.conception_monthly((p_tick - a.birth_tick) / 1440.0) * w.fertility_mult
    on conflict do nothing
    returning mother_id, father_id
  loop
    perform sim.log(p_tick, 'pregnant', 1::smallint, r.mother_id, r.father_id,
                    (select settlement_id from sim.agents where id = r.mother_id), '{}');
  end loop;
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
         and sim.rnd(w.seed, 'seed-' || d.id, st.id, p_tick) < (case d.id when 2 then 0.012 when 1 then 0.004 else 0.001 end) * w.disease_mult
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
        and sim.rnd(w.seed, 'spread-' || d.id, a.id, p_tick) < d.beta * w.disease_mult * c.inf / st.pop
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
  if p_tick % 1440 = 0 then perform sim.p_yearly(p_tick); end if;
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
    'tune', jsonb_build_object('tempShift', w.temp_shift, 'rainMult', w.rain_mult)
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
    'settlement', (select jsonb_build_object('id', s.id, 'name', s.name, 'kind', s.kind, 'x', s.x, 'y', s.y, 'food', round(s.food::numeric, 2)) from sim.settlements s where s.id = p.settlement_id),
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
      'dueTick', (select min(g.due_tick) from sim.pregnancies g where g.mother_id = a.id and g.outcome is null),
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
  insert into sim.sites (id, x, y, region, elev, river, coast)
  select (e ->> 0)::int, (e ->> 1)::real, (e ->> 2)::real, (e ->> 3)::smallint, (e ->> 4)::real,
         coalesce((e ->> 5)::real, 0), coalesce((e ->> 6)::boolean, false)
  from jsonb_array_elements(p_sites) e;
  perform sim.refresh_climate();
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

-- One-off for worlds created before sites stored their geography. Elevation and rivers come from
-- noise that only the app computes, so scripts/backfill-climate.ts sends them here as
-- [id, elevation, river, coast]. New worlds get them at Genesis.
create or replace function api.set_site_geography(p_sites jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if jsonb_typeof(p_sites) <> 'array' or jsonb_array_length(p_sites) > 2000 then raise exception 'invalid sites'; end if;
  update sim.sites t set elev = (e ->> 1)::real, river = coalesce((e ->> 2)::real, 0), coast = coalesce((e ->> 3)::boolean, false)
  from jsonb_array_elements(p_sites) e
  where t.id = (e ->> 0)::int and t.elev is null;
  get diagnostics n = row_count;
  perform sim.refresh_climate();
  return n;
end $$;

-- A world already underway keeps this year's harvest: credit the growing season so far.
select sim.refresh_climate();
update sim.settlements s set crop = 80 * least(1, (w.tick % 1440) / 720.0)
from sim.world w where w.id = 1;

revoke all on all functions in schema sim from public, anon, authenticated;
revoke all on function api.set_site_geography(jsonb) from public, anon, authenticated;
grant execute on function api.set_site_geography(jsonb) to service_role;
