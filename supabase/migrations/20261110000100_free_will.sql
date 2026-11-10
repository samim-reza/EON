-- Free will.
--
-- A person with a soul (a player's) has a mind of their own, and no one else in EON decides for
-- them. At the big moments of life, and once a year while they grow up, they get a choice. The
-- player makes it. If the player has not answered within six real hours, the person's own mind
-- makes it: the player's AI, or EON's own for the first three days of a first life. With no mind at
-- all, habit decides, which is what everyone without a soul does anyway.
--
-- A choice is an intention, not an outcome. The people closest to them pull too (a mother, a
-- partner, a rival, hunger), and sometimes they give in. God can overrule any choice, and can send
-- a sign, which the person may heed or ignore.

------------------------------------------------------------------------------
-- 1. Tables
------------------------------------------------------------------------------
alter table app.souls add column born_tick integer;
alter table app.souls add column trial_until integer;  -- EON's own mind thinks for them until this tick

-- What a child learned while growing up. By habit, it becomes their work.
alter table sim.agents add column calling text check (calling in ('farmer', 'builder', 'healer'));

-- Prayers in the person's own words, and prayers of thanks.
alter table app.prayers add column words text check (char_length(words) <= 300);
alter table app.prayers drop constraint if exists prayers_need_check;
alter table app.prayers add constraint prayers_need_check check (need in ('health', 'food', 'child', 'safety', 'peace', 'thanks'));

create table app.choices (
  id           bigserial primary key,
  soul_id      bigint not null references app.souls on delete cascade,
  agent_id     bigint not null,
  kind         text not null check (kind in ('year', 'work', 'love', 'wed', 'child', 'quarrel', 'tempt', 'sign')),
  tick         integer not null,
  due_tick     integer not null,      -- the player may choose until then; then the mind has two hours
  options      jsonb not null,        -- [{"id": "help", "label": "Help your family"}, ...]
  facts        jsonb not null default '{}',
  habit        text not null,         -- what they would do by nature
  status       text not null default 'open' check (status in ('open', 'asked', 'chosen', 'settled', 'void')),
  choice       text,
  chosen_by    text check (chosen_by in ('player', 'mind', 'habit', 'god')),
  thought      text check (char_length(thought) <= 300),
  outcome      jsonb,
  settled_tick integer
);
create index on app.choices (soul_id, id desc);
create index on app.choices (agent_id, kind, tick);
create index choices_pending on app.choices (status, due_tick) where status in ('open', 'asked', 'chosen');

-- A soul's inner life, in its own words. Private to the player and God.
create table app.thoughts (
  id        bigserial primary key,
  soul_id   bigint not null references app.souls on delete cascade,
  agent_id  bigint not null,
  tick      integer not null,
  kind      text not null check (kind in ('day', 'choice')),
  body      text not null check (char_length(body) between 1 and 300),
  choice_id bigint
);
create index on app.thoughts (soul_id, id desc);

-- Emails to players: "you are born", and "your free days are over".
create table app.outbox (
  id         bigserial primary key,
  user_id    uuid not null references auth.users on delete cascade,
  soul_id    bigint not null references app.souls on delete cascade,
  kind       text not null check (kind in ('born', 'trial_over')),
  status     text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed')),
  tries      smallint not null default 0,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (soul_id, kind)
);
create index on app.outbox (id) where status = 'queued';

-- A player's own AI key. Encrypted in the app (AES-256-GCM) with a key that never reaches the
-- database, so a copy of this table alone reveals nothing. No client role can read it.
create table secrets.ai_keys (
  user_id     uuid primary key references auth.users on delete cascade,
  provider    text not null check (provider in ('anthropic', 'gemini', 'openai', 'groq', 'deepseek', 'xai')),
  model       text not null check (char_length(model) between 1 and 100),
  ciphertext  text not null check (char_length(ciphertext) <= 1000),
  iv          text not null check (char_length(iv) <= 64),
  tag         text not null check (char_length(tag) <= 64),
  kek_version smallint not null default 1,
  last4       text not null check (char_length(last4) = 4),
  status      text not null default 'ok' check (status in ('ok', 'limited', 'error', 'invalid')),
  daily_cap   smallint not null default 40 check (daily_cap between 5 and 500),
  used_day    date,
  used        smallint not null default 0,
  checked_at  timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
revoke all on secrets.ai_keys from public, anon, authenticated;

alter table llm.jobs drop constraint if exists jobs_kind_check;
alter table llm.jobs add constraint jobs_kind_check
  check (kind in ('obituary', 'birth', 'discovery', 'prayer', 'story', 'diary', 'news', 'mind_choice', 'mind_day', 'mind_prayer'));
alter table llm.jobs add column soul_id bigint;
alter table llm.jobs add column choice_id bigint;
alter table llm.jobs add column prayer_id bigint;
create index on llm.jobs (soul_id, kind, tick) where soul_id is not null;

-- The souls already alive get their three free days from now: none of this existed when they were born.
update app.souls o set born_tick = a.birth_tick, trial_until = w.tick + 3 * 1440
  from sim.agents a, sim.world w
 where w.id = 1 and a.id = o.agent_id and o.status = 'living';

------------------------------------------------------------------------------
-- 2. Being born: the clock for the free days starts, and the player hears about it
------------------------------------------------------------------------------
create or replace function app.on_soul_born() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.born_tick := (select w.tick from sim.world w where w.id = 1);
  -- EON thinks for the first three days of a player's first life. After that, their own AI does.
  new.trial_until := case
    when exists (select 1 from app.souls x where x.user_id = new.user_id and x.id <> new.id and x.trial_until is not null) then null
    else new.born_tick + 3 * 1440 end;
  insert into app.outbox (user_id, soul_id, kind) values (new.user_id, new.id, 'born') on conflict do nothing;
  return new;
end $$;
drop trigger if exists eon_soul_born on app.souls;
create trigger eon_soul_born before update of status on app.souls
  for each row when (old.status <> 'living' and new.status = 'living') execute function app.on_soul_born();

------------------------------------------------------------------------------
-- 3. Who has a mind right now
------------------------------------------------------------------------------
-- 'world': EON's own mind (the free days), 'own': the player's AI, 'none': habit only.
create or replace function app.soul_mind(p_soul bigint, p_tick integer) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case
      when o.status <> 'living' then 'none'
      when o.trial_until is not null and p_tick < o.trial_until then 'world'
      when exists (select 1 from secrets.ai_keys k where k.user_id = o.user_id and k.status <> 'invalid') then 'own'
      else 'none'
    end
    from app.souls o where o.id = p_soul), 'none');
