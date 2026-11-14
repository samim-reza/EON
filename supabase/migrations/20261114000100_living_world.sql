-- A living world.
--
-- 1. The Creator made the first people and then stopped. After the years of creation nobody is made
--    again: everyone is born to a mother and a father, and a waiting soul waits for a baby.
-- 2. So the world has to renew itself the way people do. Someone with nobody to court at home looks
--    to the next village and moves for love, and a crowded village sends young families out to
--    settle new land.
-- 3. Every person is an individual: they are born with looks they inherit from their parents.
-- 4. The land is alive. Around every village there are woods that are cut and grow back, soil that
--    tires and is renewed, wild herds and the animals that hunt them, fish, and the village's own
--    herd. They feed people, and they answer to weather, fire and flood.

------------------------------------------------------------------------------
-- 1. The years of creation end
------------------------------------------------------------------------------
alter table sim.world add column creation_end_tick integer not null default 14400; -- the first 10 EON years
update sim.world set creation_end_tick = least(creation_end_tick, tick) where genesis_at is not null;

update sim.params set value = jsonb_set(value, '{genesis,creationYears}', '10') where key = 'demography';

create or replace function api.god_create_founder(p_name text, p_surname text, p_sex text, p_age integer, p_settlement integer)
returns bigint language plpgsql security definer set search_path = '' as $$
declare t integer := (select tick from sim.world); aid bigint;
begin
  perform app.assert_god();
  perform app.hit('god:founder', 30, interval '1 hour');
  if t >= (select creation_end_tick from sim.world) then
    raise exception 'The first people have been made. Everyone after them is born';
  end if;
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

-- No family arrives from nowhere any more. A waiting soul becomes a young child who has no soul
-- yet, or waits for the next baby to be born.
drop function if exists sim.arriving_family(integer, bigint);
drop function if exists sim.arrivals_today(integer);

create or replace function app.find_body(p_soul bigint, p_tick integer) returns boolean
language plpgsql security definer set search_path = '' as $$
declare child bigint := sim.unclaimed_child(p_tick);
begin
  if child is null then return false; end if;
  return app.give_child(p_soul, child, 'autopilot');
end $$;

------------------------------------------------------------------------------
-- 2. Looks: every person is born looking like their parents, and like nobody else
------------------------------------------------------------------------------
-- [skin 0-4, hair 0-4, curl 0-2, eyes 0-3, height 0-100, build 0-100]
alter table sim.agents add column looks smallint[];

create or replace function sim.draw_looks(p_id bigint, p_mother bigint, p_father bigint) returns smallint[]
language plpgsql stable security definer set search_path = '' as $$
declare
  seed bigint := (select w.seed from sim.world w where w.id = 1);
  m smallint[] := (select a.looks from sim.agents a where a.id = p_mother);
  f smallint[] := (select a.looks from sim.agents a where a.id = p_father);
  own smallint[] := array[
    floor(5 * sim.rnd(seed, 'look-skin', p_id)), floor(5 * sim.rnd(seed, 'look-hair', p_id)),
    floor(3 * sim.rnd(seed, 'look-curl', p_id)), floor(4 * sim.rnd(seed, 'look-eyes', p_id)),
    sim.clamp100(50 + 18 * sim.rnorm(seed, 'look-tall', p_id)), sim.clamp100(50 + 18 * sim.rnorm(seed, 'look-build', p_id))]::smallint[];
  r double precision;
  got smallint[] := own;
begin
  if m is null and f is null then return own; end if;
  m := coalesce(m, f);
  f := coalesce(f, m);
  -- Skin, height and build blend. Hair and eyes come from one parent or the other, and now and
  -- then from someone further back.
  got[1] := greatest(0, least(4, round((m[1] + f[1]) / 2.0 + (sim.rnd(seed, 'look-skin-d', p_id) - 0.5) * 1.2)))::smallint;
  for i in 2..4 loop
    r := sim.rnd(seed, 'look-from', p_id, i);
    got[i] := case when r < 0.46 then m[i] when r < 0.92 then f[i] else own[i] end;
  end loop;
  got[5] := sim.clamp100((m[5] + f[5]) / 2.0 + 10 * sim.rnorm(seed, 'look-tall-d', p_id));
  got[6] := sim.clamp100((m[6] + f[6]) / 2.0 + 12 * sim.rnorm(seed, 'look-build-d', p_id));
  return got;
end $$;

create or replace function sim.set_looks() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.looks is null then new.looks := sim.draw_looks(new.id, new.mother_id, new.father_id); end if;
  return new;
end $$;

create trigger agents_looks before insert on sim.agents for each row execute function sim.set_looks();

-- People already alive get their looks oldest generation first, so children take after their parents.
do $$
declare g smallint;
begin
  for g in select distinct a.generation from sim.agents a order by 1 loop
    update sim.agents a set looks = sim.draw_looks(a.id, a.mother_id, a.father_id) where a.generation = g and a.looks is null;
  end loop;
end $$;

