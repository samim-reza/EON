-- Neighbours: friendship, quarrels, fights, theft, judgement and making peace.
--
-- Until now the people of EON only ever got along. Real villages do not. This pass gives every
-- adult a monthly chance to make a friend, to fall out with a neighbour, to come to blows over an
-- old grudge, to steal when hungry, and to make peace again. Like every other pass it is
-- deterministic from the world seed, so a replay produces the same quarrels.
--
-- Death from a fight is possible but rare, and like every death it goes through sim.kill, so a
-- player's life ends the same way anyone's does.

-- Reasons people fall out, limited to what the world has discovered: nobody argues over a
-- borrowed tool before tools exist.
create or replace function sim.quarrel_reason(p_u double precision) returns text
language sql stable security definer set search_path = '' as $$
  with reasons as (
    select 'harsh words' as r
    union all select 'a debt'
    union all select 'water from the stream'
    union all select 'a place by the fire' where exists (select 1 from sim.discoveries d where d.id = 'fire' and d.found_tick is not null)
    union all select 'a borrowed tool' where exists (select 1 from sim.discoveries d where d.id = 'tools' and d.found_tick is not null)
    union all select 'the edge of a field' where exists (select 1 from sim.discoveries d where d.id = 'farming' and d.found_tick is not null)
    union all select 'a stray goat' where exists (select 1 from sim.discoveries d where d.id = 'animals' and d.found_tick is not null)
    union all select 'a broken pot' where exists (select 1 from sim.discoveries d where d.id = 'pottery' and d.found_tick is not null)
    union all select 'the price of grain' where exists (select 1 from sim.discoveries d where d.id = 'trade' and d.found_tick is not null)
  ), numbered as (select r, row_number() over () as rn, count(*) over () as n from reasons)
  select r from numbered where rn = 1 + floor(least(0.999999, greatest(0, p_u)) * n)::int;
$$;

