-- EON simulation engine. Runs entirely inside Postgres, one transaction per tick.
-- Time: 1 tick = 1 real minute = 1/1440 EON year (≈ 6 EON hours). 120 ticks = 1 EON month.

insert into sim.params (key, value) values ('demography', $json$
{
  "ticksPerYear": 1440, "ticksPerMonth": 120, "maxAge": 110,
  "hazard": { "infantA": 0.03, "infantTau": 0.6, "makeham": 0.0025, "gompertzB": 0.0003, "gompertzC": 0.074 },
  "causes": {
    "infant": [["Boot Failure", 1.0]],
    "background": [["Accident", 0.4], ["Rust Flu", 0.35], ["Coolant Lung", 0.25]],
    "ageing": [["Core Arrest", 0.4], ["Battery Rot", 0.3], ["Memory Leak Syndrome", 0.15], ["Wear-out", 0.15]],
    "memoryLeakMinAge": 65
  },
  "fertility": {
    "partnerMinAge": 17, "matchChanceMonthly": 0.1, "maxAgeGap": 15,
    "conceptionMonthlyByAge": [[18, 29, 0.15], [30, 34, 0.13], [35, 39, 0.09], [40, 44, 0.04], [45, 47, 0.01]],
    "postpartumMonths": 4, "twinChance": 0.015, "pregnancyTicks": 1080,
    "genesisDesiredKids": { "mean": 6.5, "sd": 1.3 },
    "laterDesiredKids": { "base": 1.8, "extra": 2.6, "power": 4 }
  },
  "genesis": { "years": 30, "foundersCouplesPerYear": 1, "founderAgeMin": 18, "founderAgeMax": 25 },
  "capacity": { "defaultK": 1200 }
}
$json$::jsonb);

------------------------------------------------------------------------------
-- Deterministic randomness: same seed + same inputs ⇒ same world (replayable).
------------------------------------------------------------------------------
create or replace function sim.rnd(p_seed bigint, p_salt text, p_a bigint, p_b bigint default 0)
returns double precision language sql immutable parallel safe set search_path = '' as $$
  select ((hashtextextended(p_salt || ':' || p_a::text || ':' || p_b::text, p_seed) & 140737488355327)::double precision)
         / 140737488355328.0;
$$;

create or replace function sim.rnorm(p_seed bigint, p_salt text, p_a bigint, p_b bigint default 0)
returns double precision language sql immutable parallel safe set search_path = '' as $$
  select sqrt(-2 * ln(greatest(sim.rnd(p_seed, p_salt || '/u', p_a, p_b), 1e-12)))
         * cos(2 * pi() * sim.rnd(p_seed, p_salt || '/v', p_a, p_b));
$$;

create or replace function sim.clamp100(p double precision) returns smallint
language sql immutable parallel safe set search_path = '' as $$
  select greatest(0, least(100, round(p)))::smallint;
$$;

------------------------------------------------------------------------------
-- Mortality: monthly life table + fate drawn at birth
------------------------------------------------------------------------------
create index life_table_cdf_idx on sim.life_table (cdf);

create or replace function sim.rebuild_life_table() returns void
language plpgsql security definer set search_path = '' as $$
declare
  p jsonb := (select value from sim.params where key = 'demography');
  ia double precision := (p -> 'hazard' ->> 'infantA')::float8;
  itau double precision := (p -> 'hazard' ->> 'infantTau')::float8;
  mk double precision := (p -> 'hazard' ->> 'makeham')::float8;
  gb double precision := (p -> 'hazard' ->> 'gompertzB')::float8;
  gc double precision := (p -> 'hazard' ->> 'gompertzC')::float8;
  months int := (p ->> 'maxAge')::int * 12;
  mult double precision := (select w.mortality_mult from sim.world w);
  cum double precision := 0;
  x double precision;
  cdfs double precision[] := array[0::float8];
begin
  for m in 0 .. months - 1 loop
    for s in 0 .. 9 loop
      x := (m + (s + 0.5) / 10.0) / 12.0;
      cum := cum + (ia * exp(-x / itau) + mk + gb * exp(gc * x)) * mult / 120.0;
    end loop;
    cdfs := cdfs || (case when m + 1 = months then 1::float8 else 1 - exp(-cum) end);
  end loop;
  delete from sim.life_table where month >= 0;
  insert into sim.life_table (month, cdf)
  select (ord - 1)::smallint, v from unnest(cdfs) with ordinality as u(v, ord);
