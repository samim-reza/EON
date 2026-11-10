-- Things to do. Someone with a mind of their own can act a few times a day, not only choose when
-- life asks: cuddle a parent, play with another child, help with the chores, work hard, visit a
-- friend, help a neighbour, try to make peace, look for love. Each act changes the world a little
-- at once, and the person's mind remembers it. A player can also ask their person a question
-- (from a fixed list, so no player's words ever reach an AI) and their own mind answers.

create table app.deeds (
  id       bigserial primary key,
  soul_id  bigint not null references app.souls on delete cascade,
  agent_id bigint not null,
  tick     integer not null,
  kind     text not null check (char_length(kind) <= 12),
  other_id bigint,
  told     text not null check (char_length(told) <= 300)
);
create index on app.deeds (soul_id, tick desc);

alter table app.thoughts drop constraint if exists thoughts_kind_check;
alter table app.thoughts add constraint thoughts_kind_check check (kind in ('day', 'choice', 'answer'));
alter table app.thoughts add column question text check (question in ('feel', 'want', 'family', 'creator'));
alter table llm.jobs drop constraint if exists jobs_kind_check;
alter table llm.jobs add constraint jobs_kind_check
  check (kind in ('obituary', 'birth', 'discovery', 'prayer', 'story', 'diary', 'news', 'mind_choice', 'mind_day', 'mind_prayer', 'mind_ask'));

create or replace function sim.deed(p_id text, p_label text, p_other bigint default null) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_strip_nulls(jsonb_build_object('id', p_id, 'label', p_label, 'other', p_other))
$$;

-- What someone could do right now, given their age, family and neighbours.
create or replace function sim.deeds_for(p_agent bigint, p_tick integer) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  w sim.world; me sim.agents; yrs integer; list jsonb := '[]';
  mom sim.agents; dad sim.agents; parent sim.agents; x record;
begin
  select * into w from sim.world where id = 1;
  select * into me from sim.agents a where a.id = p_agent;
  if not found then return '[]'; end if;
  yrs := (p_tick - me.birth_tick) / 1440;
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
  return list;
end $$;

-- Does it. Four deeds in any real day.
create or replace function api.do_deed(p_deed text, p_other bigint default null) returns text
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  w sim.world; t integer; o app.souls; me sim.agents; you sim.agents;
  ok boolean; told text; u double precision; n integer; cand bigint;
  min_age int; gap int; p jsonb := (select value from sim.params where key = 'demography');
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
    else
      raise exception 'You cannot do that right now';
  end case;

  insert into app.deeds (soul_id, agent_id, tick, kind, other_id, told) values (o.id, me.id, t, p_deed, you.id, told);
  -- A quiet event: the person's mind and page know it, the public feed does not.
  perform sim.log(t, 'deed', 0::smallint, me.id, you.id, me.settlement_id, jsonb_build_object('deed', p_deed));
  return told;
end $$;

-- Asks the person something. Their own mind answers within a minute or two. Three a day.
create or replace function api.ask_mind(p_question text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t integer := (select w.tick from sim.world w where w.id = 1); o app.souls;
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_question is null or p_question not in ('feel', 'want', 'family', 'creator') then raise exception 'Ask one of the questions'; end if;
  perform app.hit('ask:' || uid::text, 10, interval '1 hour');
  select * into o from app.souls s where s.user_id = uid and s.status = 'living';
  if not found then raise exception 'You are not alive in EON'; end if;
  if app.soul_mind(o.id, t) = 'none' then raise exception 'Connect your own AI to talk with them again'; end if;
  if (select count(*) from llm.jobs j where j.soul_id = o.id and j.kind = 'mind_ask' and j.tick > t - 1440) >= 3 then
    raise exception 'Let them be for now. You can ask again tomorrow.';
  end if;
  insert into llm.jobs (kind, priority, tick, agent_id, soul_id, context)
  values ('mind_ask', 3, t, o.agent_id, o.id, jsonb_build_object('question', p_question));
end $$;


-- The mind sees what the person did lately, and the question it was asked.
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
                             'faith', me.piety, 'honesty', me.honesty, 'diagnosed', me.diagnosed,
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
                                        'food', round(s.food::numeric, 2))
              from sim.settlements s where s.id = me.settlement_id),
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

