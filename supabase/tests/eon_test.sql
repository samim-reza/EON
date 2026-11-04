begin;
create extension if not exists pgtap with schema extensions;
set search_path = extensions, public;

select plan(37);

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

select * from finish();
rollback;