$$;

-- The soul of someone who can choose right now, or null: then they live by habit like anyone else.
create or replace function sim.will(p_agent bigint, p_tick integer) returns bigint
language sql stable security definer set search_path = '' as $$
  select a.soul_id from sim.agents a
  where a.id = p_agent and a.controller = 'soul' and app.soul_mind(a.soul_id, p_tick) <> 'none';
$$;

create or replace function sim.opt(p_id text, p_label text) returns jsonb
language sql immutable set search_path = '' as $$ select jsonb_build_object('id', p_id, 'label', p_label) $$;

-- Puts a choice in front of someone with a mind of their own. Returns null for everyone else, and
-- the caller lets nature decide for them.
create or replace function sim.offer(p_tick integer, p_agent bigint, p_kind text, p_options jsonb, p_habit text,
                                     p_facts jsonb default '{}', p_window integer default 360) returns bigint
language plpgsql security definer set search_path = '' as $$
declare soul bigint := sim.will(p_agent, p_tick); cid bigint;
begin
  if soul is null then return null; end if;
  insert into app.choices (soul_id, agent_id, kind, tick, due_tick, options, facts, habit)
  values (soul, p_agent, p_kind, p_tick, p_tick + p_window, p_options, coalesce(p_facts, '{}'), p_habit)
  returning id into cid;
  return cid;
end $$;

-- The trade a parent would hand down: the parent of the same sex first.
create or replace function sim.family_trade(p_agent bigint) returns text
language sql stable security definer set search_path = '' as $$
  select x.occupation from sim.agents me join sim.agents x on x.id in (me.father_id, me.mother_id)
  where me.id = p_agent and x.occupation in ('farmer', 'builder', 'healer')
  order by (x.sex = me.sex) desc limit 1;
$$;

-- What someone would pray for, if anything.
create or replace function sim.need_of(p_agent bigint, p_tick integer) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when me.diagnosed is not null or exists (select 1 from sim.infections i where i.agent_id = me.id and i.until_tick > p_tick) then 'health'
    when s.food < 0.7 or me.wealth < 0 then 'food'
    when me.sex = 'F' and me.partner_id is not null and me.kids = 0 and p_tick - me.birth_tick between 20 * 1440 and 44 * 1440
         and not exists (select 1 from sim.pregnancies g where g.mother_id = me.id and g.outcome is null) then 'child'
    when exists (select 1 from sim.relationships l where (l.a = me.id or l.b = me.id) and l.kind = 'rival' and l.affinity <= -30) then 'peace'
    when s.wx_kind in ('blizzard', 'thunderstorm', 'sandstorm', 'downpour') then 'safety'
  end
  from sim.agents me join sim.settlements s on s.id = me.settlement_id where me.id = p_agent;
$$;

