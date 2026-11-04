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
even God can't bypass it.

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
| **Enforce rules in the database** | `app.god`, `kin_guard` | A rule in a trigger holds even if the app has a bug |
| **Hash chain** | `app.god_actions` | Each log entry includes the hash of the one before, so tampering with history is detectable |
| **Hash what you don't need to read** | God email, IP rate limits | Compare hashes, and the original never has to be stored |
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
