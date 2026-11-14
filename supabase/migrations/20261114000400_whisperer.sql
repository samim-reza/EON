-- The Whisperer, and the reckoning.
--
-- With only the Creator above them, people did wrong out of hunger, temper or a crooked nature and
-- nothing else. Now there is an outcast as well. The Creator made it before the first people; it
-- would not honour them, was cast out, and was given until the end of the world. It can do one
-- thing: whisper. It cannot make anyone do anything. Each person it whispers to gives in, turns
-- away, or seeks refuge with the Creator, and those who seek refuge it leaves alone for a while.
--
-- So every person now carries a record: good deeds, ill deeds, and ill deeds they repented of.
-- Repentance lays the ill down. When someone dies the record is weighed, and their page says how
-- they left the world. Nobody is accountable before the age of fifteen.

------------------------------------------------------------------------------
-- 1. What is kept
------------------------------------------------------------------------------
alter table sim.world add column whisper_mult real not null default 1 check (whisper_mult between 0 and 3); -- how loud the Whisperer is

alter table sim.agents
  add column deeds_good   smallint not null default 0,
  add column deeds_ill    smallint not null default 0,   -- ill deeds not yet repented of
  add column deeds_mended smallint not null default 0,   -- ill deeds laid down by repentance
  add column refuge_until integer  not null default 0;   -- the Whisperer keeps away until this tick

alter table sim.dead
  add column deeds_good   smallint,
  add column deeds_ill    smallint,
  add column deeds_mended smallint;

alter table app.choices drop constraint if exists choices_kind_check;
alter table app.choices add constraint choices_kind_check
  check (kind in ('year', 'work', 'love', 'wed', 'child', 'quarrel', 'tempt', 'sign', 'whisper'));

-- The age at which a person answers for what they do.
create or replace function sim.age_of_reckoning() returns integer
language sql immutable parallel safe set search_path = '' as $$ select 15 * 1440 $$;

-- How a life weighs at its end. An ill deed weighs three times a small kindness; repented ill
-- weighs nothing.
create or replace function sim.weigh(p_good integer, p_ill integer, p_age_years integer) returns text
language sql immutable parallel safe set search_path = '' as $$
  select case
    when p_good is null or p_ill is null then null
    when p_age_years < 15 then 'child'
    when p_good - 3 * p_ill >= 3 then 'light'
    when p_good - 3 * p_ill <= -3 then 'heavy'
    else 'even' end;
$$;

-- The story is told once, at the beginning of the history.
create or replace function sim.tell_of_the_outcast() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select w.genesis_at from sim.world w where w.id = 1) is null then return; end if;
  if exists (select 1 from sim.chronicle c where c.kind = 'outcast') then return; end if;
  insert into sim.chronicle (id, tick, kind, agent_id, other_id, settlement_id, data)
  values (nextval('sim.event_id_seq'), 0, 'outcast', null, null, null, '{}');
end $$;

select sim.tell_of_the_outcast();

------------------------------------------------------------------------------
-- 2. The whisper
------------------------------------------------------------------------------
-- What the Whisperer would say to this person now: the wrong that lies nearest to hand.
--   take     someone here has plenty
--   cheat    give short measure at work
--   slander  lie about someone better thought of
--   strike   an old grudge
--   idle     leave the work to others
--   forsake  stop praying
create or replace function sim.whisper_for(p_agent bigint, p_tick integer, out what text, out other bigint)
language plpgsql stable security definer set search_path = '' as $$
declare
  w sim.world; me sim.agents; vfood real;
  rival bigint; rich bigint; envied bigint;
  kinds text[] := '{}'; targets bigint[] := '{}'; weights double precision[] := '{}';
  total double precision := 0; u double precision; i integer;
begin
  select * into w from sim.world where id = 1;
  select * into me from sim.agents a where a.id = p_agent;
  if not found then return; end if;
  select s.food into vfood from sim.settlements s where s.id = me.settlement_id;

  select x.id into rival
    from sim.relationships l join sim.agents x on x.id = case when l.a = me.id then l.b else l.a end
   where (l.a = me.id or l.b = me.id) and l.kind = 'rival' and l.affinity <= -20 and x.settlement_id = me.settlement_id
   order by l.affinity, x.id limit 1;
  select y.id into rich from sim.agents y
   where y.settlement_id = me.settlement_id and y.id <> me.id and y.id is distinct from me.partner_id
     and y.wealth >= 100 and y.wealth > me.wealth + 60
   order by y.wealth desc, y.id limit 1;
  select y.id into envied from sim.agents y
   where y.settlement_id = me.settlement_id and y.id <> me.id and y.id is distinct from me.partner_id
     and p_tick - y.birth_tick >= sim.age_of_reckoning() and y.reputation > me.reputation + 10
   order by sim.rnd(w.seed, 'envy', me.id, y.id + p_tick) limit 1;

  if rival is not null then
    kinds := array_append(kinds, 'strike'); targets := array_append(targets, rival);
    weights := array_append(weights, (3 + (100 - me.trait_a) / 50.0)::float8);
  end if;
  if rich is not null then
    kinds := array_append(kinds, 'take'); targets := array_append(targets, rich);
    weights := array_append(weights, (2 + case when me.wealth < 40 or vfood < 0.7 then 3 else 0 end)::float8);
  end if;
  if envied is not null then
    kinds := array_append(kinds, 'slander'); targets := array_append(targets, envied); weights := array_append(weights, 2::float8);
  end if;
  if me.occupation in ('farmer', 'builder', 'healer') then
    kinds := array_append(kinds, 'cheat'); targets := array_append(targets, null::bigint); weights := array_append(weights, 2::float8);
    kinds := array_append(kinds, 'idle');  targets := array_append(targets, null::bigint); weights := array_append(weights, 1.5::float8);
  end if;
  if me.piety >= 15 then
    kinds := array_append(kinds, 'forsake'); targets := array_append(targets, null::bigint); weights := array_append(weights, 1.5::float8);
  end if;
  if cardinality(kinds) = 0 then return; end if;

  for i in 1 .. cardinality(weights) loop total := total + weights[i]; end loop;
  u := sim.rnd(w.seed, 'whisper-what', me.id, p_tick) * total;
  for i in 1 .. cardinality(weights) loop
    u := u - weights[i];
    if u < 0 or i = cardinality(weights) then
      what := kinds[i]; other := targets[i];
      return;
    end if;
  end loop;