------------------------------------------------------------------------------
-- 4. Growing up: one choice a year, then work, and the hope for a child
------------------------------------------------------------------------------
create or replace function sim.p_growing(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  slot smallint := (p_tick % 120)::smallint;
  r record; yrs integer; opts jsonb; usual text; fem sim.agents;
begin
  for r in
    select x.*, s.food as vfood from sim.agents x join sim.settlements s on s.id = x.settlement_id
    where x.bucket = slot and x.controller = 'soul'
  loop
    continue when sim.will(r.id, p_tick) is null;  -- without a mind of their own, they live by habit
    yrs := (p_tick - r.birth_tick) / 1440;

    if yrs between 1 and 15
       and not exists (select 1 from app.choices c where c.agent_id = r.id and c.kind = 'year' and (c.facts ->> 'age')::int = yrs) then
      if yrs <= 3 then
        opts := jsonb_build_array(sim.opt('mother', 'Stay close to your mother'), sim.opt('animals', 'Toddle after the animals'),
                                  sim.opt('children', 'Follow the bigger children'), sim.opt('fire', 'Sit by the fire and watch'));
        usual := case greatest(r.trait_a, r.trait_o, r.trait_e, r.trait_c)
                   when r.trait_e then 'children' when r.trait_o then 'animals' when r.trait_a then 'mother' else 'fire' end;
      elsif yrs <= 9 then
        opts := jsonb_build_array(sim.opt('help', 'Help your family at home and in the fields'), sim.opt('play', 'Play with the other children'),
                                  sim.opt('explore', 'Wander and explore beyond the houses'),
                                  sim.opt('elders', 'Sit with the elders and listen to their prayers'));
        usual := case greatest(r.trait_c, r.trait_e, r.trait_o, r.piety)
                   when r.trait_c then 'help' when r.trait_e then 'play' when r.trait_o then 'explore' else 'elders' end;
      else
        opts := jsonb_build_array(sim.opt('farm', 'Learn to work the fields'), sim.opt('build', 'Learn to build with the builders'),
                                  sim.opt('heal', 'Learn from the healer'), sim.opt('friends', 'Spend the year with your friends'),
                                  sim.opt('pray', 'Keep to prayer and the old stories'));
        usual := case sim.family_trade(r.id) when 'builder' then 'build' when 'healer' then 'heal' else 'farm' end;
      end if;
      perform sim.offer(p_tick, r.id, 'year', opts, usual, jsonb_build_object('age', yrs));
    end if;

    if yrs >= 16 and r.occupation = 'child'
       and not exists (select 1 from app.choices c where c.agent_id = r.id and c.kind = 'work' and c.status <> 'void') then
      perform sim.offer(p_tick, r.id, 'work',
        jsonb_build_array(sim.opt('farmer', 'Work the fields'), sim.opt('builder', 'Build houses and walls'), sim.opt('healer', 'Tend the sick')),
        coalesce(r.calling, sim.family_trade(r.id), 'farmer'),
        jsonb_build_object('food', round(r.vfood::numeric, 2),
                           'healers', (select count(*) from sim.agents x where x.settlement_id = r.settlement_id and x.occupation = 'healer')));
    end if;

    -- A couple's hope for a child, asked once a year while she can still have one.
    if r.partner_id is not null then
      select * into fem from sim.agents x where x.id = case when r.sex = 'F' then r.id else r.partner_id end;
      if fem.id is not null and p_tick - fem.birth_tick between 18 * 1440 and 44 * 1440
         and not exists (select 1 from sim.pregnancies g where g.mother_id = fem.id and g.outcome is null)
         and not exists (select 1 from app.choices c where c.agent_id = r.id and c.kind = 'child' and c.tick > p_tick - 1440) then
        perform sim.offer(p_tick, r.id, 'child',
          jsonb_build_array(sim.opt('yes', 'Hope for a child this year'), sim.opt('no', 'Not this year')),
          case when fem.kids < fem.desired_kids then 'yes' else 'no' end,
          jsonb_build_object('other', r.partner_id, 'kids', fem.kids));
      end if;
    end if;
  end loop;
end $$;

-- What a year of childhood does to a person.
create or replace function sim.grow(p_tick integer, p_agent bigint, p_did text) returns void
language plpgsql security definer set search_path = '' as $$
declare w sim.world; me sim.agents; pal bigint;
begin
  select * into w from sim.world where id = 1;
  select * into me from sim.agents x where x.id = p_agent;
  if not found then return; end if;
  update sim.agents set
    trait_a   = sim.clamp100(trait_a + case p_did when 'mother' then 5 when 'help' then 3 when 'elders' then 2 else 0 end),
    trait_n   = sim.clamp100(trait_n + case p_did when 'mother' then -3 when 'fire' then -2 else 0 end),
    trait_o   = sim.clamp100(trait_o + case p_did when 'animals' then 5 when 'explore' then 5 else 0 end),
    trait_e   = sim.clamp100(trait_e + case p_did when 'children' then 5 when 'play' then 5 when 'friends' then 5 else 0 end),
    trait_c   = sim.clamp100(trait_c + case p_did when 'fire' then 5 when 'help' then 5 when 'farm' then 3 when 'build' then 3 when 'heal' then 3 else 0 end),
    piety     = sim.clamp100(piety + case p_did when 'elders' then 6 when 'pray' then 6 else 0 end),
    education = least(100, education + case p_did when 'heal' then 4 when 'explore' then 2 else 0 end),
    calling   = case p_did when 'farm' then 'farmer' when 'build' then 'builder' when 'heal' then 'healer' else calling end
  where id = p_agent;
  -- Playing together makes friends.
  if p_did in ('play', 'friends', 'children') then
    select x.id into pal from sim.agents x
     where x.settlement_id = me.settlement_id and x.id <> me.id and abs(x.birth_tick - me.birth_tick) <= 4 * 1440
       and not exists (select 1 from sim.relationships l where l.a = least(x.id, me.id) and l.b = greatest(x.id, me.id))
     order by sim.rnd(w.seed, 'pal', me.id, x.id) limit 1;
    if pal is not null then perform sim.befriend(p_tick, me.id, pal); end if;
  end if;
end $$;

------------------------------------------------------------------------------
-- 5. Love, quarrels and temptation put to people with a mind of their own
------------------------------------------------------------------------------
create or replace function sim.court(p_tick integer, p_a bigint, p_b bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world; x sim.agents; y sim.agents;
  pair text := least(p_a, p_b)::text || '-' || greatest(p_a, p_b)::text;
  asked integer := 0;
begin
  select * into w from sim.world where id = 1;
  select * into x from sim.agents s where s.id = p_a;
  select * into y from sim.agents s where s.id = p_b;
  if sim.offer(p_tick, x.id, 'love', jsonb_build_array(sim.opt('accept', 'Let ' || y.name || ' court you'), sim.opt('decline', 'Turn ' || y.name || ' away')),
               case when sim.rnd(w.seed, 'fancy', x.id, y.id) < 0.75 then 'accept' else 'decline' end,
               jsonb_build_object('other', y.id, 'pair', pair)) is not null then asked := asked + 1; end if;
  if sim.offer(p_tick, y.id, 'love', jsonb_build_array(sim.opt('accept', 'Let ' || x.name || ' court you'), sim.opt('decline', 'Turn ' || x.name || ' away')),
               case when sim.rnd(w.seed, 'fancy', y.id, x.id) < 0.75 then 'accept' else 'decline' end,
               jsonb_build_object('other', x.id, 'pair', pair)) is not null then asked := asked + 1; end if;
  if asked = 0 then perform sim.unite(p_tick, p_a, p_b); end if;
end $$;

create or replace function sim.answer_back(p_tick integer, p_me bigint, p_other bigint, p_about text) returns void
language plpgsql security definer set search_path = '' as $$
declare me sim.agents; you sim.agents;
begin
  select * into me from sim.agents x where x.id = p_me;
  select * into you from sim.agents x where x.id = p_other;
  perform sim.offer(p_tick, p_me, 'quarrel',
    jsonb_build_array(sim.opt('peace', 'Go to ' || you.name || ' and make peace'), sim.opt('distance', 'Keep your distance'),
                      sim.opt('confront', 'Stand your ground')),
    case when me.trait_a >= 60 then 'peace' when me.trait_a < 40 and me.trait_n >= 55 then 'confront' else 'distance' end,
    jsonb_build_object('other', p_other, 'about', p_about, 'pair', least(p_me, p_other)::text || '-' || greatest(p_me, p_other)::text));
end $$;

------------------------------------------------------------------------------
-- 6. Who pulls the other way
------------------------------------------------------------------------------
-- Returns who tried to change the choice, what they wanted, and whether the person gave in. The
-- young, the agreeable and the anxious give in more easily; the steady less.
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

------------------------------------------------------------------------------
-- 7. What was chosen happens, as far as the others allow
------------------------------------------------------------------------------
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
      if you.id is null or me.partner_id is not null or you.partner_id is not null or me.settlement_id <> you.settlement_id then
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

-- Every tick: the player had their six hours, the mind its two, and then habit; then what was chosen happens.
create or replace function sim.p_choices(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select x.id, x.soul_id, x.agent_id from app.choices x where x.status = 'open' and x.due_tick <= p_tick order by x.id limit 200 loop
    if app.soul_mind(r.soul_id, p_tick) = 'none' or not exists (select 1 from sim.agents a where a.id = r.agent_id) then
      update app.choices set status = 'chosen', choice = habit, chosen_by = 'habit' where id = r.id;
    else
      update app.choices set status = 'asked', due_tick = p_tick + 120 where id = r.id;
      insert into llm.jobs (kind, priority, tick, agent_id, soul_id, choice_id) values ('mind_choice', 2, p_tick, r.agent_id, r.soul_id, r.id);
    end if;
  end loop;
  update app.choices set status = 'chosen', choice = habit, chosen_by = 'habit' where status = 'asked' and due_tick <= p_tick;
  for r in select x.id from app.choices x where x.status = 'chosen' order by x.id limit 200 loop
    perform sim.settle(p_tick, r.id);
  end loop;
end $$;

------------------------------------------------------------------------------
-- 8. The monthly pass, now asking people with a mind of their own
------------------------------------------------------------------------------
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

  -- 1. Life stage & work, economy, health, mood. Someone with a mind of their own chooses their work;
  --    anyone else takes up what they learned as a child, or what comes along.
  update sim.agents a set
    occupation = case
      when a.occupation = 'child' and p_tick - a.birth_tick between 16 * 1440 and 68 * 1440 - 1
           and a.controller = 'soul' and sim.will(a.id, p_tick) is not null then 'child'
      when a.occupation = 'child' and p_tick - a.birth_tick between 16 * 1440 and 68 * 1440 - 1 and a.calling is not null then a.calling
      else sim.occupation_for_age((p_tick - a.birth_tick) / 1440.0, a.occupation, sim.rnd(w.seed, 'job', a.id, p_tick)) end,
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

  -- 3. Partnering (kin-blocked, same settlement, age gap limit). Someone with a mind of their own is asked first.
  for q in
    select a.id, a.sex, a.birth_tick, a.settlement_id, a.lineage from sim.agents a
    where a.bucket = b and a.partner_id is null and p_tick - a.birth_tick >= min_age
      and sim.rnd(w.seed, 'match', a.id, p_tick) < chance
    order by a.id
  loop
    continue when exists (select 1 from sim.agents x where x.id = q.id and x.partner_id is not null);
    continue when exists (select 1 from app.choices ch where ch.agent_id = q.id and ch.kind = 'love' and ch.status in ('open', 'asked', 'chosen'));
    select c.id into cand from sim.agents c
     where c.settlement_id = q.settlement_id and c.sex <> q.sex and c.partner_id is null
       and p_tick - c.birth_tick >= min_age and abs(c.birth_tick - q.birth_tick) <= gap
       and not sim.is_close_kin(q.id, q.lineage, c.id, c.lineage)
       and not exists (select 1 from app.choices ch where ch.agent_id = c.id and ch.kind = 'love' and ch.status in ('open', 'asked', 'chosen'))
     order by sim.rnd(w.seed, 'cand', q.id, c.id)
     limit 1;
    if cand is not null then
      if sim.will(q.id, p_tick) is not null or sim.will(cand, p_tick) is not null then
        perform sim.court(p_tick, q.id, cand);
      else
        perform sim.unite(p_tick, q.id, cand);
      end if;
    end if;
  end loop;

  -- 4. Weddings: partners for 1+ EON years may marry, if those with a mind of their own agree.
  for r in
    select u.id, u.female_id, u.male_id, a.settlement_id from sim.unions u join sim.agents a on a.id = u.female_id
    where a.bucket = b and u.end_tick is null and u.kind = 'partner' and p_tick - u.start_tick >= 1440
      and sim.rnd(w.seed, 'wed', u.id, p_tick) < 0.12
  loop
    if sim.will(r.female_id, p_tick) is not null or sim.will(r.male_id, p_tick) is not null then
      continue when exists (select 1 from app.choices ch where ch.kind = 'wed' and (ch.facts ->> 'union')::bigint = r.id
                              and (ch.status in ('open', 'asked', 'chosen') or ch.tick > p_tick - 1440));
      perform sim.offer(p_tick, r.female_id, 'wed',
        jsonb_build_array(sim.opt('marry', 'Marry ' || (select x.name from sim.agents x where x.id = r.male_id)), sim.opt('wait', 'Wait a while longer')),
        'marry', jsonb_build_object('union', r.id, 'other', r.male_id, 'pair', least(r.female_id, r.male_id)::text || '-' || greatest(r.female_id, r.male_id)::text));
      perform sim.offer(p_tick, r.male_id, 'wed',
        jsonb_build_array(sim.opt('marry', 'Marry ' || (select x.name from sim.agents x where x.id = r.female_id)), sim.opt('wait', 'Wait a while longer')),
        'marry', jsonb_build_object('union', r.id, 'other', r.female_id, 'pair', least(r.female_id, r.male_id)::text || '-' || greatest(r.female_id, r.male_id)::text));
    else
      update sim.unions set kind = 'married' where id = r.id;
      perform sim.log(p_tick, 'wedding', 2::smallint, r.female_id, r.male_id, r.settlement_id, '{}');
    end if;
  end loop;

  -- 5. Conception, never while the couple is still deciding.
  for r in
    insert into sim.pregnancies (mother_id, father_id, conceived_tick, due_tick)
    select a.id, a.partner_id, p_tick,
           -- 9 EON months ± 2 weeks, so births land on any day
           p_tick + (p -> 'fertility' ->> 'pregnancyTicks')::int - 60 + floor(120 * sim.rnd(w.seed, 'gest', a.id, p_tick))::int
    from sim.agents a
    where a.bucket = b and a.sex = 'F' and a.partner_id is not null and a.fertile_after_tick <= p_tick
      and a.kids < a.desired_kids
      and not exists (select 1 from sim.pregnancies g where g.mother_id = a.id and g.outcome is null)
      and not exists (select 1 from app.choices ch where ch.agent_id in (a.id, a.partner_id) and ch.kind = 'child' and ch.status in ('open', 'asked', 'chosen'))
      and sim.rnd(w.seed, 'conceive', a.id, p_tick) < sim.conception_monthly((p_tick - a.birth_tick) / 1440.0) * w.fertility_mult
    on conflict do nothing
    returning mother_id, father_id
  loop
    perform sim.log(p_tick, 'pregnant', 1::smallint, r.mother_id, r.father_id,
                    (select settlement_id from sim.agents where id = r.mother_id), '{}');
  end loop;
end $$;

------------------------------------------------------------------------------
-- 9. Neighbours: a quarrel happens to you; what you do about it is yours. So is temptation.
------------------------------------------------------------------------------
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
        if sim.will(r.id, p_tick) is not null or sim.will(nb.id, p_tick) is not null then
          -- They fall out. Whether it ends in peace or blows is up to them.
          perform sim.quarrel(p_tick, r.id, nb.id, reason, false);
          perform sim.answer_back(p_tick, r.id, nb.id, reason);
          perform sim.answer_back(p_tick, nb.id, r.id, reason);
        else
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
    end if;

    -- 3. Theft: the poor and the dishonest, from whoever has the most. Small villages see everything.
    --    Anyone poor can be tempted; someone with a mind of their own decides whether to give in.
    if sim.will(r.id, p_tick) is not null then
      if (r.wealth < 20 or (r.food < 0.7 and r.wealth < 100))
         and sim.rnd(w.seed, 'tempt', r.id, p_tick) < 0.10 * w.crime_mult
         and not exists (select 1 from app.choices ch where ch.agent_id = r.id and ch.kind = 'tempt' and ch.tick > p_tick - 1440) then
        select x.id, x.wealth, x.name into nb from (
          select y.id, y.wealth, y.name from sim.agents y
           where y.settlement_id = r.settlement_id and y.id <> r.id and y.wealth >= 100
           order by y.wealth desc limit 3) x
         order by sim.rnd(w.seed, 'mark', r.id, x.id) limit 1;
        if nb.id is not null then
          perform sim.offer(p_tick, r.id, 'tempt',
            jsonb_build_array(sim.opt('take', 'Take what you need from ' || nb.name), sim.opt('endure', 'Go without')),
            case when r.honesty < 45 then 'take' else 'endure' end,
            jsonb_build_object('other', nb.id, 'amount', least(80, nb.wealth / 5)));
        end if;
      end if;
    elsif (r.wealth < 20 or (r.food < 0.7 and r.wealth < 100)) and r.honesty < 45
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

------------------------------------------------------------------------------
-- 10. Prayer: people with a mind of their own pray when they choose to, in their own words
------------------------------------------------------------------------------
create or replace function sim.p_prayers(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w sim.world;
  b smallint := (p_tick % 120)::smallint;
  r record;
begin
  select * into w from sim.world where id = 1;
  for r in
    select a.id, a.settlement_id, sim.need_of(a.id, p_tick) as need
    from sim.agents a
    where a.bucket = b and p_tick - a.birth_tick >= 7 * 1440
      and sim.rnd(w.seed, 'pray', a.id, p_tick) < a.piety / 200.0
      and not exists (select 1 from app.prayers p where p.agent_id = a.id and p.status = 'open')
      and (a.controller <> 'soul' or sim.will(a.id, p_tick) is null)
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

-- A prayer from someone's own mind is in their own words, so EON's narrator does not write one for it.
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
    when p_kind = 'prayer' and not crowded and not coalesce((p_data ->> 'soul')::boolean, false) then job := 'prayer'; rank := 6;
    else return;
  end case;
  insert into llm.jobs (kind, priority, tick, event_id, event_tick, agent_id, other_id, settlement_id, context)
  values (job, rank, p_tick, p_id, p_tick, p_agent, p_other, p_settlement, jsonb_build_object('event', p_kind, 'data', p_data));
end $$;

------------------------------------------------------------------------------
-- 11. Souls: families, thoughts twice a day, the end of the free days
------------------------------------------------------------------------------
create or replace function sim.p_souls(p_tick integer) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; family bigint;
begin
  if (select w.autopilot from sim.world w where w.id = 1) then
    for r in select o.id from app.souls o where o.status = 'waiting' and o.requested_tick <= p_tick - 360 order by o.requested_tick, o.id limit 20 loop
      select g.id into family from sim.pregnancies g where g.outcome is null and g.soul_id is null order by g.due_tick limit 1;
      exit when family is null; -- nobody is expecting: the souls keep waiting for the next pregnancy
      update sim.pregnancies set soul_id = r.id where id = family;
      update app.souls set status = 'assigned', pregnancy_id = family, assigned_by = 'autopilot' where id = r.id;
    end loop;
  end if;
  -- Possession wears off. A life that has a soul goes back to its soul.
  update sim.agents set controller = case when soul_id is null then 'auto' else 'soul' end, possessed_until = null
   where controller = 'god' and possessed_until <= p_tick;

  -- Every living soul with a mind thinks a thought about twice a real day.
  insert into llm.jobs (kind, priority, tick, agent_id, soul_id)
  select 'mind_day', 7, p_tick, o.agent_id, o.id from app.souls o
  where o.status = 'living' and app.soul_mind(o.id, p_tick) <> 'none'
    and not exists (select 1 from llm.jobs j where j.soul_id = o.id and j.kind = 'mind_day' and j.tick > p_tick - 720);

  -- The free days are over and there is no key: the player hears about it once.
  insert into app.outbox (user_id, soul_id, kind)
  select o.user_id, o.id, 'trial_over' from app.souls o
  where o.status = 'living' and o.trial_until is not null and o.trial_until <= p_tick and o.trial_until > p_tick - 60
    and not exists (select 1 from secrets.ai_keys k where k.user_id = o.user_id and k.status <> 'invalid')
  on conflict do nothing;

  if p_tick % 1440 = 0 then
    delete from app.choices where status in ('settled', 'void') and settled_tick < p_tick - 30 * 1440;
    delete from app.thoughts where tick < p_tick - 60 * 1440;
    delete from app.outbox where status in ('sent', 'failed') and created_at < now() - interval '30 days';
  end if;
end $$;

------------------------------------------------------------------------------
-- 12. What a soul's mind is told: only facts about its own life
------------------------------------------------------------------------------
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
    'decided', (select coalesce(jsonb_agg(jsonb_build_object('about', x.kind, 'did', x.outcome ->> 'did', 'result', x.outcome ->> 'result',
                                                             'swayedBy', case when (x.outcome -> 'sway' ->> 'won')::boolean then x.outcome -> 'sway' ->> 'role' end)), '[]')
                from (select * from app.choices y where y.soul_id = j.soul_id and y.status = 'settled' order by y.id desc limit 3) x),
    'lately', (select coalesce(jsonb_agg(x.body), '[]') from (select y.body from app.thoughts y where y.soul_id = j.soul_id order by y.id desc limit 2) x),
    'choice', case when c.id is not null then jsonb_build_object('kind', c.kind, 'options', c.options,
                   'about', (select p.name || ' ' || p.surname from sim.people p where p.id = (c.facts ->> 'other')::bigint),
                   'details', c.facts - 'other' - 'pair' - 'union') end,
    'prayer', case when pr.id is not null then jsonb_build_object('need', pr.need) end,
    'need', sim.need_of(me.id, t),
    'month', (t / 120) % 12,
    'known', (select coalesce(jsonb_agg(d.name order by d.found_tick), '[]') from sim.discoveries d where d.found_tick is not null)));
end $$;

------------------------------------------------------------------------------
-- 13. The worker: claims world lines and soul thoughts, and settles them
------------------------------------------------------------------------------
create or replace function api.minds_claim(p_limit integer default 6) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  estimate constant numeric := 0.0002;
  soul_estimate constant numeric := 0.0004;
  cap numeric := (select w.llm_cap from sim.world w where w.id = 1);
  t integer := (select w.tick from sim.world w where w.id = 1);
  today date := current_date;
  j llm.jobs; mind text; k secrets.ai_keys;
  claimed jsonb := '[]';
  stale record;
begin
  -- A worker that died mid-job hands its reservation back.
  for stale in update llm.jobs set status = 'queued', claimed_at = null where status = 'running' and claimed_at < now() - interval '10 minutes' returning reserved loop
    update llm.budget b set reserved = greatest(0, b.reserved - stale.reserved) where b.day = today;
  end loop;
  insert into llm.budget (day) values (today) on conflict (day) do nothing;
  for j in select * from llm.jobs where status = 'queued' order by priority, id limit least(greatest(p_limit, 1), 12) for update skip locked loop
    if j.soul_id is null then
      update llm.budget b set reserved = b.reserved + estimate where b.day = today and b.spent + b.reserved + estimate <= cap;
      exit when not found;
      update llm.jobs set status = 'running', claimed_at = now(), reserved = estimate where id = j.id;
      claimed := claimed || jsonb_build_object('id', j.id, 'kind', j.kind, 'facts', llm.facts(j));
      continue;
    end if;
    mind := app.soul_mind(j.soul_id, t);
    if mind = 'world' then
      -- The free days think with EON's own key, inside the same daily cap.
      update llm.budget b set reserved = b.reserved + soul_estimate where b.day = today and b.spent + b.reserved + soul_estimate <= cap;
      continue when not found;
      update llm.jobs set status = 'running', claimed_at = now(), reserved = soul_estimate where id = j.id;
      claimed := claimed || jsonb_build_object('id', j.id, 'kind', j.kind, 'soul', true, 'facts', llm.mind_facts(j),
                                               'mind', jsonb_build_object('source', 'world'));
    elsif mind = 'own' then
      select x.* into k from secrets.ai_keys x join app.souls o on o.user_id = x.user_id where o.id = j.soul_id for update of x;
      if k.user_id is null then
        update llm.jobs set status = 'failed' where id = j.id;
        continue;
      end if;
      if k.used_day is distinct from today then k.used := 0; end if;
      if k.used >= k.daily_cap then
        update llm.jobs set status = 'failed' where id = j.id;  -- the player's own daily limit
        continue;
      end if;
      update secrets.ai_keys set used_day = today, used = k.used + 1 where user_id = k.user_id;
      update llm.jobs set status = 'running', claimed_at = now(), reserved = 0 where id = j.id;
      claimed := claimed || jsonb_build_object('id', j.id, 'kind', j.kind, 'soul', true, 'facts', llm.mind_facts(j),
        'mind', jsonb_build_object('source', 'own', 'user', k.user_id, 'provider', k.provider, 'model', k.model,
                                   'ciphertext', k.ciphertext, 'iv', k.iv, 'tag', k.tag, 'version', k.kek_version));
    else
      update llm.jobs set status = 'failed' where id = j.id;
    end if;
  end loop;
  return claimed;
end $$;

-- A soul's mind has answered. Only an offered option is accepted; words are kept as the person's own.
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
  elsif j.kind = 'mind_prayer' then
    update app.prayers set words = coalesce(vprayer, app.prayers.words) where id = j.prayer_id and app.prayers.words is null;
  end if;
end $$;

-- Wake the worker for world lines, soul thoughts and emails alike.
create or replace function llm.wake() returns void
language plpgsql security definer set search_path = '' as $$
declare
  c llm.config;
  stamp text := extract(epoch from now())::bigint::text;
begin
  delete from llm.jobs where status in ('done', 'failed') and created_at < now() - interval '3 days';
  delete from llm.jobs where status = 'queued' and created_at < now() - interval '1 day';
  select * into c from llm.config where id = 1;
  if not found then return; end if;
  if not exists (select 1 from llm.jobs where status = 'queued') and not exists (select 1 from app.outbox where status = 'queued') then return; end if;
  perform net.http_post(
    url := c.url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json',
      'X-EON-Sig', 't=' || stamp || ',v1=' || encode(extensions.hmac(stamp, c.secret, 'sha256'), 'hex')),
    timeout_milliseconds := 55000);
end $$;

-- Emails for the worker to send. Only to confirmed addresses.
create or replace function api.outbox_claim(p_limit integer default 10) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; batch jsonb := '[]';
begin
  update app.outbox set status = 'queued', claimed_at = null where status = 'sending' and claimed_at < now() - interval '10 minutes';
  for r in select x.* from app.outbox x where x.status = 'queued' order by x.id limit least(greatest(p_limit, 1), 20) for update skip locked loop
    update app.outbox set status = 'sending', claimed_at = now(), tries = tries + 1 where id = r.id;
    batch := batch || jsonb_strip_nulls(jsonb_build_object('id', r.id, 'kind', r.kind,
      'email', (select u.email from auth.users u where u.id = r.user_id and u.email_confirmed_at is not null),
      'username', (select p.username from app.profiles p where p.user_id = r.user_id),
      'name', (select pe.name || ' ' || pe.surname from app.souls o join sim.people pe on pe.id = o.agent_id where o.id = r.soul_id),
      'mother', (select m.name || ' ' || m.surname from app.souls o join sim.people pe on pe.id = o.agent_id join sim.people m on m.id = pe.mother_id where o.id = r.soul_id),
      'father', (select f.name || ' ' || f.surname from app.souls o join sim.people pe on pe.id = o.agent_id join sim.people f on f.id = pe.father_id where o.id = r.soul_id),
      'place', (select s.name from app.souls o join sim.people pe on pe.id = o.agent_id join sim.settlements s on s.id = pe.settlement_id where o.id = r.soul_id)));
  end loop;
  return batch;
end $$;

create or replace function api.outbox_finish(p_id bigint, p_ok boolean) returns void
language sql security definer set search_path = '' as $$
  update app.outbox set status = case when p_ok then 'sent' when tries >= 3 then 'failed' else 'queued' end, claimed_at = null
   where id = p_id and status = 'sending';
$$;

------------------------------------------------------------------------------
-- 14. Players
------------------------------------------------------------------------------
create or replace function api.request_life() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t integer := (select w.tick from sim.world w where w.id = 1);
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if app.is_god() then raise exception 'That is not for you' using errcode = '42501'; end if;
  perform app.hit('life:' || uid::text, 5, interval '1 hour');
  if (select w.genesis_at from sim.world w where w.id = 1) is null then raise exception 'The world has not begun'; end if;
  if exists (select 1 from app.souls s where s.user_id = uid and s.status in ('waiting', 'assigned', 'living')) then
    raise exception 'You already have a life, or are waiting for one';
  end if;
  if exists (select 1 from app.souls s where s.user_id = uid and s.status = 'ended' and s.ended_tick > t - 60) then
    raise exception 'Rest a while: you can ask again an hour after a life ends';
  end if;
  if exists (select 1 from app.souls s where s.user_id = uid and s.trial_until is not null)
     and not exists (select 1 from secrets.ai_keys k where k.user_id = uid and k.status <> 'invalid') then
    raise exception 'Your free days are used: connect your own AI to ask for another life';
  end if;
  insert into app.souls (user_id, requested_tick) values (uid, t);
  return api.my_soul();
end $$;

-- Everything the player sees about their life, in one call.
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
    'thoughts', (select coalesce(jsonb_agg(jsonb_build_object('tick', th.tick, 'kind', th.kind, 'body', th.body) order by th.id desc), '[]')
                 from (select * from app.thoughts x where x.soul_id = o.id order by x.id desc limit 8) th),
    'prayers', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('tick', p.tick, 'need', p.need, 'words', p.words, 'status', p.status)) order by p.id desc), '[]')
                from (select * from app.prayers x where x.agent_id = me.id order by x.id desc limit 5) p),
    'happened', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'tick', e.tick, 'kind', e.kind, 'imp', e.importance,
                    'agent', e.agent_id, 'other', e.other_id, 'settlement', e.settlement_id, 'data', e.data - 'said',
                    'agentName', (select p.name || ' ' || p.surname from sim.people p where p.id = e.agent_id),
                    'otherName', (select p.name || ' ' || p.surname from sim.people p where p.id = e.other_id)) order by e.tick desc, e.id desc), '[]')
                 from (select * from sim.events v where (v.agent_id = me.id or v.other_id = me.id) and v.tick >= t - 30 * 1440
                       order by v.tick desc, v.id desc limit 12) e));
