-- People act on the land, and the land remembers.
--
-- 1. A person with a soul can now live off the country around them and look after it: hunt, fish,
--    forage, cut firewood, plant trees, tend the herd. Each deed changes the village's real herds,
--    waters and woods, so a village of players can hunt its deer out or grow its woods back.
-- 2. A fire leaves a scar. The map shows where the woods burned until they have grown over.

alter table sim.settlements add column burn_tick integer; -- when the woods here last burned

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
           crop = v_crop, eco_event_tick = case when event is null then t.eco_event_tick else p_tick end,
           burn_tick = case when event = 'wildfire' then p_tick else t.burn_tick end
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
      update sim.settlements set woods = woods * 0.6, game = game * 0.7, richness = least(1, richness + 0.04), burn_tick = t where id = p_settlement;
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

-- The map also learns whether a village has a river or the sea, and when its woods last burned.
create or replace function api.pub_geo() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'seed', (select seed::text from sim.world),
    'settlements', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', s.id, 'name', s.name, 'kind', s.kind, 'x', s.x, 'y', s.y, 'region', s.region, 'founded', s.founded_tick, 'food', round(s.food::numeric, 2),
        'pop', (select count(*) from sim.agents a where a.settlement_id = s.id),
        'biome', s.biome, 'river', case when s.river >= 0.2 then true end, 'coast', case when s.coast then true end, 'burn', s.burn_tick,
        'land', case when s.woods is not null then jsonb_build_array(round(s.woods::numeric, 2), round(s.richness::numeric, 2),
                     round(s.game::numeric), round(s.beasts::numeric), round(s.fish::numeric), round(s.herd::numeric)) end)) order by s.id)
      from sim.settlements s), '[]'),
    'buildings', coalesce((select jsonb_agg(jsonb_build_array(b.id, b.settlement_id, b.kind, round(b.x::numeric, 1), round(b.y::numeric, 1)) order by b.id)
      from sim.buildings b where b.built_tick is not null), '[]'));
$$;

create or replace function sim.deeds_for(p_agent bigint, p_tick integer) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  w sim.world; me sim.agents; yrs integer; list jsonb := '[]';
  mom sim.agents; dad sim.agents; parent sim.agents; x record;
  st sim.settlements; f record;
begin
  select * into w from sim.world where id = 1;
  select * into me from sim.agents a where a.id = p_agent;
  if not found then return '[]'; end if;
  yrs := (p_tick - me.birth_tick) / 1440;
  select * into st from sim.settlements s where s.id = me.settlement_id;
  select * into f from sim.fauna(st.biome);
  select * into mom from sim.agents a where a.id = me.mother_id and a.settlement_id = me.settlement_id;
  select * into dad from sim.agents a where a.id = me.father_id and a.settlement_id = me.settlement_id;

  if yrs < 3 then
    if mom.id is not null then list := list || sim.deed('cuddle', 'Cry for your mother, ' || mom.name, mom.id); end if;
    if dad.id is not null then list := list || sim.deed('smile', 'Smile at your father, ' || dad.name, dad.id); end if;
    list := list || sim.deed('sleep', 'Sleep');
    return list;
  end if;

  if yrs < 16 then
    select a.id, a.name into x from sim.agents a
     where a.settlement_id = me.settlement_id and a.id <> me.id and abs(a.birth_tick - me.birth_tick) <= 5 * 1440
       and p_tick - a.birth_tick >= 2 * 1440
     order by sim.rnd(w.seed, 'pal', me.id, p_tick / 120 + a.id) limit 1;
    if x.id is not null then list := list || sim.deed('play', 'Play with ' || x.name, x.id); end if;
    parent := coalesce(mom, dad);
    if parent.id is not null then list := list || sim.deed('chores', 'Help ' || parent.name || ' with the chores', parent.id); end if;
    list := list || sim.deed('explore', 'Explore beyond the houses') || sim.deed('stories', 'Listen to the elders'' stories');
    -- The land is a child's playground and larder too.
    if st.woods is not null then
      list := list || sim.deed('forage', case when f.woods_k >= 0.1 then 'Gather berries at the edge of the ' || f.tree || ' woods'
                                              else 'Look for wild roots and eggs' end);
      if yrs >= 8 then list := list || sim.deed('fish', 'Go fishing'); end if;
    end if;
    return list;
  end if;

  if me.occupation in ('farmer', 'builder', 'healer') then
    list := list || sim.deed('work', case me.occupation when 'farmer' then 'Work extra hard in the fields'
                                                       when 'builder' then 'Work extra hard on the walls' else 'Work extra hard with the sick' end);
  end if;
  list := list || sim.deed('rest', 'Rest');
  select a.id, a.name into x from sim.relationships l join sim.agents a on a.id = case when l.a = me.id then l.b else l.a end
   where (l.a = me.id or l.b = me.id) and l.kind = 'friend' and a.settlement_id = me.settlement_id
   order by sim.rnd(w.seed, 'visit', me.id, p_tick / 120 + a.id) limit 1;
  if x.id is not null then list := list || sim.deed('visit', 'Visit ' || x.name, x.id); end if;
  select a.id, a.name into x from sim.agents a
   where a.settlement_id = me.settlement_id and a.id <> me.id
     and (exists (select 1 from sim.infections i where i.agent_id = a.id and i.until_tick > p_tick) or a.wealth < 20)
   order by a.health, a.wealth limit 1;
  if x.id is not null then list := list || sim.deed('help', 'Help ' || x.name || ', who is in need', x.id); end if;
  select a.id, a.name into x from sim.agents a
   where (a.mother_id = me.id or a.father_id = me.id) and p_tick - a.birth_tick between 4 * 1440 and 16 * 1440 - 1
   order by a.birth_tick limit 1;
  if x.id is not null then list := list || sim.deed('teach', 'Teach ' || x.name || ' what you know', x.id); end if;
  select a.id, a.name into x from sim.relationships l join sim.agents a on a.id = case when l.a = me.id then l.b else l.a end
   where (l.a = me.id or l.b = me.id) and l.kind = 'rival' order by l.affinity limit 1;
  if x.id is not null then list := list || sim.deed('peace', 'Try to make peace with ' || x.name, x.id); end if;
  if me.partner_id is null and yrs >= 17
     and not exists (select 1 from app.choices c where c.agent_id = me.id and c.kind = 'love' and c.status in ('open', 'asked', 'chosen')) then
    list := list || sim.deed('love', 'Look for love');
  end if;
  if me.wealth >= 20 then list := list || sim.deed('give', 'Give 10 credits to someone in need'); end if;
  -- Living off the land, and looking after it.
  if st.woods is not null then
    list := list || sim.deed('hunt', 'Go hunting for ' || f.grazer) || sim.deed('fish', 'Go fishing');
    if f.woods_k >= 0.1 then
      list := list || sim.deed('wood', 'Cut firewood in the ' || f.tree || ' woods') || sim.deed('plant', 'Plant ' || f.tree || ' saplings');
    end if;
    if st.herd >= 1 then list := list || sim.deed('herd', 'Tend the village ' || f.herd); end if;
  end if;
  return list;
