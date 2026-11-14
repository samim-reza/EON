-- The land around every village, by itself.
--
-- The map's big snapshot (everyone alive, every building) is cached by the roster version, which
-- moves only when someone is born, dies or moves. Woods, herds and soil change without that, so
-- they get a feed of their own: one small row per village, cached by the EON month. The heavy
-- snapshot is then never fetched again just because a wood grew.
--
-- [id, woods, richness, game, beasts, fish, herd, burn_tick]
create or replace function api.pub_land() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_array(
           s.id, round(s.woods::numeric, 2), round(s.richness::numeric, 2), round(s.game::numeric), round(s.beasts::numeric),
           round(s.fish::numeric), round(s.herd::numeric), s.burn_tick) order by s.id), '[]')
  from sim.settlements s where s.woods is not null;
$$;

revoke all on function api.pub_land() from public, anon, authenticated;
grant execute on function api.pub_land() to service_role;