-- Two people become friends.
create or replace function sim.befriend(p_tick integer, p_a bigint, p_b bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare lo bigint := least(p_a, p_b); hi bigint := greatest(p_a, p_b); place integer;
begin
  if p_a = p_b then return; end if;
  insert into sim.relationships (a, b, kind, affinity, since) values (lo, hi, 'friend', 20, p_tick)
  on conflict (a, b) do update set affinity = least(100, sim.relationships.affinity + 10) where sim.relationships.kind = 'friend';
  update sim.agents set happiness = least(100, happiness + 4) where id in (p_a, p_b);
  select settlement_id into place from sim.agents where id = p_a;
  perform sim.log(p_tick, 'friends', 1::smallint, p_a, p_b, place, '{}');
end $$;

-- Two people fall out, and sometimes it comes to blows. A fight hurts both, and costs the one who
-- started it their good name.
create or replace function sim.quarrel(p_tick integer, p_a bigint, p_b bigint, p_reason text, p_fight boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare lo bigint := least(p_a, p_b); hi bigint := greatest(p_a, p_b); place integer; seed bigint;
begin
  if p_a = p_b then return; end if;
  select w.seed into seed from sim.world w where w.id = 1;
  insert into sim.relationships (a, b, kind, affinity, since) values (lo, hi, 'rival', -20, p_tick)
  on conflict (a, b) do update set
    affinity = greatest(-100, sim.relationships.affinity - 20),
    kind = case when sim.relationships.affinity - 20 < 0 then 'rival' else sim.relationships.kind end;
  update sim.agents set happiness = greatest(0, happiness - 8) where id in (p_a, p_b);
  select settlement_id into place from sim.agents where id = p_a;
  if p_fight then
    update sim.agents set health = greatest(1, health - (10 + floor(15 * sim.rnd(seed, 'hurt', id, p_tick)))::int),
                          reputation = greatest(0, reputation - case when id = p_a then 8 else 3 end)
     where id in (p_a, p_b);
    perform sim.log(p_tick, 'fight', 2::smallint, p_a, p_b, place, jsonb_build_object('about', p_reason));
  else
    perform sim.log(p_tick, 'quarrel', 1::smallint, p_a, p_b, place, jsonb_build_object('about', p_reason));
  end if;
end $$;

-- Someone takes what is not theirs. If they are caught, the village makes them give it back and
-- remembers; if not, only the victim knows anything is missing.
create or replace function sim.steal(p_tick integer, p_thief bigint, p_victim bigint, p_amount bigint, p_caught boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare lo bigint := least(p_thief, p_victim); hi bigint := greatest(p_thief, p_victim); place integer; amount bigint := greatest(1, p_amount);
begin
  if p_thief = p_victim then return; end if;
  select settlement_id into place from sim.agents where id = p_victim;
  if p_caught then
    -- It goes back, with a fine on top, and everyone knows.
    update sim.agents set wealth = wealth - 20, reputation = greatest(0, reputation - 20), happiness = greatest(0, happiness - 10) where id = p_thief;
    update sim.agents set wealth = wealth + 20, happiness = greatest(0, happiness - 3) where id = p_victim;
    insert into sim.relationships (a, b, kind, affinity, since) values (lo, hi, 'rival', -30, p_tick)
    on conflict (a, b) do update set affinity = greatest(-100, sim.relationships.affinity - 30), kind = 'rival';
    perform sim.log(p_tick, 'judged', 2::smallint, p_thief, p_victim, place,
                    jsonb_build_object('stolen', amount, 'by', case when exists (select 1 from sim.discoveries d where d.id = 'law' and d.found_tick is not null) then 'law' else 'elders' end));
  else
    update sim.agents set wealth = wealth - amount, happiness = greatest(0, happiness - 10) where id = p_victim;
    update sim.agents set wealth = wealth + amount where id = p_thief;
    perform sim.log(p_tick, 'theft', 1::smallint, p_victim, null, place, jsonb_build_object('stolen', amount));
  end if;
end $$;

-- Two rivals make peace.
create or replace function sim.reconcile(p_tick integer, p_a bigint, p_b bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare lo bigint := least(p_a, p_b); hi bigint := greatest(p_a, p_b); place integer;
begin
  if p_a = p_b then return; end if;
  update sim.relationships set kind = 'friend', affinity = 10 where a = lo and b = hi;
  if not found then return; end if;
  update sim.agents set happiness = least(100, happiness + 6) where id in (p_a, p_b);
  select settlement_id into place from sim.agents where id = p_a;
  perform sim.log(p_tick, 'reconciled', 1::smallint, p_a, p_b, place, '{}');
end $$;

-- The monthly pass. Everyone in this tick's bucket is considered once.
create or replace function sim.p_community(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  slot smallint := (p_tick % 120)::smallint; -- not "b": sim.relationships has a column of that name
  adult integer := 16 * 1440;
  r record; nb record;
  temper double precision; reason text; fight boolean; victim bigint;
begin
  select * into w from sim.world where id = 1;

  for r in
    select a.id, a.settlement_id, a.partner_id, a.trait_a, a.trait_n, a.trait_e, a.honesty, a.wealth, a.reputation, a.health,
           s.food, coalesce(s.wx_high, 20) as hot, s.pop
    from sim.agents a join sim.settlements s on s.id = a.settlement_id
    where a.bucket = slot and p_tick - a.birth_tick >= adult
    order by a.id
  loop
    continue when not exists (select 1 from sim.agents x where x.id = r.id); -- lost in a fight earlier this tick

    -- 1. Friendship: the outgoing make friends sooner.
    if sim.rnd(w.seed, 'befriend', r.id, p_tick) < 0.04 + r.trait_e / 1000.0 then
      select x.id into nb from sim.agents x
       where x.settlement_id = r.settlement_id and x.id <> r.id and x.id is distinct from r.partner_id and p_tick - x.birth_tick >= adult
         and not exists (select 1 from sim.relationships l where l.a = least(x.id, r.id) and l.b = greatest(x.id, r.id))
       order by sim.rnd(w.seed, 'friend-of', r.id, x.id) limit 1;
      if nb.id is not null then perform sim.befriend(p_tick, r.id, nb.id); end if;
    end if;

    -- 2. Quarrels: short tempers, hunger and heat. An old grudge is picked up before a new one.
    temper := (100 - r.trait_a) / 100.0 * (0.5 + r.trait_n / 100.0)
              * (1 + case when r.food < 0.8 then 0.6 else 0 end + case when r.hot > 32 then 0.4 else 0 end);
    if sim.rnd(w.seed, 'quarrel', r.id, p_tick) < 0.05 * temper * w.crime_mult then
      select x.id, coalesce(l.affinity, 0) as affinity, x.health as hp into nb
        from sim.agents x
        left join sim.relationships l on l.a = least(x.id, r.id) and l.b = greatest(x.id, r.id)
       where x.settlement_id = r.settlement_id and x.id <> r.id and x.id is distinct from r.partner_id and p_tick - x.birth_tick >= adult
       order by (coalesce(l.affinity, 0) < 0) desc, sim.rnd(w.seed, 'foe', r.id, x.id) limit 1;
      if nb.id is not null then
        reason := sim.quarrel_reason(sim.rnd(w.seed, 'reason', r.id, p_tick));
        fight := nb.affinity <= -30 and sim.rnd(w.seed, 'blows', r.id, p_tick) < 0.3 * temper;
        perform sim.quarrel(p_tick, r.id, nb.id, reason, fight);
        -- Very rarely a fight is the end of someone. The weaker one falls.
        if fight and sim.rnd(w.seed, 'wound', r.id, p_tick) < 0.02 * w.crime_mult then
          victim := case when nb.hp < r.health then nb.id else r.id end;
          perform sim.kill(p_tick, victim, 'Wounds');
          continue;
        end if;
      end if;
    end if;

    -- 3. Theft: the poor and the dishonest, from whoever has the most. Small villages see everything.
    if (r.wealth < 20 or (r.food < 0.7 and r.wealth < 100)) and r.honesty < 45
       and sim.rnd(w.seed, 'steal', r.id, p_tick) < 0.10 * (45 - r.honesty) / 45.0 * w.crime_mult then
      select x.id, x.wealth into nb from (
        select y.id, y.wealth from sim.agents y
         where y.settlement_id = r.settlement_id and y.id <> r.id and y.wealth >= 100
         order by y.wealth desc limit 3) x
       order by sim.rnd(w.seed, 'mark', r.id, x.id) limit 1;
      if nb.id is not null then
        perform sim.steal(p_tick, r.id, nb.id, least(80, nb.wealth / 5),
                          sim.rnd(w.seed, 'caught', r.id, p_tick) < least(0.9, 0.45 + case when r.pop < 40 then 0.3 else 0 end
                                                                          + case when r.reputation < 40 then 0.1 else 0 end));
      end if;
    end if;
  end loop;

  -- 4. Grudges fade, and the easy-going make peace.
  for r in
    select l.a, l.b, x.trait_a as ta, y.trait_a as tb
    from sim.relationships l join sim.agents x on x.id = l.a join sim.agents y on y.id = l.b
    where l.kind = 'rival' and x.bucket = slot
  loop
    if sim.rnd(w.seed, 'peace', r.a, p_tick) < 0.12 * (r.ta + r.tb) / 200.0 then
      perform sim.reconcile(p_tick, r.a, r.b);
    else
      update sim.relationships set affinity = least(0, affinity + 4) where a = r.a and b = r.b;
    end if;
  end loop;
  -- A rivalry that has faded all the way is simply forgotten.
  delete from sim.relationships where kind = 'rival' and affinity >= 0;
end $$;

-- The first quarrel, the first fight and the first time two people made peace are history too.
create or replace function sim.log(p_tick integer, p_kind text, p_importance smallint, p_agent bigint,
                                   p_other bigint, p_settlement integer, p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare
  eid bigint := nextval('sim.event_id_seq');
  imp smallint := p_importance;
  body jsonb := coalesce(p_data, '{}');
begin
  -- The first time anything happens is history, however ordinary it later becomes.
  if imp < 3 and p_kind in ('birth', 'death', 'union', 'wedding', 'outbreak', 'weather', 'harvest', 'built',
                            'friends', 'quarrel', 'fight', 'theft', 'judged', 'reconciled')
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

-- Fights, judgements and reconciliations are worth telling.
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
    when p_kind in ('fight', 'judged', 'reconciled') and not crowded then job := 'story'; rank := 5;
    when p_kind = 'quarrel' and p_imp >= 3 then job := 'story'; rank := 5;
    when p_kind = 'prayer' and not crowded then job := 'prayer'; rank := 6;
    else return;
  end case;
  insert into llm.jobs (kind, priority, tick, event_id, event_tick, agent_id, other_id, settlement_id, context)
  values (job, rank, p_tick, p_id, p_tick, p_agent, p_other, p_settlement, jsonb_build_object('event', p_kind, 'data', p_data));
end $$;

-- People who carry a grudge pray for peace, and an answered prayer for peace makes it.
alter table app.prayers drop constraint if exists prayers_need_check;
alter table app.prayers add constraint prayers_need_check check (need in ('health', 'food', 'child', 'safety', 'peace'));

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
        when exists (select 1 from sim.relationships l where (l.a = a.id or l.b = a.id) and l.kind = 'rival' and l.affinity <= -30) then 'peace'
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

create or replace function sim.answer_prayer(p_prayer bigint, p_grant boolean, p_by text, p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p app.prayers;
  a sim.agents;
  foe record;
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
    when 'peace' then
      -- The deepest grudge is the one that lifts.
      select l.a, l.b into foe from sim.relationships l where (l.a = a.id or l.b = a.id) and l.kind = 'rival' order by l.affinity limit 1;
      if foe.a is not null then perform sim.reconcile(p_tick, foe.a, foe.b); end if;
      update sim.agents set happiness = least(100, happiness + 10) where id = a.id;
    else
      update sim.agents set happiness = least(100, happiness + 10) where id = a.id;
  end case;
  perform sim.log(p_tick, 'prayer_answered', 1::smallint, a.id, null, a.settlement_id, jsonb_build_object('need', p.need));
end $$;

-- The pass joins the tick, right after everyone's monthly check-up.
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
  perform sim.p_community(p_tick);
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

-- Deaths from fights count among the world's causes, so the cause has a name.
comment on function sim.p_community(integer) is 'Monthly: friendships, quarrels, fights, theft, judgement and peace for one bucket of adults.';