end $$;

create or replace function api.do_deed(p_deed text, p_other bigint default null) returns text
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  w sim.world; t integer; o app.souls; me sim.agents; you sim.agents;
  ok boolean; told text; u double precision; n integer; cand bigint;
  min_age int; gap int; p jsonb := (select value from sim.params where key = 'demography');
  st sim.settlements; f record; yrs integer;
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  perform app.hit('deed:' || uid::text, 30, interval '1 hour');
  select * into w from sim.world where id = 1;
  t := w.tick;
  select * into o from app.souls s where s.user_id = uid and s.status = 'living';
  if not found then raise exception 'You are not alive in EON'; end if;
  if app.soul_mind(o.id, t) = 'none' then raise exception 'Connect your own AI to act again'; end if;
  if (select count(*) from app.deeds d where d.soul_id = o.id and d.tick > t - 1440) >= 4 then
    raise exception 'That is enough for one day. Come back tomorrow.';
  end if;
  select exists (select 1 from jsonb_array_elements(sim.deeds_for(o.agent_id, t)) e
                  where e ->> 'id' = p_deed and (e ->> 'other')::bigint is not distinct from p_other) into ok;
  if not ok then raise exception 'You cannot do that right now'; end if;
  select * into me from sim.agents a where a.id = o.agent_id;
  if p_other is not null then select * into you from sim.agents a where a.id = p_other; end if;
  u := sim.rnd(w.seed, 'deed:' || p_deed, me.id, t);
  yrs := (t - me.birth_tick) / 1440;
  select * into st from sim.settlements s where s.id = me.settlement_id;
  select * into f from sim.fauna(st.biome);

  case p_deed
    when 'cuddle', 'smile' then
      update sim.agents set happiness = least(100, happiness + 3) where id in (me.id, you.id);
      update sim.agents set trait_a = sim.clamp100(trait_a + 1) where id = me.id;
      told := case p_deed when 'cuddle' then you.name || ' picked you up and hummed until you smiled.'
                                        else you.name || ' laughed and smiled back.' end;
    when 'sleep' then
      update sim.agents set health = least(100, health + 2), happiness = least(100, happiness + 1) where id = me.id;
      told := 'You slept deeply and woke up hungry.';
    when 'play' then
      if exists (select 1 from sim.relationships l where l.a = least(me.id, you.id) and l.b = greatest(me.id, you.id) and l.kind = 'friend') then
        update sim.relationships set affinity = least(100, affinity + 5) where a = least(me.id, you.id) and b = greatest(me.id, you.id);
        update sim.agents set happiness = least(100, happiness + 3) where id in (me.id, you.id);
        told := 'You and ' || you.name || ' played until dark, the best of friends.';
      elsif exists (select 1 from sim.relationships l where l.a = least(me.id, you.id) and l.b = greatest(me.id, you.id)) then
        update sim.relationships set affinity = least(0, affinity + 8) where a = least(me.id, you.id) and b = greatest(me.id, you.id);
        told := 'You and ' || you.name || ' played together, a little warily.';
      else
        perform sim.befriend(t, me.id, you.id);
        told := 'You and ' || you.name || ' played until dark. You are friends now.';
      end if;
    when 'chores' then
      update sim.agents set trait_c = sim.clamp100(trait_c + 1) where id = me.id;
      update sim.agents set happiness = least(100, happiness + 2), wealth = wealth + 3 where id = you.id;
      told := 'You helped ' || you.name || ' with the chores. ' || you.name || ' was proud of you.';
    when 'explore' then
      update sim.agents set trait_o = sim.clamp100(trait_o + 1) where id = me.id;
      if u < 0.3 then
        update sim.agents set wealth = wealth + 5 where id = coalesce(me.mother_id, me.father_id);
        told := 'You wandered past the last houses and came back with a handful of berries.';
      elsif u < 0.45 then
        update sim.agents set health = greatest(0, health - 3) where id = me.id;
        told := 'You wandered too far and came home with a scraped knee.';
      else
        told := 'You wandered past the last houses and watched the land go on and on.';
      end if;
    when 'stories' then
      update sim.agents set education = least(100, education + 2), piety = sim.clamp100(piety + 1) where id = me.id;
      told := 'You sat with the elders and listened to the old stories.';
    when 'work' then
      n := case me.occupation when 'healer' then 25 when 'builder' then 20 else 15 end;
      update sim.agents set wealth = wealth + n, health = greatest(0, health - 2), happiness = greatest(0, happiness - 1) where id = me.id;
      told := 'A long, hard day of work: ' || n || ' credits more, and an aching back.';
    when 'rest' then
      update sim.agents set health = least(100, health + 3), happiness = least(100, happiness + 2) where id = me.id;
      told := 'You took the day slowly and felt better for it.';
    when 'visit' then
      update sim.relationships set affinity = least(100, affinity + 5) where a = least(me.id, you.id) and b = greatest(me.id, you.id);
      update sim.agents set happiness = least(100, happiness + 3) where id in (me.id, you.id);
      told := 'You spent the afternoon with ' || you.name || '.';
    when 'help' then
      update sim.agents set reputation = least(100, reputation + 2) where id = me.id;
      if exists (select 1 from sim.infections i where i.agent_id = you.id and i.until_tick > t) then
        update sim.agents set health = least(100, health + 5) where id = you.id;
        told := 'You looked after ' || you.name || ' while they were ill.';
      elsif me.wealth >= 10 then
        update sim.agents set wealth = wealth - 10 where id = me.id;
        update sim.agents set wealth = wealth + 10, happiness = least(100, happiness + 3) where id = you.id;
        told := 'You shared what you had with ' || you.name || '.';
      else
        update sim.agents set happiness = least(100, happiness + 3) where id = you.id;
        told := 'You had nothing to give, so you sat with ' || you.name || ' for a while.';
      end if;
    when 'teach' then
      update sim.agents set education = least(100, education + 3) where id = you.id;
      told := 'You taught ' || you.name || ' what you know.';
    when 'peace' then
      if u < 0.4 + me.trait_a / 200.0 then
        perform sim.reconcile(t, me.id, you.id);
        told := 'You went to ' || you.name || ' and made peace.';
      else
        update sim.relationships set affinity = least(0, affinity + 5) where a = least(me.id, you.id) and b = greatest(me.id, you.id);
        told := you.name || ' would not hear of it, but the grudge is a little softer now.';
      end if;
    when 'love' then
      min_age := (p -> 'fertility' ->> 'partnerMinAge')::int * 1440;
      gap := (p -> 'fertility' ->> 'maxAgeGap')::int * 1440;
      select c.id into cand from sim.agents c
       where c.settlement_id = me.settlement_id and c.sex <> me.sex and c.partner_id is null
         and t - c.birth_tick >= min_age and abs(c.birth_tick - me.birth_tick) <= gap
         and not sim.is_close_kin(me.id, me.lineage, c.id, c.lineage)
         and not exists (select 1 from app.choices ch where ch.agent_id = c.id and ch.kind = 'love' and ch.status in ('open', 'asked', 'chosen'))
       order by sim.rnd(w.seed, 'eye', me.id, c.id + t) limit 1;
      if cand is null then
        told := 'You looked around, but nobody in the village is free to court right now.';
      else
        perform sim.court(t, me.id, cand);
        told := (select a.name from sim.agents a where a.id = cand) || ' has noticed you. Your answer is waiting under Choices.';
      end if;
    when 'give' then
      select * into you from sim.agents a where a.settlement_id = me.settlement_id and a.id <> me.id order by a.wealth, a.id limit 1;
      update sim.agents set wealth = wealth - 10, reputation = least(100, reputation + 1), happiness = least(100, happiness + 2) where id = me.id;
      update sim.agents set wealth = wealth + 10 where id = you.id;
      told := 'You gave 10 credits to ' || you.name || ', who needed them most.';
    -- The land: what a person takes from it comes out of the village's real herds, waters and woods.
    when 'forage' then
      update sim.agents set trait_o = sim.clamp100(trait_o + 1) where id = me.id;
      if u < 0.65 then
        update sim.agents set wealth = wealth + 3 where id = coalesce(me.mother_id, me.father_id, me.id);
        told := 'You came home with a basket of berries and nuts for the family.';
      else
        told := 'You searched all afternoon and found only a few sour berries.';
      end if;
    when 'fish' then
      if u < least(0.9, 0.25 + 0.65 * st.fish / sim.fish_room(st.river, st.coast)) then
        update sim.settlements set fish = greatest(5, fish - case when yrs < 16 then 1 else 3 end) where id = st.id;
        update sim.agents set wealth = wealth + case when yrs < 16 then 3 else 7 end
         where id = case when yrs < 16 then coalesce(me.mother_id, me.father_id, me.id) else me.id end;
        update sim.agents set happiness = least(100, happiness + 1) where id = me.id;
        told := case when st.coast then 'You came back from the shore with a string of fish.'
                     when st.river >= 0.2 then 'You came back from the river with a string of fish.'
                     else 'You came back from the stream with a few small fish.' end;
      else
        told := 'The fish were not biting today.';
      end if;
    when 'hunt' then
      if u < least(0.85, 0.15 + 0.7 * st.game / greatest(f.game_k, 1)) then
        update sim.settlements set game = greatest(2, game - 2) where id = st.id;
        update sim.agents set wealth = wealth + 12, reputation = least(100, reputation + 1), happiness = least(100, happiness + 2) where id = me.id;
        told := 'You brought down one of the ' || f.grazer || ' and shared the meat with your neighbours.';
      elsif st.game < 0.15 * f.game_k then
        told := 'You walked all day and saw no ' || f.grazer || ' at all. They have been hunted too hard.';
      else
        update sim.agents set health = greatest(0, health - 1) where id = me.id;
        told := 'You followed the ' || f.grazer || ' all day and came home with nothing but sore feet.';
      end if;
    when 'wood' then
      if st.woods < 0.01 then
        told := 'There is hardly a tree left standing to cut.';
      else
        update sim.settlements set woods = greatest(0, woods - 0.0008) where id = st.id;
        update sim.agents set wealth = wealth + 5 where id = me.id;
        told := 'You cut and stacked a load of ' || f.tree || ' wood. The woods are a little thinner for it.';
      end if;
    when 'plant' then
      update sim.settlements set woods = least(greatest(woods, f.woods_k), woods + 0.0015) where id = st.id;
      update sim.agents set reputation = least(100, reputation + 1), happiness = least(100, happiness + 1) where id = me.id;
      told := case when st.woods >= f.woods_k * 0.98
                   then 'The woods are as thick as this country grows them. You planted a few ' || f.tree || ' saplings anyway.'
                   else 'You planted ' || f.tree || ' saplings where the old trees were cut. They will take years to grow.' end;
    when 'herd' then
      update sim.settlements set herd = least(greatest(herd, pop * 3 * f.pasture), herd + 0.6) where id = st.id;
      update sim.agents set wealth = wealth + 4, happiness = least(100, happiness + 1) where id = me.id;
      told := 'You spent the day with the village ' || f.herd || '. They are the better for it.';
    else
      raise exception 'You cannot do that right now';
  end case;

  insert into app.deeds (soul_id, agent_id, tick, kind, other_id, told) values (o.id, me.id, t, p_deed, you.id, told);
  -- A quiet event: the person's mind and page know it, the public feed does not.
  perform sim.log(t, 'deed', 0::smallint, me.id, you.id, me.settlement_id, jsonb_build_object('deed', p_deed));
  return told;
end $$;