end $$;

-- How likely this person is to give in. Faith and honesty hold; need, temper and despair pull.
create or replace function sim.whisper_odds(p_agent bigint, p_what text) returns double precision
language sql stable security definer set search_path = '' as $$
  select greatest(0.04, least(0.9,
    0.55 - 0.40 * a.piety / 100.0 - 0.25 * a.honesty / 100.0
    + case p_what
        when 'take'    then case when a.wealth < 40 or s.food < 0.7 then 0.20 else 0 end
        when 'strike'  then (100 - a.trait_a) / 100.0 * 0.25 - 0.05
        when 'slander' then (100 - a.trait_a) / 100.0 * 0.15
        when 'idle'    then (100 - a.trait_c) / 100.0 * 0.20
        when 'forsake' then case when a.happiness < 40 then 0.25 else 0.10 end
        else 0 end))
  from sim.agents a join sim.settlements s on s.id = a.settlement_id where a.id = p_agent;
$$;

-- The words, as the person hears them: almost in their own voice.
create or replace function sim.whisper_line(p_what text, p_name text) returns text
language sql immutable set search_path = '' as $$
  select case p_what
    when 'take'    then 'Take it. ' || coalesce(p_name, 'They') || ' has more than enough, and nobody will see.'
    when 'cheat'   then 'Give a little less than you promised. Who would ever know?'
    when 'slander' then 'Tell them what you know about ' || coalesce(p_name, 'them') || '. Make it a little worse.'
    when 'strike'  then 'You have swallowed enough from ' || coalesce(p_name, 'them') || '. Make them sorry.'
    when 'idle'    then 'Let the others carry it today. You have done your share.'
    when 'forsake' then 'Why do you still pray? Nobody is listening.'
    else 'Go on.' end;
$$;

-- Someone turns back: the ill they carry is laid down. Returns how much there was.
create or replace function sim.repent(p_tick integer, p_agent bigint) returns integer
language plpgsql security definer set search_path = '' as $$
declare me sim.agents;
begin
  select * into me from sim.agents a where a.id = p_agent;
  if not found or me.deeds_ill = 0 then return 0; end if;
  update sim.agents set deeds_mended = least(30000, deeds_mended + deeds_ill), deeds_ill = 0,
         piety = sim.clamp100(piety + 3), happiness = least(100, happiness + 4)
   where id = p_agent;
  perform sim.log(p_tick, 'repent', 1::smallint, p_agent, null, me.settlement_id, '{}');
  return me.deeds_ill;
end $$;