end $$;

create or replace function api.choose(p_choice bigint, p_option text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t integer := (select w.tick from sim.world w where w.id = 1); c app.choices;
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  perform app.hit('choose:' || uid::text, 60, interval '1 hour');
  select x.* into c from app.choices x join app.souls o on o.id = x.soul_id where x.id = p_choice and o.user_id = uid;
  if not found then raise exception 'That choice is not yours' using errcode = '42501'; end if;
  if c.status not in ('open', 'asked') then raise exception 'That choice has already been made'; end if;
  if app.soul_mind(c.soul_id, t) = 'none' then raise exception 'Connect your own AI to make choices again'; end if;
  if not exists (select 1 from jsonb_array_elements(c.options) e where e ->> 'id' = p_option) then
    raise exception 'That is not one of the options';
  end if;
  update app.choices set status = 'chosen', choice = p_option, chosen_by = 'player' where id = c.id and status in ('open', 'asked');
end $$;

create or replace function api.soul_pray(p_need text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t integer := (select w.tick from sim.world w where w.id = 1); o app.souls; me sim.agents; pid bigint;
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_need is null or p_need not in ('health', 'food', 'child', 'safety', 'peace', 'thanks') then
    raise exception 'Pray for health, food, a child, safety or peace, or give thanks';
  end if;
  perform app.hit('pray:' || uid::text, 6, interval '1 day');
  select * into o from app.souls s where s.user_id = uid and s.status = 'living';
  if not found then raise exception 'You are not alive in EON'; end if;
  if app.soul_mind(o.id, t) = 'none' then raise exception 'Connect your own AI to pray again'; end if;
  select * into me from sim.agents x where x.id = o.agent_id;
  if not found then raise exception 'You are not alive in EON'; end if;
  if t - me.birth_tick < 4 * 1440 then raise exception 'Too young to pray yet'; end if;
  if exists (select 1 from app.prayers p where p.agent_id = me.id and p.status = 'open') then
    raise exception 'Your last prayer has not been answered yet';
  end if;
  insert into app.prayers (tick, agent_id, settlement_id, need) values (t, me.id, me.settlement_id, p_need) returning id into pid;
  perform sim.log(t, 'prayer', 1::smallint, me.id, null, me.settlement_id, jsonb_build_object('need', p_need, 'soul', true));
  insert into llm.jobs (kind, priority, tick, agent_id, soul_id, prayer_id) values ('mind_prayer', 4, t, me.id, o.id, pid);
end $$;

-- Keys. Saving and checking happen on the server, which verifies the user before calling these.
create or replace function api.key_gate(p_client text, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  -- A key check must never become a free way to test stolen keys.
  perform app.hit('key:' || p_user::text, 8, interval '1 hour');
  perform app.hit('key-net:' || p_client, 20, interval '1 hour');
end $$;

create or replace function api.key_save(p_user uuid, p_provider text, p_model text, p_ct text, p_iv text, p_tag text,
                                        p_version smallint, p_last4 text) returns void
language sql security definer set search_path = '' as $$
  insert into secrets.ai_keys (user_id, provider, model, ciphertext, iv, tag, kek_version, last4, status, used, used_day, checked_at)
  values (p_user, p_provider, p_model, p_ct, p_iv, p_tag, p_version, p_last4, 'ok', 0, null, now())
  on conflict (user_id) do update set provider = excluded.provider, model = excluded.model, ciphertext = excluded.ciphertext,
    iv = excluded.iv, tag = excluded.tag, kek_version = excluded.kek_version, last4 = excluded.last4, status = 'ok', checked_at = now();
$$;

create or replace function api.key_delete() returns void
language sql security definer set search_path = '' as $$
  delete from secrets.ai_keys where user_id = auth.uid();
$$;

------------------------------------------------------------------------------
-- 15. God
------------------------------------------------------------------------------
create or replace function api.god_choose(p_choice bigint, p_option text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.assert_god();
  perform app.hit('god:choose', 240, interval '1 hour');
  update app.choices x set status = 'chosen', choice = p_option, chosen_by = 'god'
   where x.id = p_choice and x.status in ('open', 'asked', 'chosen')
     and exists (select 1 from jsonb_array_elements(x.options) e where e ->> 'id' = p_option);
  if not found then raise exception 'That choice is already made, or that is not one of its options'; end if;
  perform app.audit('god', 'choose', p_choice::text, jsonb_build_object('option', p_option));
end $$;

-- A dream or a sign. Someone with a mind of their own may heed it or not; anyone else follows their faith.
create or replace function api.god_sign(p_agent bigint, p_text text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t integer := (select w.tick from sim.world w where w.id = 1);
  me sim.agents; words text := nullif(trim(coalesce(p_text, '')), '');
begin
  perform app.assert_god();
  perform app.hit('god:sign', 60, interval '1 hour');
  if words is null or char_length(words) > 200 then raise exception 'A sign is 1 to 200 characters'; end if;
  select * into me from sim.agents x where x.id = p_agent;
  if not found then raise exception 'No living soul has that id'; end if;
  if sim.offer(t, me.id, 'sign', jsonb_build_array(sim.opt('heed', 'Take it to heart'), sim.opt('ignore', 'Put it out of your mind')),
               case when me.piety >= 50 then 'heed' else 'ignore' end, jsonb_build_object('text', words)) is null
     and me.piety >= 50 then
    update sim.agents set piety = sim.clamp100(piety + 5), happiness = sim.clamp100(happiness + 5) where id = me.id;
    perform sim.log(t, 'sign', 1::smallint, me.id, null, me.settlement_id, '{}');
  end if;
  perform app.audit('god', 'sign', p_agent::text, jsonb_build_object('text', words));
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
                  select p.id, p.need, p.tick, p.words, a.name || ' ' || a.surname as agent, a.id as "agentId", s.name as place
                  from app.prayers p join sim.agents a on a.id = p.agent_id left join sim.settlements s on s.id = p.settlement_id
                  where p.status = 'open' order by p.tick limit 30) q),
    'souls', (select coalesce(jsonb_agg(q), '[]') from (
                  select o.id, o.requested_tick as tick, u.username from app.souls o join app.profiles u on u.user_id = o.user_id
                  where o.status = 'waiting' order by o.id limit 30) q),
    'lives', (select coalesce(jsonb_agg(q), '[]') from (
                  select o.id, u.username, a.id as "agentId", a.name || ' ' || a.surname as name, (w.tick - a.birth_tick) / 1440 as age,
                         app.soul_mind(o.id, w.tick) as mind, o.trial_until as "trialUntil",
                         (select k.provider || ' · ' || k.status from secrets.ai_keys k where k.user_id = o.user_id) as key,
                         (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'options', c.options, 'status', c.status,
                                   'choice', c.choice, 'by', c.chosen_by,
                                   'about', (select p.name from sim.people p where p.id = (c.facts ->> 'other')::bigint)) order by c.id), '[]')
                            from app.choices c where c.soul_id = o.id and c.status in ('open', 'asked', 'chosen')) as pending,
                         (select th.body from app.thoughts th where th.soul_id = o.id order by th.id desc limit 1) as thought
                  from app.souls o join app.profiles u on u.user_id = o.user_id join sim.agents a on a.id = o.agent_id
                  where o.status = 'living' order by o.id limit 50) q),
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