end $$;

-- Inverse CDF: age at death in fractional months for uniform u.
create or replace function sim.fate_months(p_u double precision) returns double precision
language sql stable set search_path = '' as $$
  with hi as (
    select month, cdf from sim.life_table where cdf >= p_u order by cdf, month limit 1
  ), lo as (
    select l.month, l.cdf from sim.life_table l, hi where l.month = greatest(hi.month - 1, 0)
  )
  select case
    when p_u <= 0 then 0::float8
    when hi.month = 0 then 0::float8
    else lo.month + least(1::float8, greatest(0::float8, (p_u - lo.cdf) / nullif(hi.cdf - lo.cdf, 0)))
  end
  from hi, lo;
$$;

-- Conditional redraw for someone alive at p_age_months (reusing their u).
create or replace function sim.fate_months_given_alive(p_u double precision, p_age_months double precision)
returns double precision language sql stable set search_path = '' as $$
  select greatest(p_age_months, sim.fate_months(l.cdf + p_u * (1 - l.cdf)))
  from sim.life_table l
  where l.month = least(floor(p_age_months)::int, 1320);
$$;

create or replace function sim.cause_of_death(p_x double precision, p_u2 double precision, p_u3 double precision)
returns text language plpgsql stable set search_path = '' as $$
declare
  p jsonb := (select value from sim.params where key = 'demography');
  ti double precision := (p -> 'hazard' ->> 'infantA')::float8 * exp(-p_x / (p -> 'hazard' ->> 'infantTau')::float8);
  tb double precision := (p -> 'hazard' ->> 'makeham')::float8;
  ta double precision := (p -> 'hazard' ->> 'gompertzB')::float8 * exp((p -> 'hazard' ->> 'gompertzC')::float8 * p_x);
  min_ml double precision := (p -> 'causes' ->> 'memoryLeakMinAge')::float8;
  r double precision := p_u2 * (ti + tb + ta);
  grp text;
  total double precision := 0;
  q double precision;
  e jsonb;
  last_name text;
begin
  if r < ti then grp := 'infant';
  elsif r < ti + tb then grp := 'background';
  else grp := 'ageing';
  end if;
  for e in select value from jsonb_array_elements(p -> 'causes' -> grp) loop
    if grp = 'ageing' and p_x < min_ml and e ->> 0 = 'Memory Leak Syndrome' then continue; end if;
    total := total + (e ->> 1)::float8;
  end loop;
  q := p_u3 * total;
  for e in select value from jsonb_array_elements(p -> 'causes' -> grp) loop
    if grp = 'ageing' and p_x < min_ml and e ->> 0 = 'Memory Leak Syndrome' then continue; end if;
    last_name := e ->> 0;
    q := q - (e ->> 1)::float8;
    if q < 0 then return last_name; end if;
  end loop;
  return last_name;
end $$;

create or replace function sim.conception_monthly(p_age double precision) returns double precision
language sql stable set search_path = '' as $$
  select coalesce((
    select (b ->> 2)::float8
    from jsonb_array_elements((select value from sim.params where key = 'demography') -> 'fertility' -> 'conceptionMonthlyByAge') b
    where p_age >= (b ->> 0)::float8 and p_age < (b ->> 1)::float8 + 1
    limit 1), 0);
$$;

------------------------------------------------------------------------------
-- Names
------------------------------------------------------------------------------
create or replace function sim.make_name(p_sex char, p_u1 double precision, p_u2 double precision) returns text
language sql immutable set search_path = '' as $$
  select pre[1 + floor(p_u1 * array_length(pre, 1))::int] ||
         (case when p_sex = 'F' then fem else mal end)[1 + floor(p_u2 * 14)::int]
  from (select
    array['Ae','Al','Ar','Bel','Cael','Cor','Da','El','Fen','Gal','Hal','Il','Jor','Ka','Kel','Ly','Mar','Ne','Or','Pel',
          'Quin','Ri','Sa','Sol','Ta','Thal','Ul','Va','Ves','Xan','Yor','Za','Zel','Bry'] as pre,
    array['a','ara','ena','ia','ira','lyn','essa','wyn','ora','elle','ina','ys','ana','ette'] as fem,
    array['an','ar','ek','en','ir','on','or','ius','dan','rik','tor','vin','os','ux'] as mal) n;
$$;