------------------------------------------------------------------------------
-- 3. Love and land: how a closed world keeps renewing itself
------------------------------------------------------------------------------
-- A couple from two villages makes its home in the smaller one, where there is room to build.
-- Young children come along.
create or replace function sim.unite(p_tick integer, p_a bigint, p_b bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a sim.agents; b sim.agents; mover sim.agents;
  fem bigint; mal bigint; st integer; home bigint; dk smallint; uid bigint;
begin
  select * into a from sim.agents where id = p_a;
  select * into b from sim.agents where id = p_b;
  if a.sex = 'F' then fem := a.id; mal := b.id; else fem := b.id; mal := a.id; end if;
  st := a.settlement_id;
  if a.settlement_id <> b.settlement_id then
    if (select count(*) from sim.agents x where x.settlement_id = b.settlement_id)
       < (select count(*) from sim.agents x where x.settlement_id = a.settlement_id) then
      st := b.settlement_id;
    end if;
    if st = a.settlement_id then mover := b; else mover := a; end if;
  end if;
  insert into sim.unions (female_id, male_id, start_tick) values (fem, mal, p_tick) returning id into uid;
  home := sim.new_home(st, uid);
  dk := sim.desired_kids(p_tick, uid);
  update sim.agents set partner_id = mal, home_id = home, settlement_id = st, desired_kids = dk, happiness = least(100, happiness + 15) where id = fem;
  update sim.agents set partner_id = fem, home_id = home, settlement_id = st, desired_kids = dk, happiness = least(100, happiness + 15) where id = mal;
  if mover.id is not null then
    update sim.agents c set settlement_id = st, home_id = home
     where (c.mother_id = mover.id or c.father_id = mover.id) and c.partner_id is null
       and p_tick - c.birth_tick < 16 * 1440 and c.settlement_id = mover.settlement_id;
    perform sim.log(p_tick, 'moved', 1::smallint, mover.id, case when mover.id = a.id then b.id else a.id end, st,
                    jsonb_build_object('why', 'love', 'from', (select s.name from sim.settlements s where s.id = mover.settlement_id)));
  end if;
  update sim.world set roster_version = roster_version + 1 where id = 1;
  perform sim.log(p_tick, 'union', 2::smallint, fem, mal, st, '{}');
end $$;

-- Someone with nobody to court in their own village looks to the others, nearest first.
create or replace function sim.p_far_love(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  p jsonb := (select value from sim.params where key = 'demography');
  b smallint := (p_tick % 120)::smallint;
  min_age int := (p -> 'fertility' ->> 'partnerMinAge')::int * 1440;
  gap int := (p -> 'fertility' ->> 'maxAgeGap')::int * 1440;
  chance double precision := (p -> 'fertility' ->> 'matchChanceMonthly')::float8 * 0.6;
  q record; cand bigint;
begin
  select * into w from sim.world where id = 1;
  for q in
    select a.id, a.sex, a.birth_tick, a.settlement_id, a.lineage, s.x, s.y
    from sim.agents a join sim.settlements s on s.id = a.settlement_id
    where a.bucket = b and a.partner_id is null and p_tick - a.birth_tick >= min_age
      and sim.rnd(w.seed, 'farmatch', a.id, p_tick) < chance
    order by a.id
  loop
    continue when exists (select 1 from sim.agents x where x.id = q.id and x.partner_id is not null);
    continue when exists (select 1 from app.choices ch where ch.agent_id = q.id and ch.kind = 'love' and ch.status in ('open', 'asked', 'chosen'));
    continue when exists (
      select 1 from sim.agents c
      where c.settlement_id = q.settlement_id and c.sex <> q.sex and c.partner_id is null
        and p_tick - c.birth_tick >= min_age and abs(c.birth_tick - q.birth_tick) <= gap
        and not sim.is_close_kin(q.id, q.lineage, c.id, c.lineage));
    select c.id into cand
    from sim.agents c join sim.settlements s2 on s2.id = c.settlement_id
    where c.settlement_id <> q.settlement_id and c.sex <> q.sex and c.partner_id is null
      and p_tick - c.birth_tick >= min_age and abs(c.birth_tick - q.birth_tick) <= gap
      and not sim.is_close_kin(q.id, q.lineage, c.id, c.lineage)
      and not exists (select 1 from app.choices ch where ch.agent_id = c.id and ch.kind = 'love' and ch.status in ('open', 'asked', 'chosen'))
    order by sqrt((s2.x - q.x) ^ 2 + (s2.y - q.y) ^ 2) * (0.6 + 0.8 * sim.rnd(w.seed, 'farcand', q.id, c.id))
    limit 1;
    if cand is not null then
      if sim.will(q.id, p_tick) is not null or sim.will(cand, p_tick) is not null then
        perform sim.court(p_tick, q.id, cand);
      else
        perform sim.unite(p_tick, q.id, cand);
      end if;
    end if;
  end loop;
end $$;

-- Young families leave a crowded village for good land nearby and found a new one. A family
-- with a soul in it is not uprooted: that life is its player's to steer.
create or replace function sim.send_pioneers(p_tick integer, p_from integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world; src sim.settlements;
  site integer; st integer; r record; hid bigint; moved integer;
  families integer := 0; people integer := 0;
begin
  select * into w from sim.world where id = 1;
  select * into src from sim.settlements where id = p_from;
  if not found then return null; end if;
  if (select count(*) from sim.unions u
        join sim.agents f on f.id = u.female_id join sim.agents m on m.id = u.male_id
       where u.end_tick is null and f.settlement_id = p_from and p_tick - f.birth_tick < 40 * 1440
         and f.soul_id is null and m.soul_id is null
         and not exists (select 1 from sim.agents k where (k.mother_id = f.id or k.father_id = m.id) and k.soul_id is not null)) < 2 then
    return null;
  end if;
  select g.id into site from sim.sites g
  where not g.taken
  order by sqrt((g.x - src.x) ^ 2 + (g.y - src.y) ^ 2) / greatest(sim.habitability(g.biome, g.river, g.coast), 0.01)
           * (0.7 + 0.6 * sim.rnd(w.seed, 'pioneer-site', g.id, p_tick))
  limit 1;
  if site is null then return null; end if;
  st := sim.found_settlement(p_tick, site, null);
  for r in
    select u.id as uid, u.female_id, u.male_id
    from sim.unions u join sim.agents f on f.id = u.female_id join sim.agents m on m.id = u.male_id
    where u.end_tick is null and f.settlement_id = p_from and p_tick - f.birth_tick < 40 * 1440
      and f.soul_id is null and m.soul_id is null
      and not exists (select 1 from sim.agents k where (k.mother_id = f.id or k.father_id = m.id) and k.soul_id is not null)
    order by sim.rnd(w.seed, 'pioneer', u.id, p_tick) limit 4
  loop
    hid := sim.new_home(st, 3000000 + r.uid);
    update sim.agents c set settlement_id = st, home_id = hid
     where c.id in (r.female_id, r.male_id)
        or ((c.mother_id = r.female_id or c.father_id = r.male_id) and c.partner_id is null
            and p_tick - c.birth_tick < 16 * 1440 and c.settlement_id = p_from);
    get diagnostics moved = row_count;
    people := people + moved;
    families := families + 1;
  end loop;
  update sim.world set roster_version = roster_version + 1 where id = 1;
  perform sim.log(p_tick, 'pioneers', 2::smallint, null, null, st,
                  jsonb_build_object('from', src.name, 'fromId', p_from, 'families', families, 'people', people,
                                     'name', (select s.name from sim.settlements s where s.id = st)));
  return st;
end $$;

create or replace function sim.p_yearly(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare w sim.world; s record;
begin
  select * into w from sim.world where id = 1;
  -- Only in the years of creation does the Creator send people into the world.
  if w.autopilot and p_tick < w.creation_end_tick then
    perform sim.spawn_founder_couple(p_tick, 'autopilot');
  end if;
  for s in
    select st.id, st.kind, st.name, (select count(*) from sim.agents a where a.settlement_id = st.id) as pop
    from sim.settlements st order by st.id
  loop
    if s.kind = 'village' and s.pop >= 200 then
      update sim.settlements set kind = 'town' where id = s.id;
      perform sim.log(p_tick, 'became_town', 3::smallint, null, null, s.id, jsonb_build_object('name', s.name));
    elsif s.kind = 'town' and s.pop >= 2000 then
      update sim.settlements set kind = 'city' where id = s.id;
      perform sim.log(p_tick, 'became_city', 3::smallint, null, null, s.id, jsonb_build_object('name', s.name));
    end if;
    if s.pop >= 60 and sim.rnd(w.seed, 'pioneers', s.id, p_tick) < 0.5 then
      perform sim.send_pioneers(p_tick, s.id);
    end if;
  end loop;
end $$;

------------------------------------------------------------------------------
-- 4. The land around every village
------------------------------------------------------------------------------
alter table sim.settlements
  add column woods          real,     -- share of the land under trees, 0 to 1
  add column richness       real,     -- how rich the soil is, 0 to 1 (0.6 is ordinary land)
  add column game           real,     -- head of wild grazing animals
  add column beasts         real,     -- the animals that hunt them
  add column fish           real,
  add column herd           real,     -- the village's own animals, once herding is known
  add column eco_event_tick integer not null default -100000;

-- What lives in each kind of country. Real animals, because this is a real land.
create or replace function sim.fauna(p_biome text, out grazer text, out hunter text, out herd text, out bird text, out tree text,
                                     out woods_k real, out game_k real, out pasture real)
language sql immutable parallel safe set search_path = '' as $$
  select f.grazer, f.hunter, f.herd, f.bird, f.tree, f.woods_k::real, f.game_k::real, f.pasture::real
  from (values
    ('grassland',  'deer',       'wolves',   'goats',    'cranes',   'oak',     0.25, 260, 1.0),
    ('forest',     'deer',       'wolves',   'pigs',     'geese',    'beech',   0.85, 200, 0.6),
    ('savanna',    'antelope',   'lions',    'cattle',   'storks',   'acacia',  0.20, 320, 1.0),
    ('rainforest', 'boar',       'bears',    'pigs',     'herons',   'cedar',   0.95, 150, 0.4),
    ('jungle',     'tapirs',     'jaguars',  'pigs',     'parrots',  'fig',     0.95, 150, 0.3),
    ('taiga',      'elk',        'bears',    'reindeer', 'geese',    'pine',    0.80, 140, 0.5),
    ('mountain',   'wild goats', 'lynx',     'goats',    'eagles',   'fir',     0.35, 90,  0.6),
    ('desert',     'gazelles',   'jackals',  'camels',   'falcons',  'palm',    0.03, 40,  0.3),
    ('tundra',     'reindeer',   'wolves',   'reindeer', 'geese',    'birch',   0.05, 110, 0.5),
    ('ice',        'seals',      'bears',    'dogs',     'gulls',    'willow',  0.00, 30,  0.0)
  ) f(biome, grazer, hunter, herd, bird, tree, woods_k, game_k, pasture)
  where f.biome in (p_biome, 'grassland')
  order by (f.biome = p_biome) desc limit 1;
$$;

create or replace function sim.fish_room(p_river real, p_coast boolean) returns double precision
language sql immutable parallel safe set search_path = '' as $$
  select 60 + 400 * coalesce(p_river, 0) + case when p_coast then 600 else 0 end;
$$;

-- Untouched country: what a place holds before anyone has lived off it.
create or replace function sim.wild_start(p_settlement integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s sim.settlements; f record;
  herding boolean := exists (select 1 from sim.discoveries d where d.id = 'animals' and d.found_tick is not null);
begin
  select * into s from sim.settlements where id = p_settlement;
  select * into f from sim.fauna(s.biome);
  update sim.settlements t set
    woods = f.woods_k * 0.92,
    richness = least(1, 0.55 + 0.25 * s.river + case when s.biome in ('forest', 'grassland') then 0.05 when s.biome in ('desert', 'ice', 'tundra') then -0.2 else 0 end),
    game = f.game_k * 0.8,
    beasts = f.game_k / 40 * 0.6,
    fish = sim.fish_room(s.river, s.coast) * 0.8,
    herd = case when herding then s.pop * 1.5 * f.pasture else 0 end
  where t.id = p_settlement;
end $$;

select sim.wild_start(s.id) from sim.settlements s;

-- Runs once per EON day, after the weather. Every rate below is per year, divided by 360 days.
create or replace function sim.p_nature(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  month int := (p_tick / 120) % 12;
  growing boolean := month <= 5;
  herding boolean := exists (select 1 from sim.discoveries d where d.id = 'animals' and d.found_tick is not null);
  farming boolean := exists (select 1 from sim.discoveries d where d.id = 'farming' and d.found_tick is not null);
  s sim.settlements; f record;
  v_woods double precision; v_rich double precision; v_game double precision; v_beasts double precision;
  v_fish double precision; v_herd double precision; v_crop double precision;
  woods_cap double precision; game_cap double precision; fish_cap double precision; herd_cap double precision;
  warm double precision; habitat double precision; r double precision; r2 double precision; lost double precision;
  high double precision; low double precision;
  event text; severity int; data jsonb; victim bigint;
  best_id integer; best_severity int := 0; best_data jsonb;
begin
  select * into w from sim.world where id = 1;
  for s in select st.* from sim.settlements st order by st.id loop
    if s.woods is null then
      perform sim.wild_start(s.id);
      continue;
    end if;
    select * into f from sim.fauna(s.biome);
    high := coalesce(s.wx_high, 18); low := coalesce(s.wx_low, 8);
    warm := sim.smooth(2, 14, (high + low) / 2);
    v_crop := s.crop;

    -- Trees grow back slowly, and faster where it is warm and wet. People clear fields and burn
    -- wood, twice as much when it is cold.
    woods_cap := f.woods_k * (1 - least(0.7, s.pop * 0.0004));
    v_woods := s.woods
      + (0.12 / 360) * greatest(s.woods, 0.02) * (1 - s.woods / greatest(woods_cap, 0.01)) * warm * least(1, s.soil / 0.25)
      - s.pop * (0.00024 / 360) * (case when high < 8 then 2 else 1 end);
    v_woods := greatest(0, least(1, v_woods));

    -- The village herd: it grows where there is pasture, and suffers in deep cold and drought.
    if herding and s.pop > 0 then
      herd_cap := s.pop * 3 * f.pasture;
      v_herd := case when s.herd < 1 then least(herd_cap, greatest(2, s.pop * 0.3))
                     else s.herd + (0.35 / 360) * s.herd * (1 - s.herd / greatest(herd_cap, 1)) end;
      if low < -15 or s.wx_kind = 'blizzard' then v_herd := v_herd * 0.97; end if;
      if s.soil < 0.08 then v_herd := v_herd * 0.99; end if;
    else
      v_herd := case when s.pop = 0 then 0 else s.herd end;
    end if;

    -- Soil: crops take from it, fallen leaves, dung and river silt give back.
    v_rich := s.richness
      - (case when farming and growing then (0.035 / 360) * least(1.5, s.pop / 60.0) else 0 end)
      + (0.02 / 360) * (0.3 + v_woods)
      + (0.01 / 360) * least(1, v_herd / greatest(s.pop, 1))
      + (case when s.wx_wet_days >= 2 and s.river > 0 then 0.01 else 0 end);
    v_rich := greatest(0.15, least(1, v_rich));

    -- Wild herds need cover and grass. Hunters and predators both take from them.
    habitat := case when f.woods_k >= 0.5 then least(1, v_woods / f.woods_k) else 1 end;
    game_cap := greatest(4, f.game_k * (0.3 + 0.7 * habitat) * (0.6 + 0.4 * least(1, s.soil / 0.3)) * (1 - least(0.6, s.pop / 1500.0)));
    v_game := s.game + (0.5 / 360) * s.game * (1 - s.game / game_cap)
      - s.beasts * (14.0 / 360)
      - least(s.game * 0.3, s.pop * 1.2) / 360;
    v_game := greatest(least(2, game_cap), v_game); -- strays always wander in from further off

    -- Predators follow the herds, and keep away from a busy town.
    v_beasts := s.beasts
      + (0.4 / 360) * s.beasts * (least(3, v_game / greatest(s.beasts * 40, 1)) - 1)
      - s.beasts * least(0.5, s.pop / 400.0) / 360;
    if v_beasts < 0.5 and v_game > 0.3 * game_cap then v_beasts := v_beasts + 0.01; end if;
    v_beasts := greatest(0, least(v_beasts, greatest(game_cap / 20, 1)));

    -- Fish.
    fish_cap := sim.fish_room(s.river, s.coast);
    v_fish := s.fish + (0.8 / 360) * s.fish * (1 - s.fish / fish_cap) - least(s.fish * 0.35, s.pop * 2.0) / 360;
    v_fish := greatest(5, v_fish);

    -- What happened today, if anything. Grave things can follow each other within a month;
    -- small ones are told a few times a year at most.
    event := null; severity := 0; data := '{}'; victim := null;
    r := sim.rnd(w.seed, 'nature', s.id, p_tick);
    r2 := sim.rnd(w.seed, 'nature2', s.id, p_tick);
    if v_woods > 0.15 and s.soil < 0.12 and high >= 30 and s.wx_rain < 0.2 and r < 0.03 then
      event := 'wildfire'; severity := 5;
    elsif s.wx_kind = 'thunderstorm' and v_woods > 0.3 and s.soil < 0.2 and r < 0.04 then
      event := 'wildfire'; severity := 5;
    elsif s.pop > 0 and v_herd >= 4 and v_beasts >= 2 and (v_game < 0.35 * game_cap or low < -5) and r < 0.02 then
      event := 'raid'; severity := 4;
    elsif s.pop > 0 and v_beasts >= 2 and v_game < 0.25 * game_cap and r < 0.006 then
      event := 'attack'; severity := 4;
    elsif s.pop > 0 and farming and month between 2 and 5 and s.biome in ('savanna', 'grassland', 'desert')
          and high >= 28 and v_crop > 20 and r < 0.004 then
      event := 'locusts'; severity := 4;
    elsif s.pop > 0 and farming and s.wx_wet_days >= 2 and s.river > 0 then
      event := 'silt'; severity := 2;
    elsif s.pop > 0 and month in (7, 8) and s.river >= 0.2 and r < 0.03 then
      event := 'fish_run'; severity := 2;
    elsif s.pop > 0 and v_game < 0.15 * game_cap and r < 0.02 then
      event := 'scarce'; severity := 2;
    elsif s.pop > 0 and f.woods_k >= 0.2 and v_woods < 0.3 * f.woods_k and r < 0.02 then
      event := 'thin_woods'; severity := 2;
    elsif s.pop > 0 and farming and v_rich < 0.35 and r < 0.02 then
      event := 'tired_soil'; severity := 2;
    elsif s.pop >= 4 and v_game > 0.6 * game_cap and r < 0.02 then
      event := 'hunt'; severity := 1;
    elsif s.pop > 0 and s.temp_swing >= 6 and month = 0 and r < 0.03 then
      event := 'birds_return'; severity := 1;
    elsif s.pop > 0 and s.temp_swing >= 6 and month = 7 and r < 0.03 then
      event := 'birds_leave'; severity := 1;
    end if;
    if event is not null and p_tick - s.eco_event_tick < (case when severity >= 4 then 120 else 480 end) then
      event := null; severity := 0;
    end if;

    case event
      when 'wildfire' then
        lost := 0.25 + 0.3 * r2;
        v_woods := v_woods * (1 - lost);
        v_game := v_game * 0.7;
        v_rich := least(1, v_rich + 0.04); -- ash feeds the soil
        v_crop := v_crop * 0.9;
        update sim.agents set wealth = wealth - wealth / 20 where settlement_id = s.id and wealth > 0;
        data := jsonb_build_object('kind', event, 'tree', f.tree, 'lost', round((lost * 100)::numeric));
      when 'raid' then
        lost := greatest(1, round(v_herd * (0.05 + 0.1 * r2)));
        v_herd := greatest(0, v_herd - lost);
        data := jsonb_build_object('kind', event, 'beast', f.hunter, 'herd', f.herd, 'lost', lost);
      when 'attack' then
        -- As with the weather, an animal can only bring forward a death already near.
        select a.id into victim from sim.agents a
        where a.settlement_id = s.id and a.fate_cause <> 'Divine Will' and a.fate_tick - p_tick between 9 and 360
          and p_tick - a.birth_tick >= 10 * 1440
        order by sim.rnd(w.seed, 'prey', a.id, p_tick) limit 1;
        if victim is not null then
          update sim.agents set fate_tick = p_tick + 1 + floor(6 * r2)::int, fate_cause = 'Animal Attack' where id = victim;
        end if;
        v_beasts := v_beasts * 0.8; -- people drive them off
        data := jsonb_build_object('kind', event, 'beast', f.hunter, 'hurt', victim is not null);
      when 'locusts' then
        v_crop := v_crop * 0.6;
        data := jsonb_build_object('kind', event);
      when 'fish_run' then
        v_fish := least(fish_cap, v_fish + 0.3 * fish_cap);
        data := jsonb_build_object('kind', event);
      when 'hunt' then
        v_game := v_game - least(v_game * 0.03, 6);
        update sim.agents set happiness = least(100, happiness + 3) where settlement_id = s.id;
        data := jsonb_build_object('kind', event, 'animal', f.grazer);
      when 'scarce' then data := jsonb_build_object('kind', event, 'animal', f.grazer);
      when 'thin_woods' then data := jsonb_build_object('kind', event, 'tree', f.tree);
      when 'birds_return', 'birds_leave' then data := jsonb_build_object('kind', event, 'bird', f.bird);
      when 'silt', 'tired_soil' then data := jsonb_build_object('kind', event);
      else null;
    end case;

    update sim.settlements t set woods = v_woods, richness = v_rich, game = v_game, beasts = v_beasts, fish = v_fish, herd = v_herd,
           crop = v_crop, eco_event_tick = case when event is null then t.eco_event_tick else p_tick end
    where t.id = s.id;

    -- At harvest the land has its say: rich soil stretches the crop, and meat, fish and milk fill
    -- the gaps. A small village lives well off the wild; a town has to farm.
    if p_tick % 1440 = 720 and s.pop > 0 then
      update sim.settlements t set food = greatest(0.4, least(1.5,
          t.food * (0.7 + 0.5 * v_rich)
          + least(0.12, 0.12 * v_game / (s.pop * 6.0 + 1))
          + least(0.15, 0.15 * v_fish / (s.pop * 4.0 + 1))
          + least(0.12, 0.12 * v_herd / (s.pop * 1.5 + 1))
          - 0.15))
      where t.id = s.id;
      update sim.settlements t set price_idx = greatest(0.7, least(2.5, 1 / greatest(t.food, 0.4))) where t.id = s.id;
    end if;

    if severity >= 4 then
      perform sim.log(p_tick, 'nature', 2::smallint, victim, null, s.id, data);
    elsif severity > best_severity or (severity > 0 and severity = best_severity and r2 < 0.5) then
      best_id := s.id; best_severity := severity; best_data := data;
    end if;
  end loop;

  -- Of the small things, the feed hears one a day.
  if best_id is not null then
    perform sim.log(p_tick, 'nature', 1::smallint, null, null, best_id, best_data);
  end if;
end $$;

-- The Creator's hand on the land.
create or replace function api.god_nature(p_settlement integer, p_act text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  t integer := (select tick from sim.world);
  s sim.settlements; f record; data jsonb;
begin
  perform app.assert_god();
  perform app.hit('god:nature', 60, interval '1 hour');
  select * into s from sim.settlements where id = p_settlement;
  if not found then raise exception 'unknown settlement'; end if;
  if s.woods is null then
    perform sim.wild_start(p_settlement);
    select * into s from sim.settlements where id = p_settlement;
  end if;
  select * into f from sim.fauna(s.biome);
  case p_act
    when 'bless' then
      update sim.settlements set richness = least(1, richness + 0.2), game = greatest(game, f.game_k * 0.8),
             fish = greatest(fish, sim.fish_room(river, coast) * 0.8), herd = herd * 1.2, woods = greatest(woods, f.woods_k * 0.6)
       where id = p_settlement;
    when 'rain' then
      update sim.settlements set soil = greatest(soil, 0.8) where id = p_settlement;
    when 'wildfire' then
      update sim.settlements set woods = woods * 0.6, game = game * 0.7, richness = least(1, richness + 0.04) where id = p_settlement;
    when 'locusts' then
      update sim.settlements set crop = crop * 0.5 where id = p_settlement;
    when 'beasts' then
      update sim.settlements set beasts = beasts + 4 where id = p_settlement;
    else raise exception 'unknown act';
  end case;
  data := jsonb_build_object('kind', case p_act when 'bless' then 'blessing' else p_act end, 'by', 'creator',
                             'beast', f.hunter, 'tree', f.tree);
  update sim.settlements set eco_event_tick = t where id = p_settlement;
  perform sim.log(t, 'nature', 2::smallint, null, null, p_settlement, data);
  perform app.audit('god', 'nature', p_settlement::text, jsonb_build_object('act', p_act));
  return (select jsonb_build_object('woods', x.woods, 'richness', x.richness, 'game', x.game, 'beasts', x.beasts, 'fish', x.fish, 'herd', x.herd, 'soil', x.soil)
          from sim.settlements x where x.id = p_settlement);
end $$;

------------------------------------------------------------------------------
-- 5. What the world tells
------------------------------------------------------------------------------
-- First times are history: the first fire in the woods, the first village founded by its own people.
create or replace function sim.log(p_tick integer, p_kind text, p_importance smallint, p_agent bigint,
                                   p_other bigint, p_settlement integer, p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare
  eid bigint := nextval('sim.event_id_seq');
  imp smallint := p_importance;
  body jsonb := coalesce(p_data, '{}');
begin
  if imp < 3 and p_kind in ('birth', 'death', 'union', 'wedding', 'outbreak', 'weather', 'harvest', 'built',
                            'friends', 'quarrel', 'fight', 'theft', 'judged', 'reconciled', 'nature', 'pioneers')
     and not exists (select 1 from sim.chronicle c where c.kind = p_kind
                     and (p_kind not in ('weather', 'nature') or c.data ->> 'kind' = body ->> 'kind')
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
    when p_kind in ('weather', 'harvest', 'wedding', 'built', 'nature', 'pioneers') and p_imp >= 2 and not crowded then job := 'story'; rank := 4;
    when p_kind in ('fight', 'judged', 'reconciled') and not crowded then job := 'story'; rank := 5;
    when p_kind = 'quarrel' and p_imp >= 3 then job := 'story'; rank := 5;
    when p_kind = 'prayer' and not crowded and not coalesce((p_data ->> 'soul')::boolean, false) then job := 'prayer'; rank := 6;
    else return;
  end case;
  insert into llm.jobs (kind, priority, tick, event_id, event_tick, agent_id, other_id, settlement_id, context)
  values (job, rank, p_tick, p_id, p_tick, p_agent, p_other, p_settlement, jsonb_build_object('event', p_kind, 'data', p_data));
end $$;

-- The map: each village with its country and what lives there.
create or replace function api.pub_geo() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'seed', (select seed::text from sim.world),
    'settlements', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', s.id, 'name', s.name, 'kind', s.kind, 'x', s.x, 'y', s.y, 'region', s.region, 'founded', s.founded_tick, 'food', round(s.food::numeric, 2),
        'pop', (select count(*) from sim.agents a where a.settlement_id = s.id),
        'biome', s.biome,
        'land', case when s.woods is not null then jsonb_build_array(round(s.woods::numeric, 2), round(s.richness::numeric, 2),
                     round(s.game::numeric), round(s.beasts::numeric), round(s.fish::numeric), round(s.herd::numeric)) end)) order by s.id)
      from sim.settlements s), '[]'),
    'buildings', coalesce((select jsonb_agg(jsonb_build_array(b.id, b.settlement_id, b.kind, round(b.x::numeric, 1), round(b.y::numeric, 1)) order by b.id)
      from sim.buildings b where b.built_tick is not null), '[]'));
$$;

-- The roster carries each person's skin tone, so the figure on the map is the person on their page.
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
      order by a.id), '[]'),
    'skin', coalesce(jsonb_agg(coalesce(a.looks[1], 2) order by a.id), '[]'))
  from sim.agents a;