------------------------------------------------------------------------------
-- 16. The tick
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
  perform sim.p_growing(p_tick);
  perform sim.p_community(p_tick);
  perform sim.p_prayers(p_tick);
  perform sim.p_choices(p_tick);
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

------------------------------------------------------------------------------
-- 17. Who may call what
------------------------------------------------------------------------------
revoke all on all functions in schema sim from public, anon, authenticated;
revoke all on all functions in schema llm from public, anon, authenticated;
revoke all on function app.soul_mind(bigint, integer), app.on_soul_born() from public, anon, authenticated;
revoke all on function api.minds_claim(integer), api.minds_finish_soul(bigint, text, text, text, integer, integer, text),
                       api.outbox_claim(integer), api.outbox_finish(bigint, boolean),
                       api.key_gate(text, uuid), api.key_save(uuid, text, text, text, text, text, smallint, text),
                       api.request_life(), api.my_life(), api.choose(bigint, text), api.soul_pray(text), api.key_delete(),
                       api.god_choose(bigint, text), api.god_sign(bigint, text), api.god_state()
  from public, anon, authenticated;
grant execute on function api.minds_claim(integer), api.minds_finish_soul(bigint, text, text, text, integer, integer, text),
                          api.outbox_claim(integer), api.outbox_finish(bigint, boolean),
                          api.key_gate(text, uuid), api.key_save(uuid, text, text, text, text, text, smallint, text)
  to service_role;
grant execute on function api.request_life(), api.my_life(), api.choose(bigint, text), api.soul_pray(text), api.key_delete(),
                          api.god_choose(bigint, text), api.god_sign(bigint, text), api.god_state()
  to authenticated;
