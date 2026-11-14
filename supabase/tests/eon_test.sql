begin;
create extension if not exists pgtap with schema extensions;
set search_path = extensions, public;

select plan(211);

-- Tests never contain the real God email: point the lock at a throwaway address for this
-- transaction only (everything below is rolled back).
create or replace function app.god_email_sha256() returns text language sql immutable set search_path = '' as
  $$ select encode(extensions.digest('creator@eon.test', 'sha256'), 'hex') $$;
alter table app.god drop constraint god_email_sha256_check;
alter table app.god add constraint god_email_sha256_check check (email_sha256 = encode(extensions.digest('creator@eon.test', 'sha256'), 'hex'));

------------------------------------------------------------------------------
-- Fixtures: the God account, a normal player
------------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated',
   'creator@eon.test', 'x', now(), '{"username":"creator"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated',
   'player@example.com', 'x', now(), '{"username":"Player One!","country":"Bangladesh"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated',
   'Creator@eon.test.evil.com', 'x', now(), '{}', now(), now());

-- 1–6: exactly one God, bound to the locked email, immutable
select is((select count(*)::int from app.god), 1, 'God is claimed by the confirmed locked email');
select is((select user_id from app.god), '11111111-1111-1111-1111-111111111111'::uuid, 'God is the right account');
select throws_ok($$insert into app.god (user_id, email_sha256) values ('22222222-2222-2222-2222-222222222222', app.god_email_sha256())$$,
  '23505', null, 'a second God row is impossible');
select throws_ok($$update app.god set user_id = '22222222-2222-2222-2222-222222222222'$$, '42501', null, 'God cannot be reassigned');
select throws_ok($$update auth.users set email = 'other@example.com' where id = '11111111-1111-1111-1111-111111111111'$$,
  '42501', null, 'God email cannot change');
select throws_ok($$delete from auth.users where id = '11111111-1111-1111-1111-111111111111'$$, '42501', null, 'God account cannot be deleted');

-- 7: profiles are created with sanitised usernames
select is((select username from app.profiles where user_id = '22222222-2222-2222-2222-222222222222'), 'playerone', 'username sanitised');

------------------------------------------------------------------------------
-- Default deny for client roles
------------------------------------------------------------------------------
set local role anon;
select throws_ok('select count(*) from sim.agents', '42501', null, 'anon cannot read sim tables');           -- 8
select throws_ok('select count(*) from app.profiles', '42501', null, 'anon cannot read profiles');           -- 9
select throws_ok('select api.pub_now()', '42501', null, 'anon cannot call public RPCs directly (CDN only)'); -- 10
select throws_ok('select api.god_state()', '42501', null, 'anon cannot call God RPCs');                       -- 11
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","aal":"aal2","amr":[{"method":"totp","timestamp":9999999999}]}';
select throws_ok('select count(*) from sim.agents', '42501', null, 'players cannot read sim tables');         -- 12
select throws_ok('select count(*) from secrets.byok_keys', '42501', null, 'players cannot touch secrets');    -- 13 (schema denied even before the table exists)
select is((api.whoami() ->> 'is_god')::boolean, false, 'a player is not God');                              -- 14
select throws_ok('select api.god_state()', '42501', 'Only God may do this', 'a player cannot use God powers'); -- 15
reset role;

-- God without MFA is refused
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal1","amr":[{"method":"password","timestamp":9999999999}]}';
select is((api.whoami() ->> 'is_god')::boolean, true, 'God is recognised');                                 -- 16
select throws_ok('select api.god_state()', '42501', 'God must verify with the authenticator app (MFA) first', 'God needs MFA'); -- 17
reset role;

-- Stale MFA is refused
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal2","amr":[{"method":"totp","timestamp":1000}]}';
select throws_ok('select api.god_state()', '42501', 'MFA verification is older than 12 hours; verify again', 'stale MFA refused'); -- 18
reset role;

------------------------------------------------------------------------------
-- Genesis through the real RPC (God + fresh TOTP)
------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select lives_ok($$select api.god_genesis(777, (select jsonb_agg(jsonb_build_array(g, 100 + (g % 10) * 80, 100 + (g / 10) * 80, g % 4))
                                                from generate_series(1, 40) g), 'Eden', 'Lyra', 'Orin', 'Voss', 'Kell')$$,
                'God performs Genesis');                                                                   -- 19
select throws_ok($$select api.god_genesis(778, '[]', 'Again', 'A', 'B', 'C', 'D')$$, 'P0001', null, 'Genesis happens once'); -- 20
reset role;

select is((select count(*)::int from sim.agents where is_founder), 2, 'two founders exist');               -- 21
select is((select paused from sim.world), false, 'the world clock is running');                           -- 22
select is((select count(*)::int from app.god_actions where action = 'genesis'), 1, 'Genesis is audited'); -- 23
select throws_ok('delete from app.god_actions', '42501', null, 'audit log is append-only');               -- 24

------------------------------------------------------------------------------
-- Tick safety
------------------------------------------------------------------------------
update sim.world set tick_started_at = '-infinity';
select sim.run_tick();
select is((select tick from sim.world), 1, 'run_tick advances one tick');                                   -- 25
select sim.run_tick();
select is((select tick from sim.world), 1, 'a double-fired tick within 45 s is a no-op');                  -- 26

------------------------------------------------------------------------------
-- Kin guard
------------------------------------------------------------------------------
set local statement_timeout = 0;
select sim.advance(1440 * 8);   -- 8 EON years: children are born
select ok((select count(*) from sim.agents where mother_id is not null) > 0, 'children are born');         -- 27
select throws_ok($$
  insert into sim.unions (female_id, male_id, start_tick)
  select f.id, m.id, 0 from sim.agents f join sim.agents m on m.mother_id = f.mother_id and m.father_id = f.father_id
  where f.sex = 'F' and m.sex = 'M' and f.mother_id is not null limit 1$$,
  '23514', null, 'siblings can never form a union');                                                        -- 28
select is((select count(*)::int from sim.unions u join sim.agents f on f.id = u.female_id join sim.agents m on m.id = u.male_id
           where sim.is_close_kin(f.id, f.lineage, m.id, m.lineage)), 0, 'no close-kin unions exist');     -- 29

