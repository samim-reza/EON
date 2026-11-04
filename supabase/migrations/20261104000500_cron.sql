-- Scheduling: the heartbeat of EON and the janitor that keeps it under 500 MB.

create or replace function sim.housekeeping() returns void
language plpgsql security definer set search_path = '' as $$
declare
  t integer := (select tick from sim.world);
  r record;
  day_idx integer;
begin
  delete from cron.job_run_details where end_time < now() - interval '1 day';
  if to_regclass('net._http_response') is not null then
    execute 'delete from net._http_response where created < now() - interval ''1 day''';
  end if;
  delete from app.rate_limits where window_start < now() - interval '1 day';
  -- keep per-tick stats for 3 days, then one sample per EON month
  delete from sim.world_stats where tick < t - 3 * 1440 and tick % 120 <> 0;
  -- drop event partitions older than 14 days (historic events already live in sim.chronicle)
  for r in
    select c.relname from pg_inherits i
    join pg_class c on c.oid = i.inhrelid
    join pg_class p on p.oid = i.inhparent
    join pg_namespace n on n.oid = p.relnamespace
    where n.nspname = 'sim' and p.relname = 'events' and c.relname ~ '^events_d[0-9]+$'
  loop
    day_idx := substring(r.relname from 9)::int;
    if (day_idx + 1) * 1440 < t - 14 * 1440 then
      execute format('drop table sim.%I', r.relname);
    end if;
  end loop;
  perform sim.ensure_event_partitions(t);

  -- Size guard (free plan = 500 MB; the database turns read-only beyond it).
  if pg_database_size(current_database()) > 420 * 1024 * 1024 then
    if (select fertility_mult from sim.world) > 0 then
      update sim.world set fertility_mult = 0 where id = 1;
      perform app.audit('autopilot', 'size_guard_pause_births', null,
                        jsonb_build_object('bytes', pg_database_size(current_database())));
    end if;
  elsif pg_database_size(current_database()) > 350 * 1024 * 1024 then
    -- shrink history harder: keep only 7 days of ordinary events
    for r in
      select c.relname from pg_inherits i join pg_class c on c.oid = i.inhrelid
      join pg_class p on p.oid = i.inhparent join pg_namespace n on n.oid = p.relnamespace
      where n.nspname = 'sim' and p.relname = 'events' and c.relname ~ '^events_d[0-9]+$'
    loop
      day_idx := substring(r.relname from 9)::int;
      if (day_idx + 1) * 1440 < t - 7 * 1440 then execute format('drop table sim.%I', r.relname); end if;
    end loop;
  end if;
end $$;

-- Liveness probe used by the daily Vercel cron (keeps the free project from pausing).
create or replace function api.heartbeat() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('tick', w.tick, 'paused', w.paused, 'lastTickMs', w.last_tick_ms,
                            'dbBytes', pg_database_size(current_database()))
  from sim.world w;
$$;
revoke all on function api.heartbeat() from public, anon, authenticated;
grant execute on function api.heartbeat() to service_role;

revoke all on function sim.housekeeping() from public, anon, authenticated;

select cron.schedule('eon-tick', '* * * * *', 'select sim.run_tick()');
select cron.schedule('eon-housekeeping', '17 * * * *', 'select sim.housekeeping()');
