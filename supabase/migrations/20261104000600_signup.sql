-- Sign-up: reserved usernames, usernames up to the full 20 characters, and a rate-limited gate.

create or replace function app.is_reserved_username(p_name text) returns boolean
language sql immutable set search_path = '' as $$
  select lower(p_name) in (
    'creator', 'thecreator', 'the_creator', 'god', 'autopilot', 'admin', 'administrator', 'root', 'system',
    'support', 'moderator', 'mod', 'staff', 'official', 'owner', 'eon', 'null', 'undefined');
$$;

-- Applies however an account is created, including direct calls to the Auth API, which never pass
-- through the sign-up form.
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  base text;
  uname text;
  n int := 0;
  is_god boolean := encode(extensions.digest(lower(new.email), 'sha256'), 'hex') = app.god_email_sha256();
begin
  base := lower(regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1)), '[^a-zA-Z0-9_]', '', 'g'));
  if app.is_reserved_username(base) and not is_god then base := 'soul_' || base; end if;
  if char_length(base) < 3 then base := 'soul' || base; end if;
  base := left(base, 20);
  uname := base;
  while exists (select 1 from app.profiles p where p.username = uname) loop
    n := n + 1;
    uname := left(base, 20 - char_length(n::text)) || n::text;
  end loop;
  insert into app.profiles (user_id, username, country)
  values (new.id, uname, left(nullif(trim(new.raw_user_meta_data ->> 'country'), ''), 56));
  return new;
end $$;

-- Called by the server action only. p_client is an HMAC of the visitor's IP, so no raw address is
-- stored. Checks are generous, new accounts are not: shared mobile IPs are common. The form can
-- create confirmed accounts, so it must never be able to create the God account: on a fresh
-- install, a confirmed account with that address would claim God.
create or replace function api.signup_gate(p_client text, p_username text, p_email text) returns text
language plpgsql security definer set search_path = '' as $$
begin
  if p_client !~ '^[0-9a-f]{64}$' then
    raise exception 'Bad client key' using errcode = '22023';
  end if;
  perform app.hit('signup-check:' || p_client, 60, interval '1 hour');
  if p_username !~ '^[a-z0-9_]{3,20}$' then return 'invalid'; end if;
  if app.is_reserved_username(p_username) then return 'reserved'; end if;
  if exists (select 1 from app.profiles p where p.username = p_username) then return 'taken'; end if;
  if encode(extensions.digest(lower(trim(p_email)), 'sha256'), 'hex') = app.god_email_sha256() then return 'refused'; end if;
  perform app.hit('signup:' || p_client, 10, interval '1 hour');
  return 'ok';
end $$;

revoke all on function app.is_reserved_username(text) from public, anon, authenticated;
revoke all on function api.signup_gate(text, text, text) from public, anon, authenticated;
grant execute on function api.signup_gate(text, text, text) to service_role;