-- What follows a whisper. `p_did` is 'yield', 'resist' or 'refuge'. Returns what came of it.
create or replace function sim.do_whisper(p_tick integer, p_agent bigint, p_what text, p_other bigint, p_did text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world; me sim.agents; you sim.agents;
  u double precision; caught boolean; res text; small boolean; counts boolean := true;
begin
  select * into w from sim.world where id = 1;
  select * into me from sim.agents a where a.id = p_agent;
  if not found then return 'gone'; end if;
  if p_other is not null then select * into you from sim.agents a where a.id = p_other; end if;

  if p_did is distinct from 'yield' then
    -- Turning away is a good deed in itself. Seeking refuge is more: the Whisperer keeps off for two years.
    update sim.agents set
      piety = sim.clamp100(piety + case when p_did = 'refuge' then 3 else 1 end),
      honesty = least(100, honesty + 1),
      deeds_good = least(30000, deeds_good + 1),
      refuge_until = case when p_did = 'refuge' then p_tick + 2 * 1440 else refuge_until end
    where id = me.id;
    perform sim.log(p_tick, 'whisper', 0::smallint, me.id, p_other, me.settlement_id,
                    jsonb_build_object('what', p_what, 'did', case when p_did = 'refuge' then 'refuge' else 'resist' end));
    return case when p_did = 'refuge' then 'refuge' else 'resisted' end;
  end if;

  u := sim.rnd(w.seed, 'whisper-luck', me.id, p_tick);
  small := coalesce((select s.pop from sim.settlements s where s.id = me.settlement_id), 0) < 40; -- a small village sees everything
  case p_what
    when 'take' then
      if you.id is null or you.settlement_id <> me.settlement_id then
        res := 'gone'; counts := false;
      else
        caught := u < least(0.9, 0.45 + case when small then 0.3 else 0 end + case when me.reputation < 40 then 0.1 else 0 end);
        perform sim.steal(p_tick, me.id, you.id, least(80, greatest(you.wealth, 0) / 5), caught);
        res := case when caught then 'caught' else 'took' end;
      end if;
    when 'cheat' then
      caught := u < 0.3 + case when small then 0.2 else 0 end;
      if caught then
        update sim.agents set wealth = wealth - 10, reputation = greatest(0, reputation - 10), honesty = greatest(0, honesty - 3) where id = me.id;
        perform sim.log(p_tick, 'cheat', 1::smallint, me.id, null, me.settlement_id, '{}');
        res := 'caught';
      else
        update sim.agents set wealth = wealth + 15, honesty = greatest(0, honesty - 3) where id = me.id;
        res := 'cheated';
      end if;
    when 'slander' then
      if you.id is null then
        res := 'gone'; counts := false;
      else
        update sim.agents set reputation = greatest(0, reputation - 8) where id = you.id;
        update sim.agents set honesty = greatest(0, honesty - 3) where id = me.id;
        if u < 0.4 then
          -- It comes out who said it.
          update sim.agents set reputation = greatest(0, reputation - 10) where id = me.id;
          perform sim.log(p_tick, 'slander', 1::smallint, me.id, you.id, me.settlement_id, '{}');
          perform sim.quarrel(p_tick, you.id, me.id, 'a lie told behind their back', false);
          res := 'found';
        else
          res := 'slandered';
        end if;
      end if;
    when 'strike' then
      if you.id is null or you.settlement_id <> me.settlement_id then
        res := 'gone'; counts := false;
      else
        perform sim.quarrel(p_tick, me.id, you.id, 'an old grudge', true);
        res := 'struck';
        if u < 0.02 * w.crime_mult then
          perform sim.kill(p_tick, case when you.health < me.health then you.id else me.id end, 'Wounds');
        end if;
      end if;
    when 'idle' then
      update sim.agents set wealth = wealth - 10, trait_c = sim.clamp100(trait_c - 1) where id = me.id;
      update sim.agents set happiness = greatest(0, happiness - 2)
       where id = me.partner_id or ((mother_id = me.id or father_id = me.id) and home_id is not distinct from me.home_id);
      res := 'idled';
    when 'forsake' then
      update sim.agents set piety = sim.clamp100(piety - 6), happiness = greatest(0, happiness - 2) where id = me.id;
      res := 'forsook'; counts := false; -- a loss of faith, not a wrong done to anyone
    else
      res := 'gone'; counts := false;
  end case;

  if counts then
    -- It goes on the record, and an honest person feels it.
    update sim.agents set deeds_ill = least(30000, deeds_ill + 1),
           happiness = case when honesty >= 50 then greatest(0, happiness - 4) else happiness end
     where id = me.id;
  end if;
  perform sim.log(p_tick, 'whisper', 0::smallint, me.id, p_other, me.settlement_id,
                  jsonb_build_object('what', p_what, 'did', 'yield', 'result', res));
  return res;
end $$;

-- Every tick, for the people whose month it is: a kindness, a turning back, a whisper.
create or replace function sim.p_whispers(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  slot smallint := (p_tick % 120)::smallint;
  r sim.agents; pick record; nb record;
  odds double precision; whom text; willed boolean;
begin
  select * into w from sim.world where id = 1;
  if p_tick % 1440 = 3 then perform sim.tell_of_the_outcast(); end if;

  for r in
    select a.* from sim.agents a
    where a.bucket = slot and p_tick - a.birth_tick >= sim.age_of_reckoning()
    order by a.id
  loop
    continue when not exists (select 1 from sim.agents x where x.id = r.id); -- lost earlier this tick
    willed := sim.will(r.id, p_tick) is not null;

    if not willed then
      -- Ordinary goodness: sitting up with the sick, sharing with the poor. Someone with a mind of
      -- their own does these as deeds, when their player or their mind decides to.
      if sim.rnd(w.seed, 'kindness', r.id, p_tick) < 0.04 + 0.10 * r.trait_a / 100.0 + 0.05 * r.piety / 100.0 then
        select x.id, exists (select 1 from sim.infections i where i.agent_id = x.id and i.until_tick > p_tick) as sick into nb
          from sim.agents x
         where x.settlement_id = r.settlement_id and x.id <> r.id
         order by (exists (select 1 from sim.infections i where i.agent_id = x.id and i.until_tick > p_tick) or x.wealth < 20) desc,
                  sim.rnd(w.seed, 'kind-to', r.id, x.id + p_tick)
         limit 1;
        if nb.id is not null then
          update sim.agents set deeds_good = least(30000, deeds_good + 1) where id = r.id;
          update sim.agents set happiness = least(100, happiness + 3) where id = nb.id;
          perform sim.log(p_tick, 'kindness', (case when sim.rnd(w.seed, 'kind-told', r.id, p_tick) < 0.12 then 1 else 0 end)::smallint,
                          r.id, nb.id, r.settlement_id, jsonb_build_object('how', case when nb.sick then 'nursed' else 'shared' end));
        end if;
      end if;
      -- Turning back: the devout do not carry a wrong for long.
      if r.deeds_ill > 0 and sim.rnd(w.seed, 'repent', r.id, p_tick) < 0.03 + 0.25 * r.piety / 100.0 then
        perform sim.repent(p_tick, r.id);
      end if;
    end if;

    -- The whisper.
    continue when w.whisper_mult <= 0 or r.refuge_until > p_tick;
    continue when sim.rnd(w.seed, 'whisper', r.id, p_tick) >= 0.06 * w.whisper_mult;
    select * into pick from sim.whisper_for(r.id, p_tick);
    continue when pick.what is null;
    odds := sim.whisper_odds(r.id, pick.what);
    if willed then
      -- A person with a mind of their own hears it, and decides. One at a time, and not more than twice a year.
      continue when exists (select 1 from app.choices ch where ch.agent_id = r.id and ch.kind = 'whisper'
                              and (ch.status in ('open', 'asked', 'chosen') or ch.tick > p_tick - 720));
      whom := (select x.name from sim.agents x where x.id = pick.other);
      perform sim.offer(p_tick, r.id, 'whisper',
        jsonb_build_array(
          sim.opt('yield', case pick.what when 'take' then 'Take it from ' || whom when 'cheat' then 'Give short measure'
                                          when 'slander' then 'Tell the lie about ' || whom when 'strike' then 'Strike ' || whom
                                          when 'idle' then 'Leave the work to the others' else 'Stop praying' end),
          sim.opt('resist', 'Turn away'),
          sim.opt('refuge', 'Seek refuge with the Creator')),
        case when sim.rnd(w.seed, 'whisper-habit', r.id, p_tick) < odds then 'yield' when r.piety >= 65 then 'refuge' else 'resist' end,
        jsonb_strip_nulls(jsonb_build_object('what', pick.what, 'other', pick.other, 'line', sim.whisper_line(pick.what, whom))));
    else
      perform sim.do_whisper(p_tick, r.id, pick.what, pick.other,
        case when sim.rnd(w.seed, 'whisper-give', r.id, p_tick) < odds then 'yield' when r.piety >= 65 then 'refuge' else 'resist' end);
    end if;
  end loop;
end $$;



------------------------------------------------------------------------------
-- 3. Choices: the people who love you hold you back, and what was chosen happens
------------------------------------------------------------------------------
create or replace function sim.sway(p_tick integer, c app.choices) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  w sim.world; me sim.agents; par sim.agents; mate sim.agents; you sim.agents;
  yrs integer; want text; strength double precision := 0; who bigint; role text; sus double precision; vfood real;
begin
  if c.chosen_by = 'god' then return null; end if;  -- God's will is done
  select * into w from sim.world where id = 1;
  select * into me from sim.agents x where x.id = c.agent_id;
  if not found then return null; end if;
  yrs := (p_tick - me.birth_tick) / 1440;
  select s.food into vfood from sim.settlements s where s.id = me.settlement_id;
  -- The parent with the most say: a living one in the same village. The mother while small, then the parent of the same sex.
  select x.* into par from sim.agents x
   where x.id in (me.mother_id, me.father_id) and x.settlement_id = me.settlement_id
   order by case when yrs < 10 then x.id = me.mother_id else x.sex = me.sex end desc limit 1;
  if me.partner_id is not null then select * into mate from sim.agents x where x.id = me.partner_id; end if;
  if c.facts ? 'other' then select * into you from sim.agents x where x.id = (c.facts ->> 'other')::bigint; end if;

  case c.kind
    when 'year' then
      if par.id is not null then
        if yrs <= 3 then
          if par.id = me.mother_id then want := 'mother'; strength := 0.6; who := par.id; end if;
        elsif yrs <= 9 then
          if par.wealth < 60 or vfood < 0.8 then want := 'help'; strength := 0.6; who := par.id;
          elsif par.piety >= 65 then want := 'elders'; strength := 0.4; who := par.id; end if;
        elsif par.occupation in ('farmer', 'builder', 'healer') then
          want := case par.occupation when 'farmer' then 'farm' when 'builder' then 'build' else 'heal' end; strength := 0.5; who := par.id;
        end if;
      end if;
    when 'work' then
      if par.id is not null and yrs < 25 and par.occupation in ('farmer', 'builder', 'healer') then
        want := par.occupation; strength := 0.4; who := par.id;
      end if;
    when 'love' then
      if par.id is not null and you.id is not null
         and (you.reputation < 35 or exists (select 1 from sim.relationships l where l.a = least(par.id, you.id) and l.b = greatest(par.id, you.id) and l.kind = 'rival')) then
        want := 'decline'; strength := 0.5; who := par.id;
      end if;
    when 'wed' then
      if par.id is not null then want := 'marry'; strength := 0.3; who := par.id; end if;
    when 'child' then
      if mate.id is not null then
        want := case when mate.piety >= 50 or mate.trait_a >= 55 then 'yes' else 'no' end; strength := 0.5; who := mate.id;
      end if;
    when 'quarrel' then
      if mate.id is not null and mate.id is distinct from you.id then want := 'peace'; strength := 0.4; who := mate.id;
      elsif you.id is not null and you.trait_a < 40 then want := 'confront'; strength := 0.3; who := you.id;  -- provoked
      end if;
    when 'tempt' then
      if c.choice = 'endure' and vfood < 0.7 then want := 'take'; strength := 0.4; role := 'hunger';
      elsif c.choice = 'take' and par.id is not null then want := 'endure'; strength := 0.5; who := par.id;
      elsif c.choice = 'take' and mate.id is not null then want := 'endure'; strength := 0.4; who := mate.id;
      end if;
    when 'whisper' then
      -- The people who love you hold you back; hunger takes the Whisperer's side.
      if c.choice = 'yield' and mate.id is not null then want := 'resist'; strength := 0.5; who := mate.id;
      elsif c.choice = 'yield' and par.id is not null then want := 'resist'; strength := 0.5; who := par.id;
      elsif c.choice <> 'yield' and c.facts ->> 'what' = 'take' and vfood < 0.7 then want := 'yield'; strength := 0.4; role := 'hunger';
      end if;
    else null;
  end case;

  if want is null or want = c.choice or not exists (select 1 from jsonb_array_elements(c.options) e where e ->> 'id' = want) then
    return null;
  end if;
  role := coalesce(role, case when who = me.mother_id then 'mother' when who = me.father_id then 'father'
                              when who = me.partner_id then 'partner' else 'other' end);
  sus := case when yrs < 16 then 0.25 + 0.25 * me.trait_a / 100.0
              else greatest(0.03, least(0.45, 0.1 + 0.3 * me.trait_a / 100.0 * (0.5 + me.trait_n / 100.0) - 0.1 * me.trait_c / 100.0)) end;
  return jsonb_build_object('want', want, 'who', who, 'role', role,
    'name', (select x.name from sim.agents x where x.id = who),
    'won', sim.rnd(w.seed, 'sway', c.id) < sus * strength);
end $$;

create or replace function sim.settle(p_tick integer, p_choice bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world; c app.choices; m app.choices; me sim.agents; you sim.agents;
  sw jsonb; sw2 jsonb; did text; their text; res text; fu bigint; nabbed boolean;
begin
  select * into w from sim.world where id = 1;
  select * into c from app.choices x where x.id = p_choice and x.status = 'chosen' for update;
  if not found then return; end if;
  select * into me from sim.agents x where x.id = c.agent_id;
  if not found then
    update app.choices set status = 'void', settled_tick = p_tick where id = c.id;
    return;
  end if;
  if c.facts ? 'other' then select * into you from sim.agents x where x.id = (c.facts ->> 'other')::bigint; end if;

  -- Something two people with minds of their own decide waits until both have decided.
  if c.facts ? 'pair' then
    select * into m from app.choices x
     where x.id <> c.id and x.kind = c.kind and x.tick = c.tick and x.facts ->> 'pair' = c.facts ->> 'pair' and x.status <> 'void'
     order by x.id limit 1;
    if m.id is not null and m.status in ('open', 'asked') then return; end if;
  end if;

  sw := sim.sway(p_tick, c);
  did := case when coalesce((sw ->> 'won')::boolean, false) then sw ->> 'want' else c.choice end;
  if m.id is not null and m.status = 'chosen' then
    sw2 := sim.sway(p_tick, m);
    their := case when coalesce((sw2 ->> 'won')::boolean, false) then sw2 ->> 'want' else m.choice end;
  end if;

  case c.kind
    when 'year' then
      perform sim.grow(p_tick, me.id, did);
      res := did;
    when 'work' then
      update sim.agents set occupation = did where id = me.id;
      update sim.world set roster_version = roster_version + 1 where id = 1;
      perform sim.log(p_tick, 'work', 1::smallint, me.id, null, me.settlement_id, jsonb_build_object('work', did));
      res := did;
    when 'love' then
      their := coalesce(their, case when sim.rnd(w.seed, 'yes', you.id, me.id) < 0.8 then 'accept' else 'decline' end);
      -- Love may cross from one village to another now: only someone gone, or already taken, ends it.
      if you.id is null or me.partner_id is not null or you.partner_id is not null then
        res := 'gone';
      elsif did = 'accept' and their = 'accept' then
        perform sim.unite(p_tick, me.id, you.id);
        -- People with minds of their own decide together when to have children.
        update sim.agents set desired_kids = kids where id in (me.id, you.id) and sex = 'F';
        res := 'together';
      else
        res := 'apart';
      end if;
    when 'wed' then
      fu := (c.facts ->> 'union')::bigint;
      their := coalesce(their, 'marry');
      if did = 'marry' and their = 'marry' and exists (select 1 from sim.unions u where u.id = fu and u.end_tick is null and u.kind = 'partner') then
        update sim.unions set kind = 'married' where id = fu;
        perform sim.log(p_tick, 'wedding', 2::smallint, (select u.female_id from sim.unions u where u.id = fu),
                        (select u.male_id from sim.unions u where u.id = fu), me.settlement_id, '{}');
        res := 'married';
      else
        res := 'waiting';
      end if;
    when 'child' then
      update sim.agents set desired_kids = case when did = 'yes' then greatest(desired_kids, kids + 1) else least(desired_kids, kids) end
       where id = case when me.sex = 'F' then me.id else me.partner_id end;
      res := did;
    when 'quarrel' then
      their := coalesce(their, case
        when did = 'peace' and sim.rnd(w.seed, 'forgive', c.id) < 0.35 + coalesce(you.trait_a, 0) / 200.0 then 'peace'
        when coalesce(you.trait_a, 100) < 30 and sim.rnd(w.seed, 'provoke', c.id) < 0.2 then 'confront'
        else 'distance' end);
      if you.id is null then
        res := 'gone';
      elsif did = 'confront' or their = 'confront' then
        if did = 'confront' then perform sim.quarrel(p_tick, me.id, you.id, coalesce(c.facts ->> 'about', 'an old grudge'), true);
        else perform sim.quarrel(p_tick, you.id, me.id, coalesce(c.facts ->> 'about', 'an old grudge'), true); end if;
        res := 'fought';
        if sim.rnd(w.seed, 'wound', c.id) < 0.02 * w.crime_mult then
          perform sim.kill(p_tick, case when you.health < me.health then you.id else me.id end, 'Wounds');
        end if;
      elsif did = 'peace' and their = 'peace' then
        perform sim.reconcile(p_tick, me.id, you.id);
        res := 'reconciled';
      elsif did = 'peace' then
        update sim.relationships set affinity = greatest(-100, affinity - 5) where a = least(me.id, you.id) and b = greatest(me.id, you.id);
        res := 'rebuffed';
      else
        update sim.relationships set affinity = least(0, affinity + 3) where a = least(me.id, you.id) and b = greatest(me.id, you.id);
        res := 'apart';
      end if;
    when 'tempt' then
      if did = 'take' and you.id is not null then
        nabbed := sim.rnd(w.seed, 'caught', c.id) < least(0.9, 0.45
                    + case when (select s.pop from sim.settlements s where s.id = me.settlement_id) < 40 then 0.3 else 0 end
                    + case when me.reputation < 40 then 0.1 else 0 end);
        perform sim.steal(p_tick, me.id, you.id, least(80, greatest(you.wealth, 0) / 5), nabbed);
        res := case when nabbed then 'caught' else 'took' end;
      else
        update sim.agents set happiness = greatest(0, happiness - 3), honesty = least(100, honesty + 2) where id = me.id;
        res := 'endured';
      end if;
    when 'whisper' then
      res := sim.do_whisper(p_tick, me.id, c.facts ->> 'what', (c.facts ->> 'other')::bigint, did);
    when 'sign' then
      if did = 'heed' then
        update sim.agents set piety = sim.clamp100(piety + 5), happiness = sim.clamp100(happiness + 5) where id = me.id;
        perform sim.log(p_tick, 'sign', 1::smallint, me.id, null, me.settlement_id, '{}');
        res := 'heeded';
      else
        res := 'ignored';
      end if;
    else
      res := did;
  end case;

  update app.choices set status = 'settled', settled_tick = p_tick,
         outcome = jsonb_strip_nulls(jsonb_build_object('did', did, 'their', their, 'sway', sw, 'result', res))
   where id = c.id;
  if m.id is not null and m.status = 'chosen' then
    update app.choices set status = 'settled', settled_tick = p_tick,
           outcome = jsonb_strip_nulls(jsonb_build_object('did', their, 'their', did, 'sway', sw2, 'result', res))
     where id = m.id;
  end if;
end $$;

------------------------------------------------------------------------------
-- 4. The record goes with a person to the end
------------------------------------------------------------------------------
create or replace function sim.kill(p_tick integer, p_id bigint, p_cause text) returns void
language plpgsql security definer set search_path = '' as $$
declare ag sim.agents;
begin
  delete from sim.agents where id = p_id returning * into ag;
  if not found then return; end if;
  insert into sim.dead (id, name, surname, sex, birth_tick, death_tick, cause, mother_id, father_id, lineage,
                        generation, is_founder, settlement_id, occupation, kids, soul_id, notable,
                        deeds_good, deeds_ill, deeds_mended)
  values (ag.id, ag.name, ag.surname, ag.sex, ag.birth_tick, p_tick, p_cause, ag.mother_id, ag.father_id, ag.lineage,
          ag.generation, ag.is_founder, ag.settlement_id, ag.occupation, ag.kids, ag.soul_id,
          ag.is_founder or ag.soul_id is not null or ag.kids >= 8,
          ag.deeds_good, ag.deeds_ill, ag.deeds_mended);
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
                                     'name', ag.name || ' ' || ag.surname,
                                     'record', sim.weigh(ag.deeds_good, ag.deeds_ill, (p_tick - ag.birth_tick) / 1440)));
end $$;

-- The tick: the Whisperer goes round after the neighbours have had their say.
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
  perform sim.p_whispers(p_tick);
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

-- First times are history; being found out is a story the village tells.
create or replace function sim.log(p_tick integer, p_kind text, p_importance smallint, p_agent bigint,
                                   p_other bigint, p_settlement integer, p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare
  eid bigint := nextval('sim.event_id_seq');
  imp smallint := p_importance;
  body jsonb := coalesce(p_data, '{}');
begin
  if imp < 3 and p_kind in ('birth', 'death', 'union', 'wedding', 'outbreak', 'weather', 'harvest', 'built',
                            'friends', 'quarrel', 'fight', 'theft', 'judged', 'reconciled', 'nature', 'pioneers',
                            'cheat', 'slander', 'repent', 'kindness')
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
    when p_kind in ('fight', 'judged', 'reconciled', 'cheat', 'slander', 'repent') and not crowded then job := 'story'; rank := 5;
    when p_kind = 'kindness' and p_imp >= 1 and not crowded then job := 'story'; rank := 5;
    when p_kind = 'quarrel' and p_imp >= 3 then job := 'story'; rank := 5;
    when p_kind = 'prayer' and not crowded and not coalesce((p_data ->> 'soul')::boolean, false) then job := 'prayer'; rank := 6;
    else return;
  end case;
  insert into llm.jobs (kind, priority, tick, event_id, event_tick, agent_id, other_id, settlement_id, context)
  values (job, rank, p_tick, p_id, p_tick, p_agent, p_other, p_settlement, jsonb_build_object('event', p_kind, 'data', p_data));
end $$;

------------------------------------------------------------------------------
-- 5. Players: asking forgiveness, and good deeds that count
------------------------------------------------------------------------------
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
  -- Whoever carries a wrong can lay it down.
  if me.deeds_ill > 0 then list := list || sim.deed('repent', 'Ask the Creator''s forgiveness'); end if;
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
    when 'repent' then
      n := sim.repent(t, me.id);
      told := case when n > 0 then 'You asked forgiveness for what you did, and meant it. You feel lighter.'
                   else 'You have nothing on your conscience today.' end;
    else
      raise exception 'You cannot do that right now';
  end case;

  -- Good done to others goes on the record, once a person is old enough to answer for themselves.
  if p_deed in ('help', 'give', 'teach', 'peace', 'plant') then
    update sim.agents set deeds_good = least(30000, deeds_good + 1) where id = me.id and t - birth_tick >= sim.age_of_reckoning();
  end if;

  insert into app.deeds (soul_id, agent_id, tick, kind, other_id, told) values (o.id, me.id, t, p_deed, you.id, told);
  -- A quiet event: the person's mind and page know it, the public feed does not.
  perform sim.log(t, 'deed', 0::smallint, me.id, you.id, me.settlement_id, jsonb_build_object('deed', p_deed));
  return told;
end $$;

-- A page says how someone left the world. A mind knows its own conscience. A player sees their record.
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
    -- How they left the world. A living person's record is between them and the Creator.
    'reckoning', (select sim.weigh(d.deeds_good, d.deeds_ill, (d.death_tick - d.birth_tick) / 1440) from sim.dead d where d.id = p.id),
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
                             'conscience', case when t - me.birth_tick < sim.age_of_reckoning() then null when me.deeds_ill = 0 then 'clear'
                                                when me.deeds_ill <= 2 then 'uneasy' else 'heavy' end,
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

create or replace function api.my_life() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t integer := (select w.tick from sim.world w where w.id = 1);
  o app.souls; me sim.agents; base jsonb;
begin
  if uid is null then return null; end if;
  base := jsonb_build_object('tick', t,
    'key', (select jsonb_build_object('provider', k.provider, 'model', k.model, 'last4', k.last4, 'status', k.status,
                                      'cap', k.daily_cap, 'used', case when k.used_day = current_date then k.used else 0 end)
            from secrets.ai_keys k where k.user_id = uid),
    'freeDays', not exists (select 1 from app.souls x where x.user_id = uid and x.trial_until is not null),
    'expecting', (select count(*) from sim.pregnancies g where g.outcome is null and g.soul_id is null));
  select * into o from app.souls s where s.user_id = uid order by s.id desc limit 1;
  if o.id is null then return base; end if;
  base := base || coalesce(api.my_soul(), '{}')
               || jsonb_build_object('mind', app.soul_mind(o.id, t), 'trialUntil', o.trial_until, 'bornTick', o.born_tick,
                                     'requestedTick', o.requested_tick);
  if o.status <> 'living' then
    -- A life that has ended: how it weighed.
    return base || jsonb_build_object('reckoning',
      (select sim.weigh(d.deeds_good, d.deeds_ill, (d.death_tick - d.birth_tick) / 1440) from sim.dead d where d.soul_id = o.id order by d.death_tick desc limit 1));
  end if;
  select * into me from sim.agents x where x.id = o.agent_id;
  if not found then return base; end if;
  return base || jsonb_build_object(
    'person', jsonb_strip_nulls(jsonb_build_object('id', me.id, 'sex', me.sex, 'birthTick', me.birth_tick, 'work', me.occupation,
       'health', me.health, 'happiness', me.happiness, 'wealth', me.wealth, 'piety', me.piety, 'calling', me.calling,
       'place', (select s.name from sim.settlements s where s.id = me.settlement_id),
       'mother', (select jsonb_build_object('id', p.id, 'name', p.name || ' ' || p.surname, 'alive', p.alive) from sim.people p where p.id = me.mother_id),
       'father', (select jsonb_build_object('id', p.id, 'name', p.name || ' ' || p.surname, 'alive', p.alive) from sim.people p where p.id = me.father_id),
       'partner', (select jsonb_build_object('id', x.id, 'name', x.name || ' ' || x.surname) from sim.agents x where x.id = me.partner_id),
       'children', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'alive', p.alive) order by p.birth_tick), '[]')
                    from sim.people p where p.mother_id = me.id or p.father_id = me.id),
       'need', sim.need_of(me.id, t),
       'record', case when t - me.birth_tick >= sim.age_of_reckoning()
                      then jsonb_build_object('good', me.deeds_good, 'ill', me.deeds_ill, 'mended', me.deeds_mended) end,
       'refuge', case when me.refuge_until > t then me.refuge_until end,
       'openPrayer', exists (select 1 from app.prayers p where p.agent_id = me.id and p.status = 'open'))),
    'choices', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', c.id, 'kind', c.kind, 'tick', c.tick, 'dueTick', c.due_tick,
                   'options', c.options, 'facts', c.facts - 'pair' - 'union',
                   'otherName', (select p.name || ' ' || p.surname from sim.people p where p.id = (c.facts ->> 'other')::bigint),
                   'status', c.status, 'choice', c.choice, 'by', c.chosen_by, 'thought', c.thought, 'outcome', c.outcome)) order by c.id desc), '[]')
                from (select * from app.choices x where x.soul_id = o.id order by x.id desc limit 12) c),
    'thoughts', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('tick', th.tick, 'kind', th.kind, 'body', th.body, 'question', th.question)) order by th.id desc), '[]')
                 from (select * from app.thoughts x where x.soul_id = o.id order by x.id desc limit 10) th),
    'deeds', case when app.soul_mind(o.id, t) <> 'none' then sim.deeds_for(me.id, t) else '[]'::jsonb end,
    'deedsLeft', greatest(0, 4 - (select count(*) from app.deeds d where d.soul_id = o.id and d.tick > t - 1440)),
    'asksLeft', greatest(0, 3 - (select count(*) from llm.jobs j where j.soul_id = o.id and j.kind = 'mind_ask' and j.tick > t - 1440)),
    'asking', exists (select 1 from llm.jobs j where j.soul_id = o.id and j.kind = 'mind_ask' and j.status in ('queued', 'running')),
    'done', (select coalesce(jsonb_agg(jsonb_build_object('tick', d.tick, 'kind', d.kind, 'told', d.told) order by d.id desc), '[]')
             from (select * from app.deeds x where x.soul_id = o.id order by x.id desc limit 6) d),
    'prayers', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('tick', p.tick, 'need', p.need, 'words', p.words, 'status', p.status)) order by p.id desc), '[]')
                from (select * from app.prayers x where x.agent_id = me.id order by x.id desc limit 5) p),
    'happened', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'tick', e.tick, 'kind', e.kind, 'imp', e.importance,
                    'agent', e.agent_id, 'other', e.other_id, 'settlement', e.settlement_id, 'data', e.data - 'said',
                    'agentName', (select p.name || ' ' || p.surname from sim.people p where p.id = e.agent_id),
                    'otherName', (select p.name || ' ' || p.surname from sim.people p where p.id = e.other_id)) order by e.tick desc, e.id desc), '[]')
                 from (select * from sim.events v where (v.agent_id = me.id or v.other_id = me.id) and v.tick >= t - 30 * 1440
                       order by v.tick desc, v.id desc limit 12) e));