create or replace function api.minds_finish_soul(p_job bigint, p_choice text, p_text text, p_prayer text,
                                                 p_in integer, p_out integer, p_problem text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  j llm.jobs; c app.choices; me sim.agents;
  t integer := (select w.tick from sim.world w where w.id = 1);
  vtext text := left(nullif(trim(coalesce(p_text, '')), ''), 300);
  vprayer text := left(nullif(trim(coalesce(p_prayer, '')), ''), 300);
  cost numeric := (greatest(p_in, 0) * 0.10 + greatest(p_out, 0) * 0.50) / 1000000;
  holder uuid; pid bigint;
begin
  update llm.jobs set status = case when vtext is null and p_choice is null then 'failed' else 'done' end
   where id = p_job and status = 'running' and soul_id is not null returning * into j;
  if not found then return; end if;
  if j.reserved > 0 then
    update llm.budget b set reserved = greatest(0, b.reserved - j.reserved), spent = b.spent + cost,
                            lines = b.lines + case when vtext is null then 0 else 1 end,
                            tokens_in = b.tokens_in + greatest(p_in, 0), tokens_out = b.tokens_out + greatest(p_out, 0)
     where b.day = j.claimed_at::date;
  else
    holder := (select o.user_id from app.souls o where o.id = j.soul_id);
    if p_problem in ('invalid', 'limited', 'error') then
      update secrets.ai_keys set status = p_problem, checked_at = now() where user_id = holder;
    elsif vtext is not null or p_choice is not null then
      update secrets.ai_keys set status = 'ok', checked_at = now() where user_id = holder and status <> 'ok';
    end if;
  end if;

  if j.kind = 'mind_choice' then
    select * into c from app.choices x where x.id = j.choice_id;
    if c.status = 'asked' and exists (select 1 from jsonb_array_elements(c.options) e where e ->> 'id' = p_choice) then
      update app.choices set status = 'chosen', choice = p_choice, chosen_by = 'mind', thought = vtext where id = c.id;
    elsif c.id is not null and c.thought is null and vtext is not null then
      update app.choices set thought = vtext where id = c.id;
    end if;
    if vtext is not null then
      insert into app.thoughts (soul_id, agent_id, tick, kind, body, choice_id) values (j.soul_id, j.agent_id, t, 'choice', vtext, j.choice_id);
    end if;
  elsif j.kind = 'mind_day' then
    if vtext is not null then
      insert into app.thoughts (soul_id, agent_id, tick, kind, body) values (j.soul_id, j.agent_id, t, 'day', vtext);
    end if;
    select * into me from sim.agents x where x.id = j.agent_id;
    if vprayer is not null and me.id is not null and t - me.birth_tick >= 4 * 1440
       and not exists (select 1 from app.prayers p where p.agent_id = me.id and p.status = 'open') then
      insert into app.prayers (tick, agent_id, settlement_id, need, words)
      values (t, me.id, me.settlement_id, coalesce(sim.need_of(me.id, t), 'thanks'), vprayer) returning id into pid;
      perform sim.log(t, 'prayer', 1::smallint, me.id, null, me.settlement_id,
                      jsonb_build_object('need', (select p.need from app.prayers p where p.id = pid), 'soul', true));
    end if;
  elsif j.kind = 'mind_ask' then
    if vtext is not null then
      insert into app.thoughts (soul_id, agent_id, tick, kind, body, question)
      values (j.soul_id, j.agent_id, t, 'answer', vtext, j.context ->> 'question');
    end if;
  elsif j.kind = 'mind_prayer' then
    update app.prayers set words = coalesce(vprayer, app.prayers.words) where id = j.prayer_id and app.prayers.words is null;
  end if;
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
  if o.status <> 'living' then return base; end if;
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

revoke all on function sim.deed(text, text, bigint), sim.deeds_for(bigint, integer) from public, anon, authenticated;
revoke all on function api.do_deed(text, bigint), api.ask_mind(text), api.my_life(), api.minds_finish_soul(bigint, text, text, text, integer, integer, text)
  from public, anon, authenticated;
grant execute on function api.do_deed(text, bigint), api.ask_mind(text), api.my_life() to authenticated;
grant execute on function api.minds_finish_soul(bigint, text, text, text, integer, integer, text) to service_role;