-- Sign-up
select is(api.signup_gate(repeat('a', 64), 'bad name!', 'a@example.com'), 'invalid', 'gate rejects malformed usernames'); -- 30
select is(api.signup_gate(repeat('a', 64), 'admin', 'a@example.com'), 'reserved', 'gate rejects reserved usernames');     -- 31
select is(api.signup_gate(repeat('a', 64), 'creator', 'a@example.com'), 'reserved', 'nobody else can be called creator'); -- 32
select is(api.signup_gate(repeat('a', 64), 'brand_new_soul', 'a@example.com'), 'ok', 'gate accepts a free username');     -- 33
select is(api.signup_gate(repeat('a', 64), 'sneaky_soul', ' Creator@EON.test '), 'refused', 'the form can never create the God account'); -- 34
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
values ('44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'imposter@eon.test', 'x', now(), '{"username":"admin"}', now(), now());
select is((select username from app.profiles where user_id = '44444444-4444-4444-4444-444444444444'), 'soul_admin',
          'a direct Auth API call cannot claim a reserved name');                                          -- 35
select throws_ok($$select api.signup_gate('not-a-hash', 'someone', 'a@example.com')$$, '22023', null, 'gate needs a hashed client'); -- 36
select throws_ok($$select api.signup_gate(repeat('b', 64), 'x' || g, 'a@example.com') from generate_series(100, 111) g$$,
                 'P0429', null, 'gate stops a burst of sign-ups from one client');                          -- 37

------------------------------------------------------------------------------
-- Climate: the SQL twin must equal src/shared/climate.ts (regenerate with scripts/climate-golden.ts)
------------------------------------------------------------------------------
select is(sim.hash3(1, 2, 3, 4), 0.30982257053256035::double precision, 'hash3 matches JavaScript exactly');
select is(sim.hash3(1257650109, -7, 90000, 12), 0.6115405538585037::double precision, 'hash3 matches JavaScript exactly');
select is(sim.hash3(2147483646, 123456, -1, 77), 0.3834158540703356::double precision, 'hash3 matches JavaScript exactly');
select ok(abs(sim.noise3(42, 1.25, 2.5, 3.75) - (0.61360965)) < 1e-6, 'noise3 matches JavaScript');
select ok(abs(sim.noise3(1257650109, 301.7, 12.2, 900.4) - (0.791621785)) < 1e-6, 'noise3 matches JavaScript');
select ok(abs(sim.noise3(99, -14.3, 7.7, 0.5) - (0.36552613)) < 1e-6, 'noise3 matches JavaScript');
select ok(abs(sim.spring_tide(1257650109, 419) - (0.651454902)) < 1e-6, 'spring tide matches JavaScript');
select ok(abs(sim.spring_tide(777, 2000.5) - (0.981377385)) < 1e-6, 'spring tide matches JavaScript');
select ok(abs(sim.spring_tide(4242, 31.25) - (0.728012465)) < 1e-6, 'spring tide matches JavaScript');
select ok((select abs(c.temp_mean - (12.236286992)) < 1e-6 and abs(c.temp_swing - (10.933755238)) < 1e-6 and abs(c.wet - (0.410872381)) < 1e-6 and abs(c.rainfall - (441.521530038)) < 1e-6 and c.biome = 'grassland'
    and abs(w.temp - (34.015658143)) < 1e-6 and abs(w.high - (35.714144745)) < 1e-6 and abs(w.low - (23.841336939)) < 1e-6 and abs(w.cloud - (0.166483485)) < 1e-6 and abs(w.rain - (0)) < 1e-6 and abs(w.wind - (9.735984562)) < 1e-6
    and w.kind = 'clear' and w.heatwave = true and w.cold_snap = false
  from sim.climate_at(1257650109, 509.2, 511, 0.43) c
  cross join lateral sim.weather_at(1257650109, c.lat, c.temp_mean, c.temp_swing, c.wet, c.rainfall, c.biome, 509.2, 511, 397, 1.5, 1.2) w), 'weather at 1257650109/509.2,511 matches JavaScript');
select ok((select abs(c.temp_mean - (26.638123055)) < 1e-6 and abs(c.temp_swing - (2.95)) < 1e-6 and abs(c.wet - (1)) < 1e-6 and abs(c.rainfall - (2760)) < 1e-6 and c.biome = 'jungle'
    and abs(w.temp - (27.190136781)) < 1e-6 and abs(w.high - (27.416398621)) < 1e-6 and abs(w.low - (24.611431949)) < 1e-6 and abs(w.cloud - (0.968191918)) < 1e-6 and abs(w.rain - (0)) < 1e-6 and abs(w.wind - (21.812415424)) < 1e-6
    and w.kind = 'overcast' and w.heatwave = false and w.cold_snap = false
  from sim.climate_at(1257650109, 300, 860, 0.14) c
  cross join lateral sim.weather_at(1257650109, c.lat, c.temp_mean, c.temp_swing, c.wet, c.rainfall, c.biome, 300, 860, 1210, 1.5, 1.2) w), 'weather at 1257650109/300,860 matches JavaScript');
select ok((select abs(c.temp_mean - (21.849238299)) < 1e-6 and abs(c.temp_swing - (8.064979265)) < 1e-6 and abs(c.wet - (0.587510368)) < 1e-6 and abs(c.rainfall - (897.91109471)) < 1e-6 and c.biome = 'forest'
    and abs(w.temp - (18.978457604)) < 1e-6 and abs(w.high - (22.952212208)) < 1e-6 and abs(w.low - (18.024768193)) < 1e-6 and abs(w.cloud - (1)) < 1e-6 and abs(w.rain - (0.104493782)) < 1e-6 and abs(w.wind - (13.746703697)) < 1e-6
    and w.kind = 'drizzle' and w.heatwave = false and w.cold_snap = false
  from sim.climate_at(4242, 620, 640, 0.2) c
  cross join lateral sim.weather_at(4242, c.lat, c.temp_mean, c.temp_swing, c.wet, c.rainfall, c.biome, 620, 640, 980, 1.5, 1.2) w), 'weather at 4242/620,640 matches JavaScript');
select ok((select abs(c.temp_mean - (-4.779003176)) < 1e-6 and abs(c.temp_swing - (19.249374662)) < 1e-6 and abs(c.wet - (0.065312669)) < 1e-6 and abs(c.rainfall - (66.673568374)) < 1e-6 and c.biome = 'tundra'
    and abs(w.temp - (-24.136338374)) < 1e-6 and abs(w.high - (-19.609059569)) < 1e-6 and abs(w.low - (-29.270248235)) < 1e-6 and abs(w.cloud - (0.797878347)) < 1e-6 and abs(w.rain - (0)) < 1e-6 and abs(w.wind - (15.948770297)) < 1e-6
    and w.kind = 'cloudy' and w.heatwave = false and w.cold_snap = true
  from sim.climate_at(777, 440, 120, 0.3) c
  cross join lateral sim.weather_at(777, c.lat, c.temp_mean, c.temp_swing, c.wet, c.rainfall, c.biome, 440, 120, 1090.5, 1.5, 1.2) w), 'weather at 777/440,120 matches JavaScript');
select ok((select abs(c.temp_mean - (27.4352)) < 1e-6 and abs(c.temp_swing - (1.887539331)) < 1e-6 and abs(c.wet - (0.946230335)) < 1e-6 and abs(c.rainfall - (2450.875000413)) < 1e-6 and c.biome = 'jungle'
    and abs(w.temp - (30.460206473)) < 1e-6 and abs(w.high - (30.562340253)) < 1e-6 and abs(w.low - (27.57198406)) < 1e-6 and abs(w.cloud - (1)) < 1e-6 and abs(w.rain - (0.385885617)) < 1e-6 and abs(w.wind - (22.088251506)) < 1e-6
    and w.kind = 'rain' and w.heatwave = false and w.cold_snap = false
  from sim.climate_at(90210, 520, 920, 0.08) c
  cross join lateral sim.weather_at(90210, c.lat, c.temp_mean, c.temp_swing, c.wet, c.rainfall, c.biome, 520, 920, 505.25, 1.5, 1.2) w), 'weather at 90210/520,920 matches JavaScript');
select ok((select abs(c.temp_mean - (9.672650303)) < 1e-6 and abs(c.temp_swing - (14.928161768)) < 1e-6 and abs(c.wet - (0.470919116)) < 1e-6 and abs(c.rainfall - (575.045584837)) < 1e-6 and c.biome = 'forest'
    and abs(w.temp - (9.081995735)) < 1e-6 and abs(w.high - (11.310573391)) < 1e-6 and abs(w.low - (1.031008293)) < 1e-6 and abs(w.cloud - (0.304685758)) < 1e-6 and abs(w.rain - (0)) < 1e-6 and abs(w.wind - (23.369461918)) < 1e-6
    and w.kind = 'partly' and w.heatwave = false and w.cold_snap = false
  from sim.climate_at(31337, 700, 300, 0.12) c
  cross join lateral sim.weather_at(31337, c.lat, c.temp_mean, c.temp_swing, c.wet, c.rainfall, c.biome, 700, 300, 1000.75, 1.5, 1.2) w), 'weather at 31337/700,300 matches JavaScript');                                                                                                          -- 38–52

------------------------------------------------------------------------------
-- Weather changes lives
------------------------------------------------------------------------------
select ok((select bool_and(s.wx_kind is not null and s.wx_high is not null) from sim.settlements s
           where exists (select 1 from sim.agents a where a.settlement_id = s.id)), 'every lived-in settlement has weather today'); -- 53
select ok((select count(*) > 0 from sim.events e where e.kind = 'weather'), 'severe weather reaches the feed');                       -- 54
select ok((select bool_or(s.crop_norm is not null) from sim.settlements s), 'harvests set what a normal year looks like');            -- 55

-- Fierce heat claims the frail who were already near death, and nobody else.
update sim.settlements set temp_mean = 48, temp_swing = 0, wet = 0.2, rainfall = 100;
create temp table frail on commit drop as
  select a.id, row_number() over (order by a.id) % 2 = 0 as near from sim.agents a;
update sim.agents a set birth_tick = w.tick - 75 * 1440,
                        fate_tick = w.tick + case when f.near then 300 else 200000 end,
                        fate_cause = 'Wear-out'
from sim.world w, frail f where f.id = a.id;
select sim.p_weather(w.tick + g * 4) from sim.world w, generate_series(1, 12) g;
select is((select count(*)::int from sim.agents a join frail f on f.id = a.id where not f.near and a.fate_cause <> 'Wear-out'), 0,
          'weather never shortens a life that was not already ending');                                                                  -- 56
select ok((select count(*) > 0 from sim.agents a join frail f on f.id = a.id where f.near and a.fate_cause = 'Thermal Overload'),
          'a heatwave takes people who were near death');                                                                                -- 57

-- God's sliders reach the public clock, so the map follows.
select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select api.god_set_world('{"temp_shift": 3, "rain_mult": 0.5}');
reset role;
select is(api.pub_now() -> 'tune', '{"rainMult": 0.5, "tempShift": 3}'::jsonb, 'God''s climate sliders are public');                     -- 58

-- Elevations are filled in once and cannot be rewritten.
select is(api.set_site_geography('[[1, 0.33, 0.5, true], [2, 0.4, 0, false]]') + api.set_site_geography('[[1, 0.9, 0, false]]'), 2,
          'site geography can only be filled in, never changed');                                                                        -- 59

-- A pregnancy shows its due date, so the 17-hour wait is visible.
insert into sim.pregnancies (mother_id, father_id, conceived_tick, due_tick)
select a.id, a.id + 1, 100, 99999 from sim.agents a
where a.sex = 'F' and not exists (select 1 from sim.pregnancies g where g.mother_id = a.id and g.outcome is null) order by a.id limit 1;
select is((select (api.pub_agent(g.mother_id) ->> 'dueTick')::int from sim.pregnancies g where g.due_tick = 99999), 99999,
          'a pregnant woman''s profile says when the baby is due');                                                                      -- 57

-- A river keeps the fields alive through a drought.
update sim.world set rain_mult = 0;
update sim.settlements set river = 1, soil = 0, temp_mean = 18, temp_swing = 8;
select sim.p_weather(w.tick) from sim.world w;
select ok((select min(s.soil) >= 0.29 from sim.settlements s where exists (select 1 from sim.agents a where a.settlement_id = s.id)),
          'river water irrigates when no rain falls');                                                                                   -- 61

------------------------------------------------------------------------------
-- What visitors can look back on
------------------------------------------------------------------------------
select is((select count(*)::int from sim.chronicle where kind = 'birth' and (data ->> 'first')::boolean), 1, 'the first birth is history');  -- 62
select is((select count(*)::int from sim.chronicle where kind = 'birth'), 1, 'later births are not');                                        -- 63
select ok((select (data ->> 'first')::boolean from sim.events where kind = 'birth' order by tick, id limit 1), 'the first birth is marked as a first'); -- 64
select ok((select count(*) >= 7 from sim.annals), 'every finished year has its row in the annals');                                          -- 65
select ok((select a.births > 0 and a.population > 0 and a.high is not null and a.low <= a.high from sim.annals a order by a.year desc limit 1),
          'a year sums up its births, people and extremes');                                                                                 -- 66
select ok((select sum(a.births) from sim.annals a) = (select count(*) from sim.events e where e.kind = 'birth' and e.tick < (select max(a.year + 1) * 1440 from sim.annals a)),
          'the annals count every birth exactly once');                                                                                      -- 67
select ok(jsonb_array_length(api.pub_now() -> 'places') > 0 and api.pub_annals() ->> 0 is not null, 'visitors can read places and history'); -- 68

------------------------------------------------------------------------------
-- Step by step
------------------------------------------------------------------------------
select ok((select found_tick is not null from sim.discoveries where id = 'fire'), 'people discover fire first');                            -- 69
select is((select count(*)::int from sim.discoveries d, unnest(d.needs) n join sim.discoveries y on y.id = n
           where d.found_tick is not null and (y.found_tick is null or y.found_tick > d.found_tick)), 0, 'nothing is discovered before what it needs'); -- 70
select is((select count(*)::int from sim.discoveries d where d.found_tick is not null
           and not exists (select 1 from sim.chronicle c where c.kind = 'discovery' and c.agent_id = d.found_by and c.data ->> 'tech' = d.id)), 0,
          'every discovery is credited to someone, in the history');                                                                         -- 71
select sim.p_progress(w.tick) from sim.world w; -- founders who have just arrived get theirs at the next monthly pass
select is((select count(*)::int from sim.agents a where a.home_id is null and (select tick from sim.world) - a.birth_tick >= 16 * 1440), 0,
          'once shelter is known, every adult has a home');                                                                                  -- 72
select ok(not exists (select 1 from jsonb_array_elements(api.pub_geo() -> 'buildings') b where b ->> 2 = 'factory'), 'visitors never see buildings that do not exist yet'); -- 73

select set_config('request.jwt.claims', json_build_object('sub', '22222222-2222-2222-2222-222222222222', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select throws_ok($$select api.god_found_settlement(5, 'Stolen')$$, '42501', null, 'a player cannot found a settlement');                     -- 74
reset role;

select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
select set_config('test.site', (select id::text from sim.sites where not taken order by id limit 1), true);
select set_config('test.mover', (select a.id::text from sim.agents a where a.partner_id is not null order by a.id limit 1), true);
set local role authenticated;
select lives_ok($$select set_config('test.town', api.god_found_settlement(current_setting('test.site')::int, 'Newhope')::text, true)$$, 'God founds a settlement'); -- 75
select lives_ok($$select api.god_move_agent(current_setting('test.mover')::bigint, current_setting('test.town')::int)$$, 'God moves someone there');       -- 76
reset role;
select is((select count(*)::int from sim.buildings b join sim.settlements s on s.id = b.settlement_id where s.name = 'Newhope' and b.kind <> 'home' and b.built_tick is not null), 1,
          'a new village is only a gathering place');                                                                                        -- 77
select is((select count(*)::int from sim.agents a where a.settlement_id = (select id from sim.settlements where name = 'Newhope')
           and a.home_id is not null and a.partner_id is not null), 2, 'partners move together, into one new home');                         -- 78

------------------------------------------------------------------------------
-- The world never waits for God
------------------------------------------------------------------------------
create temp table asked on commit drop as
  select a.id from sim.agents a order by a.id limit 1;
insert into app.prayers (tick, agent_id, need) select (select tick from sim.world) - 1000, id, 'food' from asked;
update sim.agents set piety = 100 where id = (select id from asked);
select sim.p_prayers(w.tick) from sim.world w;
select isnt((select status from app.prayers where agent_id = (select id from asked) order by id limit 1), 'open', 'an old prayer is answered without God'); -- 79

set local role anon;
select throws_ok('select api.request_life()', '42501', null, 'visitors cannot ask for a life directly');                                     -- 80
reset role;

select set_config('request.jwt.claims', json_build_object('sub', '22222222-2222-2222-2222-222222222222', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is((api.request_life() ->> 'status'), 'waiting', 'a player can ask for a life');                                                      -- 81
select throws_ok('select api.request_life()', 'P0001', 'You already have a life, or are waiting for one', 'one life at a time');             -- 82
reset role;

insert into sim.pregnancies (mother_id, father_id, conceived_tick, due_tick)
select a.id, a.partner_id, 100, (select tick + 8 from sim.world) from sim.agents a
where a.sex = 'F' and a.partner_id is not null and not exists (select 1 from sim.pregnancies g where g.mother_id = a.id and g.outcome is null) order by a.id limit 1;
update sim.pregnancies set due_tick = (select tick + 8 from sim.world) where outcome is null and soul_id is null;
update app.souls set requested_tick = (select tick - 1000 from sim.world);
select sim.p_souls((select tick from sim.world));
select is((select status from app.souls limit 1), 'assigned', 'a soul left waiting joins a family without God');                             -- 83
select sim.advance(12);
select ok((select o.status = 'living' and a.soul_id = o.id and a.controller = 'soul' from app.souls o join sim.agents a on a.id = o.agent_id limit 1),
          'the soul is born into that family');                                                                                               -- 84

select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
select set_config('test.player', (select agent_id::text from app.souls limit 1), true);
select set_config('test.body', (select a.id::text from sim.agents a where a.soul_id is null and a.occupation = 'farmer' order by a.id limit 1), true);
set local role authenticated;
select throws_ok($$select api.god_possess(current_setting('test.player')::bigint, null, 'Obey')$$, 'P0001', 'That life belongs to a player', 'a player''s life is never taken over'); -- 85
select lives_ok($$select api.god_possess(current_setting('test.body')::bigint, 'healer', 'Peace be with you')$$, 'God can work through someone'); -- 86
reset role;
update sim.agents set possessed_until = 1 where controller = 'god';
select sim.p_souls((select tick from sim.world));
select is((select count(*)::int from sim.agents where controller = 'god'), 0, 'possession wears off by itself');                              -- 87

-- When God does answer, a prayer for healing heals.
insert into sim.infections (agent_id, disease_id, since_tick, until_tick)
select id, 1, 0, 999999 from asked on conflict (agent_id, disease_id) do update set until_tick = 999999;
insert into app.prayers (tick, agent_id, need) select (select tick from sim.world), id, 'health' from asked;
select set_config('test.prayer', (select max(id)::text from app.prayers), true);
set local role authenticated;
select lives_ok($$select api.god_answer_prayer(current_setting('test.prayer')::bigint, true)$$, 'God can answer a prayer');                   -- 88
reset role;
select is((select count(*)::int from sim.infections i join asked a on a.id = i.agent_id where i.until_tick > (select tick from sim.world)), 0,
          'an answered prayer for healing ends the illness');                                                                                -- 89

------------------------------------------------------------------------------
-- Voices
------------------------------------------------------------------------------
select ok((select count(*) > 0 from llm.jobs where kind = 'discovery'), 'a discovery asks for words');                                      -- 90
set local role authenticated;
select throws_ok('select api.minds_claim(1)', '42501', null, 'players cannot touch the AI queue');                                           -- 91
reset role;
update sim.world set llm_cap = 0.5;
select is(jsonb_array_length(api.minds_claim(3)), 3, 'the worker claims jobs');                                                              -- 92
select ok((select b.reserved > 0 from llm.budget b where b.day = current_date), 'each claim reserves its cost first');                       -- 93
select set_config('test.job', (select id::text from llm.jobs where status = 'running' and event_id is not null order by id limit 1), true);
select api.minds_finish(current_setting('test.job')::bigint, 'The fire is warm tonight.', 100, 40);
select is((select e.data ->> 'voice' from llm.jobs j join sim.events e on e.tick = j.event_tick and e.id = j.event_id where j.id = current_setting('test.job')::bigint),
          'The fire is warm tonight.', 'the words join the event');                                                                          -- 94
select ok((select b.spent = 0.00003 and b.lines = 1 from llm.budget b where b.day = current_date), 'the real cost is settled');              -- 95
update sim.world set llm_cap = 0;
select is(jsonb_array_length(api.minds_claim(3)), 0, 'nothing is spent past the cap');                                                       -- 96

------------------------------------------------------------------------------
-- Neighbours
------------------------------------------------------------------------------
create temp table pair on commit drop as
  select (array_agg(q.id order by q.id))[1] as x, (array_agg(q.id order by q.id))[2] as y
  from (select a.id from sim.agents a
        where a.soul_id is null and a.settlement_id = (select settlement_id from sim.agents order by id limit 1)
          and (select tick from sim.world) - a.birth_tick >= 16 * 1440
        order by a.id limit 2) q;
select ok((select sim.quarrel_reason(0.9999) is not null), 'every draw gives a reason to fall out');                                        -- 97
select sim.quarrel(w.tick, p.x, p.y, 'a stray goat', false) from sim.world w, pair p;
select is((select l.kind from sim.relationships l, pair p where l.a = p.x and l.b = p.y), 'rival', 'a quarrel leaves a grudge');            -- 98
select ok((select count(*) > 0 from sim.chronicle c where c.kind = 'quarrel' and (c.data ->> 'first')::boolean), 'the first quarrel is history'); -- 99
update sim.relationships set affinity = -60 from pair p where a = p.x and b = p.y;
select set_config('test.h0', (select a.health::text from sim.agents a, pair p where a.id = p.x), true);
select sim.quarrel(w.tick, p.x, p.y, 'a borrowed tool', true) from sim.world w, pair p;
select ok((select a.health < current_setting('test.h0')::int from sim.agents a, pair p where a.id = p.x), 'a fight hurts');                   -- 100
update sim.agents set wealth = 0 from pair p where id = p.x;
update sim.agents set wealth = 500 from pair p where id = p.y;
select sim.steal(w.tick, p.x, p.y, 80, true) from sim.world w, pair p;
select is((select a.wealth from sim.agents a, pair p where a.id = p.y), 520::bigint, 'a caught thief pays back, and a fine on top');          -- 101
select sim.steal(w.tick, p.x, p.y, 50, false) from sim.world w, pair p;
select ok((select e.other_id is null and e.agent_id = p.y from sim.events e, pair p where e.kind = 'theft' order by e.id desc limit 1),
          'a thief who gets away stays unknown');                                                                                             -- 102
select sim.reconcile(w.tick, p.x, p.y) from sim.world w, pair p;
select is((select l.kind from sim.relationships l, pair p where l.a = p.x and l.b = p.y), 'friend', 'making peace turns a rival into a friend'); -- 103
update sim.relationships set kind = 'rival', affinity = -60 from pair p where a = p.x and b = p.y;
insert into app.prayers (tick, agent_id, need) select w.tick, p.x, 'peace' from sim.world w, pair p;
select sim.answer_prayer((select max(id) from app.prayers), true, 'autopilot', w.tick) from sim.world w;
select is((select l.kind from sim.relationships l, pair p where l.a = p.x and l.b = p.y), 'friend', 'an answered prayer for peace ends the grudge'); -- 104
select lives_ok($$select sim.p_community((select tick from sim.world))$$, 'the community pass runs');                                        -- 105

------------------------------------------------------------------------------
-- Hardening
------------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '55555555-5555-5555-5555-555555555555', 'authenticated', 'authenticated',
        'pending@example.com', 'x', null, '{"username":"pending"}', now(), now());
select is((select count(*)::int from app.profiles where user_id = '55555555-5555-5555-5555-555555555555'), 0,
          'no username is taken before the address is confirmed');                                                                           -- 106
update auth.users set email_confirmed_at = now() where id = '55555555-5555-5555-5555-555555555555';
select is((select username from app.profiles where user_id = '55555555-5555-5555-5555-555555555555'), 'pending',
          'confirming the address creates the profile');                                                                                      -- 107
select is(api.signup_gate(repeat('a', 64), 'newname', 'new@example.com', repeat('b', 24)), 'ok', 'a fresh proof of work passes');            -- 108
select is(api.signup_gate(repeat('a', 64), 'newname', 'new@example.com', repeat('b', 24)), 'replayed', 'the same proof of work is refused twice'); -- 109
select lives_ok($$select api.login_gate(repeat('c', 64), 'who@example.com')$$, 'sign-in attempts are counted');                              -- 110
select throws_ok($$select api.login_gate(repeat('c', 64), x || '@example.com') from generate_series(1, 25) x$$, 'P0429', null,
                 'a network that keeps trying to sign in is cut off');                                                                        -- 111

------------------------------------------------------------------------------
-- Free will
------------------------------------------------------------------------------
select set_config('test.soul', (select id::text from app.souls where status = 'living' order by id limit 1), true);
select set_config('test.player', (select agent_id::text from app.souls where status = 'living' order by id limit 1), true);
select ok((select o.trial_until = o.born_tick + 3 * 1440 from app.souls o where o.id = current_setting('test.soul')::bigint),
          'a first life starts with three days of EON''s own mind');                                                            -- 112
select is((select count(*)::int from app.outbox x where x.soul_id = current_setting('test.soul')::bigint and x.kind = 'born'), 1,
          'the player is told they are born');                                                                                  -- 113
select is(app.soul_mind(current_setting('test.soul')::bigint, (select tick from sim.world)), 'world', 'EON thinks for them at first'); -- 114

-- A year of childhood is theirs to choose.
update sim.agents set birth_tick = (select tick - 1440 - 200 from sim.world) where id = current_setting('test.player')::bigint;
select sim.p_growing(w.tick - w.tick % 120 + a.bucket) from sim.world w, sim.agents a where a.id = current_setting('test.player')::bigint;
select set_config('test.year', (select max(id)::text from app.choices where agent_id = current_setting('test.player')::bigint and kind = 'year'), true);
select ok((select options @> '[{"id": "mother"}]' from app.choices where id = current_setting('test.year')::bigint),
          'a toddler is asked how to spend the year');                                                                         -- 115

select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok($$select api.choose(current_setting('test.year')::bigint, 'mother')$$, '42501', 'That choice is not yours',
                 'nobody chooses for someone else''s soul');                                                                    -- 116
reset role;
select set_config('request.jwt.claims', json_build_object('sub', '22222222-2222-2222-2222-222222222222', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok($$select api.choose(current_setting('test.year')::bigint, 'fly')$$, 'P0001', 'That is not one of the options',
                 'only an offered option can be chosen');                                                                      -- 117
select lives_ok($$select api.choose(current_setting('test.year')::bigint, 'mother')$$, 'the player chooses');                -- 118
select is((api.my_life() -> 'choices' -> 0 ->> 'by'), 'player', 'the player sees their own choice');                         -- 119
reset role;
select sim.p_choices((select tick from sim.world));
select is((select outcome ->> 'did' from app.choices where id = current_setting('test.year')::bigint), 'mother', 'what the player chose happens'); -- 120

-- When the player is away, their own mind is asked; when it has nothing usable to say, habit decides.
insert into app.choices (soul_id, agent_id, kind, tick, due_tick, options, habit)
select current_setting('test.soul')::bigint, current_setting('test.player')::bigint, 'year', w.tick, w.tick - 1,
       '[{"id": "mother", "label": "Stay close"}, {"id": "fire", "label": "Sit by the fire"}]', 'fire' from sim.world w;
select set_config('test.late', (select max(id)::text from app.choices), true);
select sim.p_choices((select tick from sim.world));
select is((select status from app.choices where id = current_setting('test.late')::bigint), 'asked', 'when the player is away, the mind is asked'); -- 121
select ok(exists (select 1 from llm.jobs where kind = 'mind_choice' and choice_id = current_setting('test.late')::bigint), 'the question goes to the mind'); -- 122
update sim.world set llm_cap = 0.5;
update llm.jobs set status = 'done' where status = 'queued' and choice_id is distinct from current_setting('test.late')::bigint;
select set_config('test.claim', api.minds_claim(5)::text, true);
select is((current_setting('test.claim')::jsonb -> 0 -> 'mind' ->> 'source'), 'world', 'during the free days it is EON''s mind'); -- 123
select ok((current_setting('test.claim')::jsonb -> 0 -> 'facts' -> 'choice') is not null, 'the mind is shown the choice');   -- 124
select api.minds_finish_soul((select id from llm.jobs where choice_id = current_setting('test.late')::bigint), 'jump', 'I want to fly.', null, 100, 20, null);
select is((select status from app.choices where id = current_setting('test.late')::bigint), 'asked', 'an option that was not offered is ignored'); -- 125
update app.choices set due_tick = (select tick - 1 from sim.world) where id = current_setting('test.late')::bigint;
select sim.p_choices((select tick from sim.world));
select is((select chosen_by from app.choices where id = current_setting('test.late')::bigint), 'habit', 'then habit decides'); -- 126

insert into app.choices (soul_id, agent_id, kind, tick, due_tick, options, habit)
select current_setting('test.soul')::bigint, current_setting('test.player')::bigint, 'year', w.tick, w.tick - 1,
       '[{"id": "mother", "label": "Stay close"}, {"id": "fire", "label": "Sit by the fire"}]', 'mother' from sim.world w;
select set_config('test.mind', (select max(id)::text from app.choices), true);
select sim.p_choices((select tick from sim.world));
update llm.jobs set status = 'done' where status = 'queued' and choice_id is distinct from current_setting('test.mind')::bigint;
select api.minds_claim(5);
select api.minds_finish_soul((select id from llm.jobs where choice_id = current_setting('test.mind')::bigint), 'fire', 'The fire is warm and bright.', null, 100, 20, null);
select is((select chosen_by from app.choices where id = current_setting('test.mind')::bigint), 'mind', 'the mind''s own choice is kept'); -- 127

-- God can overrule.
insert into app.choices (soul_id, agent_id, kind, tick, due_tick, options, habit)
select current_setting('test.soul')::bigint, current_setting('test.player')::bigint, 'year', w.tick, w.tick + 300,
       '[{"id": "mother", "label": "Stay close"}, {"id": "fire", "label": "Sit by the fire"}]', 'mother' from sim.world w;
select set_config('test.open', (select max(id)::text from app.choices), true);
select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select lives_ok($$select api.god_choose(current_setting('test.open')::bigint, 'fire')$$, 'God can overrule any choice');    -- 128
reset role;
select is((select chosen_by from app.choices where id = current_setting('test.open')::bigint), 'god', 'and God''s will is done'); -- 129

-- After the free days, without a key of their own, the player can only watch.
update app.souls set trial_until = (select tick from sim.world) where id = current_setting('test.soul')::bigint;
select is(app.soul_mind(current_setting('test.soul')::bigint, (select tick from sim.world)), 'none', 'after the free days, no key means no mind'); -- 130
insert into app.choices (soul_id, agent_id, kind, tick, due_tick, options, habit)
select current_setting('test.soul')::bigint, current_setting('test.player')::bigint, 'year', w.tick, w.tick + 300,
       '[{"id": "mother", "label": "Stay close"}, {"id": "fire", "label": "Sit by the fire"}]', 'mother' from sim.world w;
select set_config('test.watch', (select max(id)::text from app.choices), true);
select set_config('request.jwt.claims', json_build_object('sub', '22222222-2222-2222-2222-222222222222', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok($$select api.choose(current_setting('test.watch')::bigint, 'fire')$$, 'P0001', 'Connect your own AI to make choices again',
                 'without a mind, the player can only watch');                                                                 -- 131
reset role;
insert into secrets.ai_keys (user_id, provider, model, ciphertext, iv, tag, last4)
values ('22222222-2222-2222-2222-222222222222', 'groq', 'openai/gpt-oss-20b', 'sealed', 'iv', 'tag', 'abcd');
select is(app.soul_mind(current_setting('test.soul')::bigint, (select tick from sim.world)), 'own', 'their own key brings the mind back'); -- 132
set local role authenticated;
select throws_ok($$select api.key_save('22222222-2222-2222-2222-222222222222', 'groq', 'm', 'c', 'i', 't', 1::smallint, 'abcd')$$, '42501', null,
                 'players cannot write keys directly');                                                                       -- 133
reset role;

-- A second life needs your own AI once the free days are used.
insert into app.souls (user_id, status, requested_tick, trial_until, ended_tick) values ('33333333-3333-3333-3333-333333333333', 'ended', 0, 100, 0);
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok('select api.request_life()', 'P0001', 'Your free days are used: connect your own AI to ask for another life',
                 'after the free days, a new life needs your own AI');                                                         -- 134
reset role;

-- A quarrel happens to you; what you do about it is yours.
select sim.answer_back((select tick from sim.world), current_setting('test.player')::bigint,
                       (select a.id from sim.agents a where a.id <> current_setting('test.player')::bigint order by a.id limit 1), 'a stray goat');
select ok(exists (select 1 from app.choices where agent_id = current_setting('test.player')::bigint and kind = 'quarrel' and status = 'open'),
          'after a quarrel, what happens next is up to them');                                                                  -- 135
select is((api.outbox_claim(5) -> 0 ->> 'kind'), 'born', 'the worker picks up the birth email');                              -- 136
set local role authenticated;
select throws_ok('select api.outbox_claim(1)', '42501', null, 'players cannot read the email queue');                         -- 137
reset role;

-- A young child with no soul takes a new player's soul at once, and the free days start then.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '66666666-6666-6666-6666-666666666666', 'authenticated', 'authenticated',
        'newcomer@example.com', 'x', now(), '{"username":"newcomer"}', now(), now());
update sim.agents set birth_tick = (select tick - 700 from sim.world)
 where id = (select a.id from sim.agents a where a.soul_id is null and a.controller = 'auto' order by a.id desc limit 1);
select set_config('request.jwt.claims', json_build_object('sub', '66666666-6666-6666-6666-666666666666', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is((api.request_life() ->> 'status'), 'living', 'a new player becomes a young child with no soul at once');               -- 138
reset role;
select ok((select a.soul_id = o.id and a.controller = 'soul' and (select tick from sim.world) - a.birth_tick < 3 * 1440
             from app.souls o join sim.agents a on a.id = o.agent_id where o.user_id = '66666666-6666-6666-6666-666666666666'),
          'the child is theirs now');                                                                                          -- 139
select ok((select o.born_tick = w.tick and o.trial_until = w.tick + 3 * 1440
             from app.souls o, sim.world w where o.user_id = '66666666-6666-6666-6666-666666666666'),
          'their three free days start from that moment');                                                                     -- 140
select is((select count(*)::int from app.outbox x join app.souls o on o.id = x.soul_id
            where o.user_id = '66666666-6666-6666-6666-666666666666' and x.kind = 'born'), 1, 'and they get the welcome email'); -- 141

-- The Creator keeps every player and every person in hand.
set local role authenticated;
select throws_ok('select api.god_players()', '42501', 'Only God may do this', 'players cannot list players');              -- 142
reset role;
select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
select set_config('test.newsoul', (select id::text from app.souls where user_id = '66666666-6666-6666-6666-666666666666'), true);
select set_config('test.t0', (select trial_until::text from app.souls where user_id = '66666666-6666-6666-6666-666666666666'), true);
set local role authenticated;
select ok((select count(*) > 0 from jsonb_array_elements(api.god_players()) e where e ->> 'username' = 'newcomer'), 'God sees every player'); -- 143
select api.god_extend_free(current_setting('test.newsoul')::bigint, 3);
reset role;
select is((select trial_until - current_setting('test.t0')::int from app.souls where id = current_setting('test.newsoul')::bigint), 3 * 1440,
          'God can give more free days');                                                                                     -- 144
select set_config('test.body', (select agent_id::text from app.souls where id = current_setting('test.newsoul')::bigint), true);
set local role authenticated;
select api.god_take_soul(current_setting('test.newsoul')::bigint);
reset role;
select ok((select o.status = 'ended' and a.soul_id is null and a.controller = 'auto'
             from app.souls o, sim.agents a where o.id = current_setting('test.newsoul')::bigint and a.id = current_setting('test.body')::bigint),
          'God can take a soul back, and the person lives on');                                                               -- 145
select set_config('test.p1', (select agent_id::text from app.souls where status = 'living' order by id limit 1), true);
delete from auth.users where id = '22222222-2222-2222-2222-222222222222';
select ok((select a.soul_id is null and a.controller = 'auto' from sim.agents a where a.id = current_setting('test.p1')::bigint),
          'when a player is removed, their person lives on as an ordinary life');                                            -- 146
set local role authenticated;
select ok((select count(*) > 0 from jsonb_array_elements(api.god_find('')) e), 'God can find anyone');                     -- 147
reset role;

-- Where am I? A player can find their own person; God can see every player's.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '77777777-7777-7777-7777-777777777777', 'authenticated', 'authenticated',
        'finder@example.com', 'x', now(), '{"username":"finder"}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', '77777777-7777-7777-7777-777777777777', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select api.request_life();
reset role;
select set_config('test.mine', (select agent_id::text from app.souls where user_id = '77777777-7777-7777-7777-777777777777'), true);
set local role authenticated;
select ok((api.whoami() ->> 'agent') is not null and (api.whoami() ->> 'agent') = current_setting('test.mine'),
          'a player can always find their own person');                                                                         -- 148
select throws_ok('select api.god_player_agents()', '42501', 'Only God may do this', 'players cannot see where every player is'); -- 149
reset role;
select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select ok(exists (select 1 from jsonb_array_elements(api.god_player_agents()) e where e ->> 'username' = 'finder'), 'God sees every player''s person'); -- 150
reset role;

-- When no young child is free, nobody is made for the soul: it waits, and is born as the next baby.
update sim.agents a set birth_tick = birth_tick - 4 * 1440 from sim.world w where a.soul_id is null and w.tick - a.birth_tick < 3 * 1440;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '88888888-8888-8888-8888-888888888888', 'authenticated', 'authenticated',
        'arrival@example.com', 'x', now(), '{"username":"arrival"}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', '88888888-8888-8888-8888-888888888888', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is((api.request_life() ->> 'status'), 'waiting', 'with no young child free, a soul waits: nobody is made for it');     -- 151
reset role;
select set_config('test.t', (select tick::text from sim.world), true);
select set_config('test.mum', sim.spawn_agent(current_setting('test.t')::int, 'Sela', 'Marsh', 'F', current_setting('test.t')::int - 24 * 1440,
  null, null, '{}', 0::smallint, false, (select min(id) from sim.settlements), null, sim.random_traits(811), 50)::text, true);
select set_config('test.dad', sim.spawn_agent(current_setting('test.t')::int, 'Brann', 'Holt', 'M', current_setting('test.t')::int - 26 * 1440,
  null, null, '{}', 0::smallint, false, (select min(id) from sim.settlements), null, sim.random_traits(812), 50)::text, true);
update sim.agents set fate_tick = current_setting('test.t')::int + 200000 where id in (current_setting('test.mum')::bigint, current_setting('test.dad')::bigint);
select sim.unite(current_setting('test.t')::int, current_setting('test.mum')::bigint, current_setting('test.dad')::bigint);
update sim.pregnancies set due_tick = current_setting('test.t')::int + 5000 where outcome is null and soul_id is null; -- other babies are far off
insert into sim.pregnancies (mother_id, father_id, conceived_tick, due_tick)
values (current_setting('test.mum')::bigint, current_setting('test.dad')::bigint, 100, current_setting('test.t')::int + 8);
update app.souls set requested_tick = current_setting('test.t')::int - 1000 where user_id = '88888888-8888-8888-8888-888888888888';
select sim.p_souls(current_setting('test.t')::int);
select sim.advance(12);
select ok((select o.status = 'living' and a.mother_id = current_setting('test.mum')::bigint and a.father_id = current_setting('test.dad')::bigint
             and w.tick - a.birth_tick < 12
             from app.souls o join sim.agents a on a.id = o.agent_id, sim.world w where o.user_id = '88888888-8888-8888-8888-888888888888'),
          'and is born to a mother and a father');                                                                             -- 152
select is((select count(*)::int from sim.events where kind = 'family_arrives'), 0, 'no family arrives from nowhere any more'); -- 153

-- Things to do, and questions to ask.
select ok(exists (select 1 from jsonb_array_elements(sim.deeds_for((select agent_id from app.souls where user_id = '88888888-8888-8888-8888-888888888888'),
                                                                   (select tick from sim.world))) e where e ->> 'id' = 'sleep'),
          'a newborn has things to do too');                                                                                  -- 154
select set_config('request.jwt.claims', json_build_object('sub', '88888888-8888-8888-8888-888888888888', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(api.do_deed('sleep'), 'You slept deeply and woke up hungry.', 'a deed happens at once');                       -- 155
select api.do_deed('sleep'); select api.do_deed('sleep'); select api.do_deed('sleep');
select throws_ok($$select api.do_deed('sleep')$$, 'P0001', 'That is enough for one day. Come back tomorrow.', 'four deeds a day'); -- 156
select lives_ok($$select api.ask_mind('feel')$$, 'a player can ask their person how they feel');                        -- 157
reset role;
update llm.jobs set status = 'done' where status = 'queued' and kind <> 'mind_ask';
select api.minds_claim(5);
select api.minds_finish_soul((select id from llm.jobs where kind = 'mind_ask' order by id desc limit 1), null, 'Warm. Full. Sleepy.', null, 50, 10, null);
select is((select question from app.thoughts where kind = 'answer' order by id desc limit 1), 'feel', 'and their own mind answers'); -- 158

------------------------------------------------------------------------------
-- A living world: everyone is born, people move for love and land, and the land is alive
------------------------------------------------------------------------------
select is((select count(*)::int from sim.agents where looks is null or array_length(looks, 1) <> 6), 0, 'everyone has looks of their own'); -- 159
select ok(coalesce((select bool_and(c.looks[1] between least(m.looks[1], f.looks[1]) - 1 and greatest(m.looks[1], f.looks[1]) + 1)
                    from sim.agents c join sim.agents m on m.id = c.mother_id join sim.agents f on f.id = c.father_id), false),
          'a child takes after their parents');                                                                                -- 160
select ok((api.pub_agent(current_setting('test.mum')::bigint) -> 'looks') is not null, 'a person''s page shows their looks');  -- 161
select is(jsonb_array_length(api.pub_roster() -> 'skin'), (select count(*)::int from sim.agents), 'the map draws each person as they are'); -- 162

-- The years of creation end.
update sim.world set creation_end_tick = tick;
select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select throws_ok($$select api.god_create_founder('Late', 'Comer', 'F', 20, current_setting('test.town')::int)$$, 'P0001',
                 'The first people have been made. Everyone after them is born', 'after the years of creation, not even God makes a person'); -- 163
reset role;
select set_config('test.people', (select count(*)::text from sim.agents), true);
select sim.p_yearly((select tick from sim.world));
select is((select count(*)::int from sim.agents), current_setting('test.people')::int, 'and no couple arrives with the new year'); -- 164

-- Love between villages.
select set_config('test.t', (select tick::text from sim.world), true);
select set_config('test.her', sim.spawn_agent(current_setting('test.t')::int, 'Mira', 'Vale', 'F', current_setting('test.t')::int - 20 * 1440,
  null, null, '{}', 0::smallint, false, (select min(id) from sim.settlements), null, sim.random_traits(901), 0)::text, true);
select set_config('test.him', sim.spawn_agent(current_setting('test.t')::int, 'Taro', 'Reed', 'M', current_setting('test.t')::int - 21 * 1440,
  null, null, '{}', 0::smallint, false, current_setting('test.town')::int, null, sim.random_traits(902), 0)::text, true);
select sim.unite(current_setting('test.t')::int, current_setting('test.her')::bigint, current_setting('test.him')::bigint);
select is((select count(distinct a.settlement_id)::int from sim.agents a
           where a.id in (current_setting('test.her')::bigint, current_setting('test.him')::bigint)), 1, 'a couple from two villages makes one home'); -- 165
select ok(exists (select 1 from sim.events e where e.kind = 'moved' and e.data ->> 'why' = 'love'
                  and e.agent_id in (current_setting('test.her')::bigint, current_setting('test.him')::bigint)), 'and the one who moved is remembered'); -- 166
select lives_ok($$select sim.p_far_love(w.tick + g) from sim.world w, generate_series(0, 119) g$$, 'the lonely look to the next village'); -- 167
select is((select count(*)::int from sim.unions u join sim.agents f on f.id = u.female_id join sim.agents m on m.id = u.male_id
           where u.end_tick is null and f.settlement_id <> m.settlement_id), 0, 'no couple lives apart');                       -- 168

-- Young families settle new land.
select set_config('test.f1', sim.spawn_agent(current_setting('test.t')::int, 'Anwen', 'Pike', 'F', current_setting('test.t')::int - 22 * 1440,
  null, null, '{}', 0::smallint, false, (select min(id) from sim.settlements), null, sim.random_traits(903), 0)::text, true);
select set_config('test.m1', sim.spawn_agent(current_setting('test.t')::int, 'Corin', 'Ashby', 'M', current_setting('test.t')::int - 24 * 1440,
  null, null, '{}', 0::smallint, false, (select min(id) from sim.settlements), null, sim.random_traits(904), 0)::text, true);
select set_config('test.f2', sim.spawn_agent(current_setting('test.t')::int, 'Edda', 'Lowe', 'F', current_setting('test.t')::int - 23 * 1440,
  null, null, '{}', 0::smallint, false, (select min(id) from sim.settlements), null, sim.random_traits(905), 0)::text, true);
select set_config('test.m2', sim.spawn_agent(current_setting('test.t')::int, 'Hale', 'Burr', 'M', current_setting('test.t')::int - 25 * 1440,
  null, null, '{}', 0::smallint, false, (select min(id) from sim.settlements), null, sim.random_traits(906), 0)::text, true);
select sim.unite(current_setting('test.t')::int, current_setting('test.f1')::bigint, current_setting('test.m1')::bigint);
select sim.unite(current_setting('test.t')::int, current_setting('test.f2')::bigint, current_setting('test.m2')::bigint);
select set_config('test.colony', coalesce(sim.send_pioneers(current_setting('test.t')::int, (select min(id) from sim.settlements))::text, ''), true);
select ok((select count(*) >= 4 from sim.agents a where a.settlement_id = nullif(current_setting('test.colony'), '')::int),
          'young families leave a village to found a new one');                                                                 -- 169
select ok(exists (select 1 from sim.events e where e.kind = 'pioneers' and e.settlement_id = nullif(current_setting('test.colony'), '')::int
                  and (e.data ->> 'families')::int >= 2), 'and the new village knows where its people came from');             -- 170
select is((select count(*)::int from sim.agents), current_setting('test.people')::int + 6, 'nobody is made along the way');    -- 171

-- The land.
select sim.p_nature(current_setting('test.t')::int);
select sim.p_nature(current_setting('test.t')::int + 4);
select ok((select bool_and(woods between 0 and 1 and richness between 0.15 and 1 and game >= 0 and beasts >= 0 and fish >= 5 and herd >= 0)
           from sim.settlements), 'every village has woods, soil, wild herds, hunters and fish around it');                    -- 172
select is((select jsonb_array_length(e -> 'land') from jsonb_array_elements(api.pub_geo() -> 'settlements') e limit 1), 6,
          'visitors can see the land around a village');                                                                       -- 173
update sim.settlements set woods = 0.8, soil = 0.05, wx_high = 36, wx_low = 20, wx_rain = 0, wx_kind = 'clear', eco_event_tick = -100000
 where id = current_setting('test.town')::int;
select sim.p_nature(current_setting('test.t')::int + g * 4) from generate_series(2, 301) g;
select ok(exists (select 1 from sim.events e where e.kind = 'nature' and e.data ->> 'kind' = 'wildfire'
                  and e.settlement_id = current_setting('test.town')::int), 'a hot, dry wood catches fire');                   -- 174
select ok((select woods < 0.8 from sim.settlements where id = current_setting('test.town')::int), 'and the fire takes its trees'); -- 175
select ok((select bool_and(food between 0.4 and 1.5) from sim.settlements), 'the land feeds people within sane bounds');        -- 176

select set_config('test.rich', (select richness::text from sim.settlements where id = current_setting('test.town')::int), true);
select set_config('request.jwt.claims', json_build_object('sub', '22222222-2222-2222-2222-222222222222', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select throws_ok($$select api.god_nature(current_setting('test.town')::int, 'bless')$$, '42501', 'Only God may do this', 'a player cannot command the land'); -- 177
reset role;
select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select lives_ok($$select api.god_nature(current_setting('test.town')::int, 'bless')$$, 'God can bless a land');                 -- 178
reset role;
select ok((select richness > current_setting('test.rich')::real or richness = 1 from sim.settlements where id = current_setting('test.town')::int),
          'and its soil grows richer');                                                                                        -- 179
select ok(exists (select 1 from app.god_actions g where g.action = 'nature'), 'and it is written in the audit log');           -- 180

-- People live off the land and look after it, and it shows.
select set_config('test.me', (select agent_id::text from app.souls where user_id = '88888888-8888-8888-8888-888888888888'), true);
update sim.settlements set biome = 'forest', woods = 0.5, game = 150, fish = 200, herd = 10
 where id = (select settlement_id from sim.agents where id = current_setting('test.me')::bigint);
update sim.agents set birth_tick = (select tick - 20 * 1440 from sim.world), occupation = 'farmer' where id = current_setting('test.me')::bigint;
delete from app.deeds where agent_id = current_setting('test.me')::bigint;
select ok((select count(*) = 5 from jsonb_array_elements(sim.deeds_for(current_setting('test.me')::bigint, (select tick from sim.world))) e
           where e ->> 'id' in ('hunt', 'fish', 'wood', 'plant', 'herd')), 'a grown person can hunt, fish, cut wood, plant trees and tend the herd'); -- 181
select set_config('request.jwt.claims', json_build_object('sub', '88888888-8888-8888-8888-888888888888', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select matches(api.do_deed('wood'), 'beech wood', 'cutting firewood is a deed');                                               -- 182
reset role;
select ok((select woods < 0.5 from sim.settlements where id = (select settlement_id from sim.agents where id = current_setting('test.me')::bigint)),
          'and it thins the village''s real woods');                                                                           -- 183
set local role authenticated;
select api.do_deed('plant'); select api.do_deed('plant');
reset role;
select ok((select woods > 0.5 from sim.settlements where id = (select settlement_id from sim.agents where id = current_setting('test.me')::bigint)),
          'planting trees grows them back');                                                                                   -- 184
select ok((select (e ->> 'burn') is not null from jsonb_array_elements(api.pub_geo() -> 'settlements') e
           where (e ->> 'id')::int = current_setting('test.town')::int), 'the map knows where the woods burned');              -- 185

select is((select count(*)::int from jsonb_array_elements(api.pub_land()) e where jsonb_array_length(e) = 8),
          (select count(*)::int from sim.settlements where woods is not null), 'the land has a small feed of its own, one row per village'); -- 186
set local role authenticated;
select throws_ok('select api.pub_land()', '42501', null, 'which only the server may read');                                    -- 187
reset role;

------------------------------------------------------------------------------
-- The Whisperer, and the reckoning
------------------------------------------------------------------------------
select is(sim.weigh(10, 0, 40), 'light', 'a life of kindness weighs light');                                                   -- 188
select is(sim.weigh(2, 4, 40), 'heavy', 'wrongs that were never repented weigh heavy');                                        -- 189
select is(sim.weigh(0, 9, 12), 'child', 'nothing is held against a child');                                                    -- 190

select set_config('test.t', (select tick::text from sim.world), true);
update sim.agents set deeds_good = 0, deeds_ill = 0, deeds_mended = 0, refuge_until = 0, piety = 50, honesty = 50, occupation = 'farmer'
 where id = current_setting('test.mum')::bigint;
select is(sim.do_whisper(current_setting('test.t')::int, current_setting('test.mum')::bigint, 'cheat', null, 'resist'), 'resisted',
          'a whisper can be turned away');                                                                                      -- 191
select is((select deeds_good from sim.agents where id = current_setting('test.mum')::bigint), 1::smallint, 'and turning away is a good deed'); -- 192
select ok(sim.do_whisper(current_setting('test.t')::int, current_setting('test.mum')::bigint, 'cheat', null, 'yield') in ('cheated', 'caught'),
          'or given in to');                                                                                                    -- 193
select is((select deeds_ill from sim.agents where id = current_setting('test.mum')::bigint), 1::smallint, 'which goes on the record'); -- 194
select is(sim.do_whisper(current_setting('test.t')::int, current_setting('test.mum')::bigint, 'idle', null, 'refuge'), 'refuge',
          'anyone can seek refuge with the Creator');                                                                           -- 195
select ok((select refuge_until > current_setting('test.t')::int from sim.agents where id = current_setting('test.mum')::bigint),
          'and then the Whisperer keeps away for a while');                                                                     -- 196
select is(sim.repent(current_setting('test.t')::int, current_setting('test.mum')::bigint), 1, 'repentance lays the ill down');  -- 197
select ok((select deeds_ill = 0 and deeds_mended = 1 from sim.agents where id = current_setting('test.mum')::bigint),
          'and it no longer weighs');                                                                                           -- 198

-- God decides how loud the Whisperer is.
select set_config('test.e0', (select coalesce(max(id), 0)::text from sim.events), true);
update sim.world set whisper_mult = 0;
select sim.p_whispers(w.tick + g) from sim.world w, generate_series(0, 119) g;
select is((select count(*)::int from sim.events where kind = 'whisper' and id > current_setting('test.e0')::bigint), 0,
          'with its voice taken away, the Whisperer is silent');                                                                -- 199
update sim.world set whisper_mult = 3, crime_mult = 0; -- loud, but nobody dies of a blow while the tests need them
update sim.agents set refuge_until = 0;
select sim.p_whispers(w.tick + g) from sim.world w, generate_series(0, 1199) g;
select ok((select count(*) > 0 from sim.events where kind = 'whisper' and id > current_setting('test.e0')::bigint),
          'and when it speaks, people hear it');                                                                                -- 200
select is((select count(*)::int from sim.agents a, sim.world w
           where w.tick - a.birth_tick < sim.age_of_reckoning() and (a.deeds_good > 0 or a.deeds_ill > 0)), 0, 'no child is held to account'); -- 201
update sim.world set whisper_mult = 1, crime_mult = 1;

-- A person with a mind of their own hears the whisper, and decides.
select set_config('test.wc', sim.offer(current_setting('test.t')::int, current_setting('test.me')::bigint, 'whisper',
  jsonb_build_array(sim.opt('yield', 'Give short measure'), sim.opt('resist', 'Turn away'), sim.opt('refuge', 'Seek refuge with the Creator')),
  'yield', '{"what": "cheat", "line": "Give a little less than you promised."}')::text, true);
select set_config('request.jwt.claims', json_build_object('sub', '88888888-8888-8888-8888-888888888888', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select lives_ok($$select api.choose(current_setting('test.wc')::bigint, 'refuge')$$, 'a player answers the whisper themselves'); -- 202
reset role;
select sim.p_choices(current_setting('test.t')::int);
select is((select outcome ->> 'result' from app.choices where id = current_setting('test.wc')::bigint), 'refuge',
          'and what they chose is what happens');                                                                               -- 203

-- Love between two villages, for someone with a mind of their own.
select set_config('test.far', sim.spawn_agent(current_setting('test.t')::int, 'Rowan', 'Dale',
  (select case when sex = 'F' then 'M' else 'F' end from sim.agents where id = current_setting('test.me')::bigint)::char,
  current_setting('test.t')::int - 21 * 1440, null, null, '{}', 0::smallint, false, current_setting('test.town')::int, null, sim.random_traits(907), 0)::text, true);
select sim.court(current_setting('test.t')::int, current_setting('test.me')::bigint, current_setting('test.far')::bigint);
select set_config('test.lc', (select max(id)::text from app.choices where agent_id = current_setting('test.me')::bigint and kind = 'love'), true);
set local role authenticated;
select api.choose(current_setting('test.lc')::bigint, 'accept');
reset role;
select sim.p_choices(current_setting('test.t')::int);
select ok((select outcome ->> 'result' in ('together', 'apart') from app.choices where id = current_setting('test.lc')::bigint),
          'a courtship from another village is not lost for the distance');                                                     -- 204

-- The record goes with a person to the end.
update sim.agents set deeds_good = 12, deeds_ill = 1 where id = current_setting('test.dad')::bigint;
select sim.kill(current_setting('test.t')::int, current_setting('test.dad')::bigint, 'Accident');
select is((select deeds_good::int from sim.dead where id = current_setting('test.dad')::bigint), 12, 'the record goes with a person when they die'); -- 205
select is(api.pub_agent(current_setting('test.dad')::bigint) ->> 'reckoning', 'light', 'and their page says how they left the world'); -- 206
select ok((api.pub_agent(current_setting('test.mum')::bigint) ->> 'reckoning') is null, 'a living person''s record stays between them and the Creator'); -- 207

select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated',
  'aal', 'aal2', 'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
set local role authenticated;
select lives_ok($$select api.god_set_world('{"whisper_mult": 2}')$$, 'God sets how loud the Whisperer is');                     -- 208
select is((api.god_whisperer() ->> 'mult')::real, 2::real, 'and sees what it has been doing');                                  -- 209
reset role;
select set_config('request.jwt.claims', json_build_object('sub', '88888888-8888-8888-8888-888888888888', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok('select api.god_whisperer()', '42501', 'Only God may do this', 'which no player can');                        -- 210
reset role;
select sim.tell_of_the_outcast();
select sim.tell_of_the_outcast();
select is((select count(*)::int from sim.chronicle where kind = 'outcast'), 1, 'the story of the outcast is told once, at the beginning'); -- 211

select * from finish();
rollback;