end $$;

------------------------------------------------------------------------------
-- 6. The Creator's console
------------------------------------------------------------------------------
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
    whisper_mult   = coalesce((p ->> 'whisper_mult')::real, whisper_mult),
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
-- What the Whisperer has been doing, for the Creator's eyes only.
create or replace function api.god_whisperer() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare t integer := (select tick from sim.world);
begin
  perform app.assert_god();
  return jsonb_build_object(
    'mult', (select whisper_mult from sim.world),
    -- the past EON year
    'whispers', (select count(*) from sim.events e where e.kind = 'whisper' and e.tick > t - 1440),
    'yielded', (select count(*) from sim.events e where e.kind = 'whisper' and e.tick > t - 1440 and e.data ->> 'did' = 'yield'),
    'refuge', (select count(*) from sim.events e where e.kind = 'whisper' and e.tick > t - 1440 and e.data ->> 'did' = 'refuge'),
    'repented', (select count(*) from sim.events e where e.kind = 'repent' and e.tick > t - 1440),
    'kindness', (select count(*) from sim.events e where e.kind = 'kindness' and e.tick > t - 1440),
    'by', coalesce((select jsonb_object_agg(k.what, k.n) from (
             select e.data ->> 'what' as what, count(*) as n from sim.events e
             where e.kind = 'whisper' and e.tick > t - 1440 and e.data ->> 'did' = 'yield' and e.data ->> 'what' is not null group by 1) k), '{}'),
    'waiting', (select count(*) from app.choices c where c.kind = 'whisper' and c.status in ('open', 'asked')),
    'heaviest', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name || ' ' || x.surname, 'good', x.deeds_good, 'ill', x.deeds_ill, 'mended', x.deeds_mended)) from (
                  select * from sim.agents a where a.deeds_ill > 0 order by a.deeds_good - 3 * a.deeds_ill, a.id limit 6) x), '[]'),
    'lightest', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name || ' ' || x.surname, 'good', x.deeds_good, 'ill', x.deeds_ill, 'mended', x.deeds_mended)) from (
                  select * from sim.agents a where a.deeds_good > 0 order by a.deeds_good - 3 * a.deeds_ill desc, a.id limit 6) x), '[]'));
end $$;

revoke all on function sim.age_of_reckoning(), sim.weigh(integer, integer, integer), sim.tell_of_the_outcast(), sim.whisper_for(bigint, integer),
  sim.whisper_odds(bigint, text), sim.whisper_line(text, text), sim.repent(integer, bigint),
  sim.do_whisper(integer, bigint, text, bigint, text), sim.p_whispers(integer) from public, anon, authenticated;
revoke all on function api.god_whisperer() from public, anon;
grant execute on function api.god_whisperer() to authenticated;

