-- "Where am I?" A player can always find their own person, and God can see every player's person.

-- whoami now also says which person the caller lives as, if any.
create or replace function api.whoami() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'user_id', auth.uid(),
    'username', (select p.username from app.profiles p where p.user_id = auth.uid()),
    'is_god', app.is_god(),
    'aal', auth.jwt() ->> 'aal',
    'agent', (select o.agent_id from app.souls o where o.user_id = auth.uid() and o.status = 'living' order by o.id desc limit 1))
  end;
$$;

-- Every player's person, for God's map.
create or replace function api.god_player_agents() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.assert_god();
  return (select coalesce(jsonb_agg(jsonb_build_object('agent', o.agent_id, 'username', p.username) order by o.id), '[]')
          from app.souls o join app.profiles p on p.user_id = o.user_id
          where o.status = 'living' and o.agent_id is not null);
end $$;

revoke all on function api.god_player_agents() from public, anon, authenticated;
grant execute on function api.god_player_agents() to authenticated;
