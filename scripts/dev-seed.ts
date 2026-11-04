// LOCAL DEV ONLY: prints SQL that performs Genesis directly (bypassing the God UI) and fast-forwards N EON years.
// Usage: npx tsx scripts/dev-seed.ts <seed> <years> | docker exec -i supabase_db_EON psql -U postgres -d postgres
import { sitesWithWater } from "../src/shared/rivers";

const seed = Number(process.argv[2] ?? 4242);
const years = Number(process.argv[3] ?? 20);
const sites = sitesWithWater(seed);
console.log(`\\set ON_ERROR_STOP 1
set statement_timeout = 0;
update sim.world set seed = ${seed}, paused = false, genesis_at = now() where id = 1;
insert into sim.sites (id, x, y, region, elev, river, coast) select (e->>0)::int, (e->>1)::real, (e->>2)::real, (e->>3)::smallint, (e->>4)::real, (e->>5)::real, (e->>6)::boolean from jsonb_array_elements('${JSON.stringify(sites)}'::jsonb) e;
select sim.rebuild_life_table();
select sim.refresh_climate();
select sim.ensure_event_partitions(0);
select sim.found_settlement(0, ${sites[0][0]}, 'Eden') as st \\gset
select sim.spawn_agent(0, 'Lyra', 'Voss', 'F', -20*1440, null, null, '{}', 0::smallint, true, :st, null, sim.random_traits(1), 300);
select sim.spawn_agent(0, 'Orin', 'Kell', 'M', -21*1440, null, null, '{}', 0::smallint, true, :st, null, sim.random_traits(2), 300);
select sim.log(0, 'genesis', 3::smallint, 1, 2, :st, '{"village":"Eden"}');
select sim.advance(${years} * 1440) as tick;
select count(*) as alive, (select count(*) from sim.dead) as dead, (select count(*) from sim.settlements) as settlements,
       (select count(distinct agent_id) from sim.infections i where i.until_tick > (select tick from sim.world)) as sick_now,
       (select round(avg(tick_ms), 1) from sim.world_stats) as avg_ms from sim.agents;`);