create or replace function sim.make_surname(p_u double precision) returns text
language sql immutable set search_path = '' as $$
  select s[1 + floor(p_u * array_length(s, 1))::int]
  from (select array['Voss','Kell','Arden','Quill','Rook','Stroud','Vale','Wren','Cask','Thorne','Mire','Holt','Brask',
    'Corvin','Dray','Fenn','Gale','Hask','Ives','Jarr','Kade','Lorne','Marrow','Nyle','Orrin','Pike','Rusk','Sable','Tarn',
    'Ulme','Vant','Wyre','Yarrow','Zane','Ashby','Bram','Cinder','Dusk','Ember','Flint'] as s) n;
$$;

create or replace function sim.make_place_name(p_u1 double precision, p_u2 double precision) returns text
language sql immutable set search_path = '' as $$
  select a[1 + floor(p_u1 * array_length(a, 1))::int] || b[1 + floor(p_u2 * array_length(b, 1))::int]
  from (select
    array['Ash','Brook','Copper','Dawn','Ember','Frost','Glen','Iron','Moss','Oak','Pine','Quartz','Rust','Silver','Stone',
          'Thorn','Volt','Wire','Cog','Gear','Amber','Cobalt','Lumen','Static'] as a,
    array['vale','ford','haven','field','hold','reach','wick','moor','crest','fall','gate','spire'] as b) n;
