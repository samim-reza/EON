begin;
create extension if not exists pgtap with schema extensions;
set search_path = extensions, public;

select plan(89);

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

select * from finish();
rollback;
