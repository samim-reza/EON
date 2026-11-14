# How EON is engineered

EON runs a world of thousands of agents around the clock on free tiers. It can do that because of a few
techniques that apply far beyond this project. This guide explains each one: what it is, where to find it
here, and when to reach for it in your own work.

- [The simulation](#the-simulation)
- [The database](#the-database)
- [Caching and the read path](#caching-and-the-read-path)
- [The browser](#the-browser)
- [Security patterns](#security-patterns)
- [Measured results](#measured-results)

## The simulation

### Move the computation to the data

**What:** the whole simulation runs inside Postgres as set-based SQL, instead of in an app server that fetches
rows, changes them and writes them back.

**Where:** `sim.run_tick()` in `supabase/migrations/20261104000300_engine.sql`.

**Why:** a tick needs no network round trips, and one transaction covers the whole world. A serverless function
would spend its free allowance on data transfer alone.

**Use it when:** the work is mostly reading and updating rows in bulk.

### Time slicing with buckets

**What:** each agent has `bucket = id % 120`, and a tick evaluates just one bucket. Every agent gets a full check
every 120 ticks, and each tick touches 1/120 of the population.

**Why:** the work per tick stays small and even, so 100,000 agents cost about 833 row updates a minute rather than
100,000. Nobody notices, because an agent's month doesn't need minute-by-minute precision.

**Use it when:** you have many entities that need periodic work but not all at the same moment. Cron jobs that
process "all users" often benefit from the same idea.

### Scheduling instead of polling

**What:** instead of asking every agent "are you due to die or give birth?" on every tick, the due moment is stored
in an indexed column, and the engine fetches only rows where `fate_tick <= now` or `due_tick <= now`.

**Where:** `agents_fate_idx`, `pregnancies_due`.

**Why:** the cost depends on how many events happen, not on how many agents exist.

**Use it when:** something will happen at a known future time. This is how timer queues work.

### Precompute a table, then sample from it

**What:** a person's lifespan is decided at birth. The life table turns the Gompertz–Makeham hazard into a
cumulative curve, stored once in `sim.life_table`. A random number `u` is then looked up directly on that curve.
This is called **inverse transform sampling**.

**Why:** drawing a lifespan is one index lookup, rather than rolling dice for each agent each month for 60 years.
It also gives exact control over the population's age statistics, and allows foreshadowing: a chronic illness can
be diagnosed years before the death that's already scheduled.

**Use it when:** you need random values from a complicated distribution many times.

### Deterministic randomness

**What:** `sim.rnd(seed, salt, a, b)` hashes its inputs instead of calling `random()`. The same inputs always give
the same result.

**Why:** a world can be replayed exactly, a bug can be reproduced, and a test can assert precise outcomes. The
browser and database can also independently agree without talking to each other.

**Use it when:** you want reproducible simulations, procedural content or stable test data.

### Keep the answer next to the question

**What:** every agent stores `lineage`, a small array of parents and grandparents. Two people are close kin if
their arrays overlap, which is a single array comparison rather than a recursive family-tree query.

**Where:** `sim.is_close_kin` and the `kin_guard` trigger. Because the rule is a trigger, not application code,
nothing can bypass it.

**Use it when:** an expensive question is asked constantly and its inputs rarely change.

### Feedback instead of fixed rates

**What:** the number of children a family wants depends on how crowded the land is:
`1.8 + 2.6 / (1 + (N/K)^4)`. Population grows fast while land is empty, then settles by itself.

**Why:** a fixed birth rate either explodes or dies out. A negative feedback loop is stable without anyone
tuning it.

**Use it when:** a system needs to stay within limits on its own, like autoscaling or rate control.

### Test the model before you build it

**What:** `lab/` is a Monte Carlo simulator in TypeScript. It runs many worlds for centuries in seconds and checks
statistical targets (life expectancy near 60, all worlds survive, no close-kin unions). CI runs it on every change.

**Why:** you can't wait 300 real days to learn that a world goes extinct in year 200.

**Use it when:** your system's behaviour comes from many random interactions.

### Make scheduled jobs safe to double-fire

**What:** a tick takes an advisory lock and then advances time with a conditional update, which fails if another
tick started less than 45 seconds ago. Running it twice is harmless, and this is called being **idempotent**.

**Why:** schedulers do fire twice, and retries happen. If the database is down, time simply stops, with no
catastrophic catch-up burst.

**Use it when:** you have any scheduled job, webhook handler or payment step.

## The database

| Technique | Where | What it buys |
|---|---|---|
| **Partitioning, then dropping** | `sim.events` is split by day | Deleting old data is `DROP TABLE`: instant, with no dead rows to clean up |
| **Fill factor and HOT updates** | `sim.agents` has `fillfactor 80` | Leaves room in each page, so frequent updates avoid rewriting indexes |
| **Partial indexes** | `agents_single_idx`, `unions_active_f` | Indexes only the rows queries care about, such as single people. Smaller and faster, and can enforce rules like "one active union" |
| **Unlogged tables** | `app.rate_limits` | Skipping crash-safety logging makes writes cheap, and losing a rate-limit counter in a crash does no harm |
| **A retention budget** | `sim.housekeeping()` | Keeps important events forever and drops the rest. A size guard slows the world down before it reaches the 500 MB limit |

## Caching and the read path

The goal is simple: one viewer or a million viewers should cost the database almost the same.

### Treat the CDN as your read replica

Public pages and JSON are served by the CDN. The database only sees a few requests a minute, however many people
are watching, because the CDN answers everyone else and collapses simultaneous requests into one.

### Immutable, versioned URLs

**What:** `/api/pub/bundle/{k}` and `/api/pub/world/{version}` have the version in the URL. Once complete, that URL
can never change, so it's served with `Cache-Control: immutable` for a year.

**Why:** cache invalidation is famously hard, and this avoids it. To change the content, change the URL.

**Use it when:** data is append-only or versionable. Bundlers do this for JavaScript files.

### Key each resource by what changes it

**What:** the map loads two things. `/api/pub/world/{version}` holds everyone alive and every building, and its key
is the roster version, which moves when someone is born, dies or moves. `/api/pub/land/{month}` holds the woods,
soil and herds around each village, and its key is the EON month.

**Why:** the land changes by itself, without anyone being born. Putting it in the big snapshot meant choosing between
stale woods and re-downloading the whole population every time a tree grew. Split by what changes them, each is
fetched exactly when it has changed: the heavy one rarely, the light one twelve times a real day.

**Use it when:** one response mixes data that changes at different rates. The slowest-changing part decides how long
the response can be cached, so separate them.

### Stale-while-revalidate

**What:** `s-maxage=10, stale-while-revalidate=20` lets the CDN answer instantly with slightly old data while it
refreshes in the background.

**Why:** visitors never wait, and an expired entry doesn't send a stampede of requests to your server.

### Incremental static regeneration

Pages such as `/feed` and `/agents/[id]` are generated once, cached, and rebuilt at most every so often. Agent pages
are built on first visit (`generateStaticParams` returns `[]`), so a world of 100,000 agents needs no 100,000-page
build.

### Derive, don't transfer

**What:** the terrain is never downloaded: the browser generates it from the seed. Agent positions are never sent:
the browser works them out from the roster and the clock.

**Why:** sending the same result of a deterministic function is a waste. A seed is a few bytes, and a map is megabytes.

**Use it when:** several parties can compute the same thing from a small shared input.

### Columnar JSON

The roster is sent as parallel arrays (`{"id":[…],"name":[…]}`) rather than an array of objects. Keys aren't repeated
for every agent, and it compresses far better.

### Validate parameters to protect the cache

Public routes reject unknown query parameters. Otherwise `?x=1`, `?x=2`, … would each be a cache miss that
reaches the database, which is an easy way to attack a site.

### Turn off prefetching for lists

Next.js prefetches every `<Link>` that scrolls into view. On a feed naming dozens of agents, that means dozens of
server renders for pages nobody opened. EON uses `prefetch={false}` throughout. See the results below.

## The browser

### One poller for everything

**Where:** `src/components/world-time.ts`.

The map, clock, stats and live ages all read one store, so the page makes one request every 30 seconds however
many widgets it has. The store also:

- **stops in hidden tabs**
- **backs off exponentially** when the server has trouble (30 s, 60 s, 120 s, … up to 5 minutes), so a struggling
  server isn't hammered back down
- adds **jitter** of ±10%, so viewers don't synchronize into waves

### Dead reckoning

**What:** between polls the client estimates the world time itself, and server replies only correct it. Ships
navigated this way, and multiplayer games use the same trick to show smooth movement.

**Where:** `advanceAnchor` and `tickAt` in `src/shared/time.ts`.

**Why:** the clock ticks every second with only two requests a minute. A cached reply is usually slightly old, so
the estimate may only move forward, and time never visibly jumps backwards.

### One formula in two languages

**What:** weather is needed in two places: the browser draws it, and Postgres uses it to grow crops. Neither sends it
to the other. `src/shared/climate.ts` and `sim.weather_at` are the same formula written twice, and a set of golden
vectors, generated by `scripts/climate-golden.ts`, is checked on both sides in CI.

**Why:** the feed can say "a blizzard buried Elysium" while the map shows that exact blizzard, at no bandwidth cost.

**The hard part:** two languages rarely agree on numbers. `sim.rnd` uses a Postgres hash that JavaScript doesn't have,
so the shared noise uses its own 32-bit integer hash. JavaScript gets the low 32 bits of a product from `Math.imul`.
Postgres has no such function, but a 32-bit value times a multiplier below 2^31 fits in a `bigint`, and masking gives
the same bits. Plain addition and multiplication of doubles give the same result everywhere, because IEEE 754
defines them exactly; functions like `exp` can differ in the last digit, so the tests allow 1e-6.

**Use it when:** a pure function must run in two runtimes. Without shared test vectors they will drift apart.

### Calibrate with a closed form

**What:** the storm front is noise that turned out to be almost a bell curve. To rain 30% of the time, you need the
level that noise exceeds 30% of the time. Inverting a bell curve exactly is awkward in SQL, but the logistic curve is a
close match and inverts to one line: `threshold = 0.5 - 0.088 × ln(p / (1 - p))`.

**Why:** the first version guessed a threshold and made deserts rainy 21% of the time. After measuring the noise,
rain matches each climate: deserts 5%, jungles 48%.

**Use it when:** you want a random process to hit a target rate. Measure its distribution, then invert it.

### A tile pyramid

**What:** the whole map is one 1000 × 1000 image, which turns to blur at close zoom. Close up, the view is covered by
640 × 640 tiles of extra detail with individual trees and boulders. They are generated in the worker on demand, one
at a time, nearest the centre first, and only the current view is ever queued. The 24 most recently used tiles are
kept, about 40 MB.

**Why:** a sharp image of the whole world at that detail would be about 100 MB of pixels and take far longer to generate, for a view that only ever shows a few squares of it. This is how every web map works.

### Priority flood: rivers without simulating water

**What:** to know where rivers run, you need to know where every drop goes, and rough terrain is full of pits that
trap it. Priority flood solves both at once. Start at the coast and let the sea rise inland, always spilling into the
lowest unvisited cell, using a heap. Each cell's flow direction is the cell the water reached it from, so every cell
is guaranteed a path to the sea. Any pit has to fill before water can leave it, and that filled depth is a lake.

**Why:** visiting cells in the reverse of the flood order means every cell is handled after all its upstream cells, so
one pass adds up the flow. 250,000 cells take about 120 ms, in the worker, for a whole world's rivers.

**Use it when:** you have a height map and need drainage, or a graph where each node must find its way to a set of
exits. It is Dijkstra's algorithm with heights in place of distances.

### Update only what can change

**What:** a tide moves the shoreline, which sounds like redrawing the map. But the sea only ever reaches a thin strip
of coast. Each tile keeps a list of just the cells in that strip with their heights, and a new sea level rewrites only
those. Wet sand, foam and flooded beach all come from comparing one number per cell.

**Why:** the tide takes a minute to cross a few pixels, so a tile changes only when the sea has really moved, and only
one tile per frame. The tide is written into the tile's own pixels, so each frame still draws just one image per tile.

**Use it when:** most of a big structure can't be affected by a change. Precompute which part can.

### A minimum spanning tree for paths nobody planned

**What:** people wear paths between places, and the shortest network that joins every building is a minimum spanning
tree, built with Prim's algorithm in `src/shared/roads.ts`. Because a tree has exactly one route between any two nodes,
finding someone's way needs no search: climb from both ends until the two meet.

**Why:** it costs no storage and no pathfinding, and everyone derives the same roads. It looks right too, because paths
really do branch from a centre.

**Use it when:** you need to connect points cheaply and don't need more than one route between them.

### Paint small, let the GPU stretch

**What:** light and clouds are computed for a 104 × 70 image a few times a second, then stretched over the map each
frame. Weather itself is sampled on an 18 × 12 grid. A `multiply` blend applies the light, which keeps the land's own
colours at night and gives warm dawns. The small images are pinned to world coordinates and include a margin, so panning
stays smooth between repaints.

**Why:** soft things like clouds and twilight have no fine detail, so per-pixel work would be wasted. Computing a
1280 × 800 sky at 30 fps is about 31 million pixels a second. This computes about 60,000 and looks the same.

### Seasons by crossfade

**What:** snow and autumn leaves are two transparent images drawn once, then faded in as the year turns.

**Why:** recolouring a million pixels whenever the season moves would need a shader or a slow loop. Changing an
image's opacity is free.

### Weighted random choice with one line of SQL

**What:** people settle fertile land more than ice. `order by -ln(u) / weight limit 1` picks one row with probability
proportional to its weight, because each row draws an exponential waiting time and the shortest wins.

**Use it when:** you need weighted sampling in SQL, without computing cumulative totals.

### Rollups: keep the summary, drop the detail

**What:** every event can't be kept forever on a 500 MB database, so everyday events are dropped after 14 days. Before
they go, each EON year is rolled up into one row of `sim.annals`: counts, the extremes and its biggest story. One row a
day is nothing, so it is never deleted. The first time anything happens is also copied to the chronicle permanently.

**Why:** old data is mostly read in summary. Nobody needs every birth from Year 3, but they do want to know how many
there were and what kind of year it was.

**Use it when:** data grows forever but its detail loses value with age. Metrics systems do this as downsampling.

### Reserve, then settle

**What:** before calling Claude, a worker adds the job's estimated cost to the day's `reserved` total, but only if
`spent + reserved + estimate` stays under the cap. Afterwards it swaps the estimate for the real cost. Jobs are claimed
with `FOR UPDATE SKIP LOCKED`, so two workers never take the same one.

**Why:** checking the balance and then spending is a race: ten workers could each see $0.01 left. A reservation in one
`UPDATE` makes overspending impossible, and hotels and card payments work the same way.

**Use it when:** several workers draw on one limited budget.

### Fail back to something that already works

**What:** AI text is attached to an event that already exists. If the budget runs out or the API fails, nothing is
missing: the plain line stays, and the world never depends on a model being up.

**Use it when:** you add AI to a working product. Let it improve what's there, not replace it.

### Limit how far a new system can reach

**What:** the life table is calibrated and tested. Severe weather could have added its own deaths, which would have
needed recalibrating everything. Instead it may only bring forward a death already due within three EON months.

**Why:** stories arrive, life expectancy stays put, and a storm can't wipe out a village of two.

**Use it when:** you add a feature to a system with a tested invariant. Give it a narrow channel.

### A slow function of fast inputs

**What:** what someone wears is worked out from their id, the weather and what they're doing, in `outfitFor`. It is
never stored, like their position. Their garment colour comes from hashing their id, so they keep it from day to day.

**Why:** thousands of people changing clothes with the weather would be thousands of writes. As a pure function it
costs nothing until someone zooms in close enough to see.

### Web Workers and transferable objects

**What:** map generation runs in a background thread (`terrain.worker.ts`). The finished pixels are **transferred**
rather than copied: ownership of the buffer moves to the main thread, with no copying at all.

**Why:** the main thread handles every click and scroll. Work that takes 300 ms there freezes the page, and on a
phone it takes far longer.

### Code splitting

The map code loads after the landing page has painted (`next/dynamic`), so the headline never waits for it.

### Culling

**What:** agents are grouped by settlement. If a settlement is off-screen, everyone in it is skipped in one check.
This is a **broad phase**, the same idea game engines use to avoid testing every object against every other.

**Why:** the cost of a frame follows what's visible, not how many agents exist.

### A grid, not a search

**What:** `src/shared/spatial.ts` hashes villages into 64-unit cells. "Which villages are on screen?" and "what is
under the pointer?" look at a few cells instead of every village, building and person in the world.

**Why:** hovering asks that question fourteen times a second, and the frame asks it thirty times. A scan grows with
the world; a grid lookup grows with what is nearby. A grid suits EON better than a quadtree: villages are spread
fairly evenly, never move, and the index is rebuilt only when one is founded.

**Use it when:** you ask "what is near this point?" often, about things that rarely move. (**Spatial hashing**.)

### Work it out once

Three places where the map used to redo the same sum every frame:

- **Is this land?** takes six layers of noise, and every animal asked it every frame. `landLookup` keeps one byte
  per map unit and fills it in the first time a point is asked about (**lazy memoisation**).
- **Where does this herd stand?** came from hashing the village's id forty times a frame. The hashes never change, so
  they are kept in a flat array per village; a frame only applies the clock.
- **What is this person doing?** A plan holds for a whole half-hour, which is 150 frames. It is worked out once per
  half-hour, and the frames in between only move the person along their path.

**Use it when:** a value depends on inputs that change far less often than you read it.

### Batch the draw calls

**What:** every tree of one colour goes into one path and is filled once. The same for animals, chimney smoke, and
people seen as dots: sorted by colour first, then one canvas call per colour.

**Why:** a canvas is slow per call, not per shape. With 86 villages on screen, drawing each tree and animal by itself
took 22,471 canvas calls a frame; in batches it takes 17, and the number no longer grows with the world.

**Use it when:** you draw many things that share a style. Game engines call this **batching**, and tests in
`scenery.test.ts` hold the line: five thousand animals must cost no more calls than ten.

### Spend only when someone is looking

The landing map runs at 20 fps instead of 30, stops when scrolled out of view (`IntersectionObserver`), and respects
`prefers-reduced-motion`.

### A display hint for cached pages

Cached pages are the same for everyone, so they can't contain "Hello, Lyra". EON uses a small non-secret cookie that
tells the browser which buttons to show. The server never trusts it. This gives a personalized header with no server
call per page view.

## Security patterns

| Pattern | Where | Idea |
|---|---|---|
| **Default deny** | every table | Row-level security is forced on with no policies. Access exists only through explicit functions, and a trigger applies this to any new table |
| **Enforce rules in the database** | `kin_guard` | A rule in a trigger holds even if the app has a bug |
| **Hash chain** | `app.god_actions` | Each log entry includes the hash of the one before, so tampering with history is detectable |
| **Hash what you don't need to read** | IP rate limits | Compare hashes, and the original never has to be stored |
| **Nonce CSP** | `src/proxy.ts` | Scripts need a per-request random value, so injected scripts don't run |
| **Constant-time comparison** | `/api/cron/daily` | Stops attackers learning a secret by timing how long a comparison takes |
| **Honeypot field** | sign-up form | Hidden from people, irresistible to bots |
| **Same error for everything** | sign-in | Never reveals whether an email has an account |

## Measured results

From a production build, comparing the first deployed version with the current one.

| Measure | Before | After |
|---|---|---|
| Background prefetches per page view | 15 | **0** |
| Requests when opening the home page | 30 | **20** |
| Requests when opening the feed | 30 | **13** |
| Longest main-thread freeze on the map | 334 ms | **0 ms** |
| Noise evaluations per map pixel | 2 | **1** (plus fine texture on land) |
| Canvas calls per frame for woods and animals, 86 villages on screen | 22,471 | **17** |
| Script time per frame for the same (`npm run bench:map`) | 2.0 ms | **0.7 ms** |

The climate adds about 6 ms to each EON day's tick with 5 settlements. On the map, JavaScript takes about 100 ms in
every 5 seconds, or 2% of the main thread. The browser's own drawing is the larger cost: with no GPU, the map runs at
54 fps by day and 28 at night, when window glows are blended in software. Measure before you blame: the profile showed
that night was the cause, after a guess had pointed at tides.