$$;

-- A person's page shows their looks.
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
      'diagnosed', a.diagnosed, 'homeId', a.home_id, 'looks', to_jsonb(a.looks),
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

-- A mind knows what it looks like and what lives around it.
create or replace function llm.mind_facts(j llm.jobs) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  t integer := (select w.tick from sim.world w where w.id = 1);
  me sim.agents; c app.choices; pr app.prayers;
begin
  select * into me from sim.agents x where x.id = j.agent_id;
  if not found then return '{}'; end if;
  if j.choice_id is not null then select * into c from app.choices x where x.id = j.choice_id; end if;
  if j.prayer_id is not null then select * into pr from app.prayers x where x.id = j.prayer_id; end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'me', jsonb_build_object('name', me.name || ' ' || me.surname, 'sex', me.sex, 'age', (t - me.birth_tick) / 1440,
                             'work', me.occupation, 'health', me.health, 'mood', me.happiness, 'wealth', me.wealth,
                             'faith', me.piety, 'honesty', me.honesty, 'diagnosed', me.diagnosed, 'looks', to_jsonb(me.looks),
                             'temper', jsonb_build_object('o', me.trait_o, 'c', me.trait_c, 'e', me.trait_e, 'a', me.trait_a, 'n', me.trait_n)),
    'family', jsonb_strip_nulls(jsonb_build_object(
      'mother', (select p.name || case when p.alive then '' else ' (died)' end from sim.people p where p.id = me.mother_id),
      'father', (select p.name || case when p.alive then '' else ' (died)' end from sim.people p where p.id = me.father_id),
      'partner', (select x.name from sim.agents x where x.id = me.partner_id),
      'children', (select jsonb_agg(p.name || case when p.alive then '' else ' (died)' end order by p.birth_tick)
                   from sim.people p where p.mother_id = me.id or p.father_id = me.id),
      'friends', (select jsonb_agg(x.name) from sim.relationships l join sim.agents x on x.id = case when l.a = me.id then l.b else l.a end
                  where (l.a = me.id or l.b = me.id) and l.kind = 'friend'),
      'rivals', (select jsonb_agg(x.name) from sim.relationships l join sim.agents x on x.id = case when l.a = me.id then l.b else l.a end
                 where (l.a = me.id or l.b = me.id) and l.kind = 'rival'))),
    'place', (select jsonb_build_object('name', s.name, 'kind', s.kind, 'land', s.biome, 'weather', s.wx_kind, 'people', s.pop,
                                        'food', round(s.food::numeric, 2),
                                        'wild', case when s.woods is not null then jsonb_strip_nulls(jsonb_build_object(
                                          'animals', f.grazer, 'hunters', case when s.beasts >= 1 then f.hunter end,
                                          'herd', case when s.herd >= 1 then f.herd end, 'trees', f.tree, 'birds', f.bird,
                                          'woods', case when f.woods_k < 0.1 then 'none' when s.woods < 0.3 * f.woods_k then 'thin'
                                                        when s.woods < 0.7 * f.woods_k then 'open' else 'thick' end,
                                          'river', case when s.river >= 0.2 then true end, 'sea', case when s.coast then true end)) end)
              from sim.settlements s cross join lateral sim.fauna(s.biome) f where s.id = me.settlement_id),
    'happened', (select coalesce(jsonb_agg(jsonb_build_object('what', e.kind, 'with', (select p.name from sim.people p where p.id = e.other_id),
                                                              'data', e.data - 'voice' - 'story' - 'said')), '[]')
                 from (select * from sim.events v where (v.agent_id = me.id or v.other_id = me.id) and v.tick >= t - 3 * 1440
                         and v.kind not in ('voice', 'spoke') order by v.tick desc, v.id desc limit 6) e),
    'did', (select coalesce(jsonb_agg(x.told), '[]') from (select y.told from app.deeds y where y.soul_id = j.soul_id order by y.id desc limit 3) x),
    'decided', (select coalesce(jsonb_agg(jsonb_build_object('about', x.kind, 'did', x.outcome ->> 'did', 'result', x.outcome ->> 'result',
                                                             'swayedBy', case when (x.outcome -> 'sway' ->> 'won')::boolean then x.outcome -> 'sway' ->> 'role' end)), '[]')
                from (select * from app.choices y where y.soul_id = j.soul_id and y.status = 'settled' order by y.id desc limit 3) x),
    'lately', (select coalesce(jsonb_agg(x.body), '[]') from (select y.body from app.thoughts y where y.soul_id = j.soul_id order by y.id desc limit 2) x),
    'choice', case when c.id is not null then jsonb_build_object('kind', c.kind, 'options', c.options,
                   'about', (select p.name || ' ' || p.surname from sim.people p where p.id = (c.facts ->> 'other')::bigint),
                   'details', c.facts - 'other' - 'pair' - 'union') end,
    'prayer', case when pr.id is not null then jsonb_build_object('need', pr.need) end,
    'question', j.context ->> 'question',
    'need', sim.need_of(me.id, t),
    'month', (t / 120) % 12,
    'known', (select coalesce(jsonb_agg(d.name order by d.found_tick), '[]') from sim.discoveries d where d.found_tick is not null)));
end $$;

-- The tick: far love follows the monthly pass, and nature follows the weather.
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
  perform sim.p_far_love(p_tick);
  perform sim.p_growing(p_tick);
  perform sim.p_community(p_tick);
  perform sim.p_prayers(p_tick);
  perform sim.p_choices(p_tick);
  if p_tick % 4 = 0 then
    perform sim.p_weather(p_tick);
    perform sim.p_nature(p_tick);
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

revoke all on function sim.draw_looks(bigint, bigint, bigint), sim.set_looks(), sim.p_far_love(integer), sim.send_pioneers(integer, integer),
  sim.fauna(text), sim.fish_room(real, boolean), sim.wild_start(integer), sim.p_nature(integer) from public, anon, authenticated;
revoke all on function api.god_nature(integer, text) from public, anon;
grant execute on function api.god_nature(integer, text) to authenticated;