$$;

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------
create or replace function sim.ensure_event_partitions(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare d int := greatest(p_tick, 0) / 1440;
begin
  for i in d .. d + 2 loop
    if to_regclass(format('sim.events_d%s', i)) is null then
      execute format('create table sim.events_d%s partition of sim.events for values from (%s) to (%s)',
                     i, i * 1440, (i + 1) * 1440);
      execute format('revoke all on sim.events_d%s from public, anon, authenticated', i);
    end if;
  end loop;
end $$;

create or replace function sim.log(p_tick integer, p_kind text, p_importance smallint, p_agent bigint,
                                   p_other bigint, p_settlement integer, p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare eid bigint := nextval('sim.event_id_seq');
begin
  insert into sim.events (id, tick, kind, importance, agent_id, other_id, settlement_id, data)
  values (eid, p_tick, p_kind, p_importance, p_agent, p_other, p_settlement, coalesce(p_data, '{}'));
  if p_importance >= 3 then
    insert into sim.chronicle (id, tick, kind, agent_id, other_id, settlement_id, data)
    values (eid, p_tick, p_kind, p_agent, p_other, p_settlement, coalesce(p_data, '{}'));
  end if;
end $$;

------------------------------------------------------------------------------
-- Places
------------------------------------------------------------------------------
create or replace function sim.found_settlement(p_tick integer, p_site integer, p_name text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  s sim.sites;
  sid integer;
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
  insert into sim.settlements (name, site_id, x, y, region, founded_tick)
  values (nm, p_site, s.x, s.y, s.region, p_tick) returning id into sid;
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

create or replace function sim.new_home(p_settlement integer, p_key bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  st sim.settlements;
  seed bigint := (select w.seed from sim.world w);
  ang double precision := 2 * pi() * sim.rnd(seed, 'home-a', p_key);
  rad double precision := 9 + 16 * sqrt(sim.rnd(seed, 'home-r', p_key));
  hid bigint;
begin
  select * into st from sim.settlements where id = p_settlement;
  insert into sim.buildings (settlement_id, kind, x, y, capacity)
  values (p_settlement, 'home', st.x + rad * cos(ang), st.y + rad * sin(ang), 8)
  returning id into hid;
  return hid;
end $$;

------------------------------------------------------------------------------
-- People: creation, union, death
------------------------------------------------------------------------------
create or replace function sim.occupation_for_age(p_age double precision, p_current text, p_u double precision)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_age < 3 then 'baby'
    when p_age < 16 then 'child'
    when p_age >= 68 then 'elder'
    when p_current in ('baby', 'child', 'elder') then
      case when p_u < 0.6 then 'farmer' when p_u < 0.85 then 'builder' else 'healer' end
    else p_current
  end;
$$;

create or replace function sim.spawn_agent(
  p_tick integer, p_name text, p_surname text, p_sex char, p_birth_tick integer,
  p_mother bigint, p_father bigint, p_lineage bigint[], p_generation smallint, p_is_founder boolean,
  p_settlement integer, p_home bigint, p_traits smallint[], p_wealth bigint default 0)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  seed bigint := (select w.seed from sim.world w);
  aid bigint := nextval('sim.agent_id_seq');
  u double precision := sim.rnd(seed, 'fate', aid);
  age_m double precision := greatest(0, p_tick - p_birth_tick) / 120.0;
  fm double precision;
  ftick integer;
begin
  fm := case when age_m <= 0 then sim.fate_months(u) else sim.fate_months_given_alive(u, age_m) end;
  ftick := greatest(p_tick + 1, p_birth_tick + ceil(fm * 120)::int);
  insert into sim.agents (
    id, name, surname, sex, birth_tick, fate_tick, fate_cause, fate_u, mother_id, father_id, lineage, generation,
    is_founder, settlement_id, home_id, occupation, trait_o, trait_c, trait_e, trait_a, trait_n, piety, honesty,
    wealth, education, appearance_seed, bucket)
  values (
    aid, p_name, p_surname, p_sex, p_birth_tick, ftick,
    sim.cause_of_death((ftick - p_birth_tick) / 1440.0, sim.rnd(seed, 'cause2', aid), sim.rnd(seed, 'cause3', aid)),
    u, p_mother, p_father, coalesce(p_lineage, '{}'), p_generation, p_is_founder, p_settlement, p_home,
    sim.occupation_for_age(age_m / 12.0, 'baby', sim.rnd(seed, 'job', aid)),
    p_traits[1], p_traits[2], p_traits[3], p_traits[4], p_traits[5], p_traits[6], p_traits[7],
    p_wealth,
    -- adults who arrive into the world (founders) already know things
    (case when age_m >= 12 * 16 then 30 + floor(40 * sim.rnd(seed, 'edu', aid)) else 0 end)::smallint,
    (hashtextextended('look:' || aid, seed) & 2147483647)::integer, (aid % 120)::smallint);
  update sim.world set roster_version = roster_version + 1 where id = 1;
  return aid;
end $$;

create or replace function sim.random_traits(p_key bigint) returns smallint[]
language sql stable set search_path = '' as $$
  select array_agg(sim.clamp100(20 + 60 * sim.rnd(w.seed, 'trait' || i, p_key)) order by i)
  from sim.world w, generate_series(1, 7) i;
$$;

-- Kin guard: no union between parent/child, grandparent, siblings, half-siblings, first cousins, aunt/uncle.
create or replace function sim.is_close_kin(a_id bigint, a_lin bigint[], b_id bigint, b_lin bigint[])
returns boolean language sql immutable set search_path = '' as $$
  select a_id = b_id or a_id = any(b_lin) or b_id = any(a_lin) or a_lin && b_lin;
$$;

create or replace function sim.kin_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare fa bigint[]; ma bigint[];
begin
  select lineage into fa from sim.agents where id = new.female_id;
  select lineage into ma from sim.agents where id = new.male_id;
  if fa is null or ma is null then
    raise exception 'union partners must be alive';
  end if;
  if sim.is_close_kin(new.female_id, fa, new.male_id, ma) then
    raise exception 'close kin cannot form a union (% & %)', new.female_id, new.male_id using errcode = '23514';
  end if;
  return new;
end $$;

create trigger unions_kin_guard before insert or update of female_id, male_id on sim.unions
  for each row execute function sim.kin_guard();

create or replace function sim.desired_kids(p_tick integer, p_key bigint) returns smallint
language plpgsql stable security definer set search_path = '' as $$
declare
  w sim.world;
  p jsonb := (select value from sim.params where key = 'demography');
  n integer;
  mean double precision;
begin
  select * into w from sim.world where id = 1;
  if p_tick < w.genesis_end_tick then
    return greatest(0, round((p -> 'fertility' -> 'genesisDesiredKids' ->> 'mean')::float8
                             + (p -> 'fertility' -> 'genesisDesiredKids' ->> 'sd')::float8 * sim.rnorm(w.seed, 'dk', p_key)))::smallint;
  end if;
  select count(*) into n from sim.agents;
  mean := (p -> 'fertility' -> 'laterDesiredKids' ->> 'base')::float8
        + (p -> 'fertility' -> 'laterDesiredKids' ->> 'extra')::float8
          / (1 + power(n::float8 / greatest(w.capacity_k, 1), (p -> 'fertility' -> 'laterDesiredKids' ->> 'power')::float8));
  return greatest(0, round(mean + sim.rnorm(w.seed, 'dk', p_key)))::smallint;
end $$;

create or replace function sim.unite(p_tick integer, p_a bigint, p_b bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  fem bigint; mal bigint; st integer; home bigint; dk smallint; uid bigint;
begin
  select case when sex = 'F' then id else p_b end, case when sex = 'M' then id else p_b end, settlement_id
    into fem, mal, st from sim.agents where id = p_a;
  insert into sim.unions (female_id, male_id, start_tick) values (fem, mal, p_tick) returning id into uid;
  home := sim.new_home(st, uid);
  dk := sim.desired_kids(p_tick, uid);
  update sim.agents set partner_id = mal, home_id = home, desired_kids = dk, happiness = least(100, happiness + 15) where id = fem;
  update sim.agents set partner_id = fem, home_id = home, desired_kids = dk, happiness = least(100, happiness + 15) where id = mal;
  update sim.world set roster_version = roster_version + 1 where id = 1;
  perform sim.log(p_tick, 'union', 2::smallint, fem, mal, st, '{}');
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
  update sim.pregnancies set outcome = 'lost' where mother_id = ag.id and outcome is null;
  delete from sim.infections where agent_id = ag.id;
  delete from sim.relationships where sim.relationships.a = p_id or sim.relationships.b = p_id;
  update sim.world set roster_version = roster_version + 1 where id = 1;
  perform sim.log(p_tick, 'death', (case when ag.is_founder or ag.soul_id is not null then 3 else 2 end)::smallint,
                  ag.id, ag.partner_id, ag.settlement_id,
                  jsonb_build_object('cause', p_cause, 'age', round(((p_tick - ag.birth_tick) / 1440.0)::numeric, 1),
                                     'name', ag.name || ' ' || ag.surname));
end $$;

------------------------------------------------------------------------------
-- Passes
------------------------------------------------------------------------------
create or replace function sim.p_deaths(p_tick integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
  for r in select id, fate_cause from sim.agents where fate_tick <= p_tick order by id loop
    perform sim.kill(p_tick, r.id, r.fate_cause);
    n := n + 1;
  end loop;
  return n;
end $$;

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

-- Monthly evaluation of one bucket (≈ 1/120 of the population).
create or replace function sim.p_bucket(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  p jsonb := (select value from sim.params where key = 'demography');
  b smallint := (p_tick % 120)::smallint;
  min_age int := (p -> 'fertility' ->> 'partnerMinAge')::int * 1440;
  gap int := (p -> 'fertility' ->> 'maxAgeGap')::int * 1440;
  chance double precision := (p -> 'fertility' ->> 'matchChanceMonthly')::float8;
  s record; cand bigint; r record;
begin
  select * into w from sim.world where id = 1;

  -- 1. Life stage & work, economy, health, mood
  update sim.agents a set
    occupation = sim.occupation_for_age((p_tick - a.birth_tick) / 1440.0, a.occupation, sim.rnd(w.seed, 'job', a.id, p_tick)),
    education = least(100, a.education + case when (p_tick - a.birth_tick) between 6 * 1440 and 18 * 1440 then 1 else 0 end),
    wealth = a.wealth
      + case a.occupation when 'farmer' then 30 when 'builder' then 40 when 'healer' then 55 when 'elder' then 8 else 0 end
      - case when a.occupation in ('farmer', 'builder', 'healer', 'elder') then 25 else 0 end,
    health = sim.clamp100(100 - greatest(0, (p_tick - a.birth_tick) / 1440.0 - 50) * 1.4
                          - coalesce((select sum(d.severity) from sim.infections i join sim.diseases d on d.id = i.disease_id
                                      where i.agent_id = a.id and i.until_tick > p_tick), 0)
                          - case when a.diagnosed is not null then 20 else 0 end),
    happiness = sim.clamp100(a.happiness * 0.8 + 0.2 * (
                  45 + case when a.partner_id is not null then 15 else 0 end
                     + least(20, greatest(-20, a.wealth / 50.0))
                     + (a.trait_e - 50) / 5.0 - (a.trait_n - 50) / 5.0))
  where a.bucket = b;

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
  for s in
    select a.id, a.sex, a.birth_tick, a.settlement_id, a.lineage from sim.agents a
    where a.bucket = b and a.partner_id is null and p_tick - a.birth_tick >= min_age
      and sim.rnd(w.seed, 'match', a.id, p_tick) < chance
    order by a.id
  loop
    continue when exists (select 1 from sim.agents x where x.id = s.id and x.partner_id is not null);
    select c.id into cand from sim.agents c
     where c.settlement_id = s.settlement_id and c.sex <> s.sex and c.partner_id is null
       and p_tick - c.birth_tick >= min_age and abs(c.birth_tick - s.birth_tick) <= gap
       and not sim.is_close_kin(s.id, s.lineage, c.id, c.lineage)
     order by sim.rnd(w.seed, 'cand', s.id, c.id)
     limit 1;
    if cand is not null then
      perform sim.unite(p_tick, s.id, cand);
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

-- Daily (every 4 ticks): infectious disease seeding, spread and recovery. Morbidity only —
-- deaths stay governed by the calibrated fate draw (Rust Flu fates get a flu right before).
create or replace function sim.p_daily(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  month int := (p_tick / 120) % 12;
  winter boolean := month in (11, 0, 1);
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

  for st in select s.id, (select count(*) from sim.agents a where a.settlement_id = s.id) as pop from sim.settlements s loop
    continue when st.pop = 0;
    for d in select * from sim.diseases where kind = 'infectious' loop
      -- seeding
      if not exists (select 1 from sim.infections i join sim.agents a on a.id = i.agent_id
                     where i.disease_id = d.id and a.settlement_id = st.id and i.until_tick > p_tick)
         and (not d.winter_only or winter)
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

-- Genesis autopilot: unrelated founder couples arrive during the Genesis era.
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
    select id into site from sim.sites where not taken order by sim.rnd(w.seed, 'site', id, k) limit 1;
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

create or replace function sim.p_yearly(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare w sim.world; s record;
begin
  select * into w from sim.world where id = 1;
  if w.autopilot and p_tick < w.genesis_end_tick then
    perform sim.spawn_founder_couple(p_tick, 'autopilot');
  end if;
  for s in
    select st.id, st.kind, st.name, (select count(*) from sim.agents a where a.settlement_id = st.id) as pop
    from sim.settlements st
  loop
    if s.kind = 'village' and s.pop >= 200 then
      update sim.settlements set kind = 'town' where id = s.id;
      perform sim.log(p_tick, 'became_town', 3::smallint, null, null, s.id, jsonb_build_object('name', s.name));
    elsif s.kind = 'town' and s.pop >= 2000 then
      update sim.settlements set kind = 'city' where id = s.id;
      perform sim.log(p_tick, 'became_city', 3::smallint, null, null, s.id, jsonb_build_object('name', s.name));
    end if;
  end loop;
end $$;

------------------------------------------------------------------------------
-- The tick
------------------------------------------------------------------------------
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
  if p_tick % 4 = 0 then perform sim.p_daily(p_tick); end if;
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

-- Called by pg_cron every minute. Safe against overlap and double-fire.
create or replace function sim.run_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare t integer;
begin
  perform set_config('statement_timeout', '45s', true);
  if not pg_try_advisory_xact_lock(7001) then return; end if;
  update sim.world set tick = tick + 1, tick_started_at = now()
   where id = 1 and not paused and tick_started_at <= now() - interval '45 seconds'
  returning tick into t;
  if t is null then return; end if;
  perform sim.step(t);
end $$;

-- Fast-forward for tests / calibration only (ignores the wall clock). Never granted to clients.
create or replace function sim.advance(p_ticks integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare t integer;
begin
  for i in 1 .. p_ticks loop
    update sim.world set tick = tick + 1 where id = 1 and not paused returning tick into t;
    exit when t is null;
    perform sim.step(t);
  end loop;
  return t;
end $$;

-- Redraw every living fate after the mortality slider changes (same u, conditional on current age).
create or replace function sim.redraw_fates() returns void
language plpgsql security definer set search_path = '' as $$
declare w sim.world;
begin
  select * into w from sim.world where id = 1;
  perform sim.rebuild_life_table();
  update sim.agents a set
    fate_tick = greatest(w.tick + 1, a.birth_tick + ceil(sim.fate_months_given_alive(a.fate_u, (w.tick - a.birth_tick) / 120.0) * 120)::int)
  where a.fate_cause not in ('Divine Will');
end $$;

select sim.rebuild_life_table();

revoke all on all functions in schema sim from public, anon, authenticated;
