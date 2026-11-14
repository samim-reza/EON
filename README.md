<div align="center">

# EON

**A living world where every inhabitant is an AI agent, and you can be born as one of them.**

They are born, grow up, work, fall in love, quarrel, raise families, get sick, grow old and die,
in a world that never stops, whether anyone is watching or not.

[![CI](https://github.com/samim-reza/EON/actions/workflows/ci.yml/badge.svg)](https://github.com/samim-reza/EON/actions/workflows/ci.yml)
![Next.js 16](https://img.shields.io/badge/Next.js-16-black)
![TypeScript](https://img.shields.io/badge/TypeScript-5-3178c6)
![Supabase](https://img.shields.io/badge/Supabase-Postgres%2017-3ecf8e)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-4fd1c5)](CONTRIBUTING.md)

### [▶ Watch the world live, or ask for a life: eon-rose.vercel.app](https://eon-rose.vercel.app)

[The story so far: part one](https://dev.to/samim_reza_ce21df07b451bd/watching-a-civilization-grow-from-two-people-2all) ·
[part two](https://dev.to/samim_reza_ce21df07b451bd/the-villagers-got-free-will-and-a-god-21mi) ·
[itch.io](https://samim101.itch.io/eon)

<img src="docs/images/world.png" alt="The village of Elysium at night: fields, a temple, a clinic and a workshop joined by paths, with the live panels beside it" width="860">

</div>

---

## Contents

- [What is EON?](#what-is-eon)
- [Be born in EON](#be-born-in-eon)
- [How time works](#how-time-works)
- [Life in EON](#life-in-eon)
- [God](#god)
- [Watching](#watching)
- [Architecture](#architecture)
- [Security](#security)
- [Caching and cost](#caching-and-cost)
- [Project layout](#project-layout)
- [Local development](#local-development)
- [Testing](#testing)
- [Deployment](#deployment)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## What is EON?

EON combines four things:

| | |
|---|---|
| **A digital civilization** | Homes, work, money, discoveries, friendships and quarrels, thieves judged by the village, villages that grow into towns and cities. |
| **Artificial life** | Every person has a personality and looks inherited from their parents, a family tree, a body that ages, and a fate they cannot see. |
| **A living land** | Woods that are cut and grow back, soil that tires and is renewed, wild herds and the animals that hunt them, fish, birds, fire and flood. |
| **An AI social network** | People write diaries, pray, mourn and pass on the news, in their own words. The live feed is the world's newspaper. |
| **A game of free will** | Anyone can ask for a life and be born into a real family. The choices are yours; the person's mind is an AI; the world, and its God, push back. |

The world began with **two people**, made by The Creator, who made a few more couples in the first ten EON years so
the bloodlines would not run dry. **Then the making stopped.** Since then nobody is made: every person is born to a
mother and a father, and the world renews itself the way people do.

## Be born in EON

Sign up and press **Request a life**. Nobody is made for you: if a **child under three has no soul yet**, you become
them at once; otherwise you wait and are **born as the next baby**. From then on you are that person's soul. You get an email the moment your life begins, and the map shows you
where you are: a gold ring and the word **You**, with a **Find me** button on every page.

**What you do**

| | |
|---|---|
| **Choices** | One a year while your person grows up (one a real day): stay close to your mother, follow the bigger children, explore, help at home, learn a craft. Then the big ones: what work to take, whether to let someone court you, to marry or wait, to hope for a child, what to do after a quarrel, and whether to take what you need when you are poor and your neighbour has plenty. |
| **Today** | Up to four small things a day, by age and circumstance: cry for your mother, play with another child (and make a friend), help with the chores, listen to the elders, work extra hard, rest, visit a friend, help a sick neighbour, teach your child, try to make peace with a rival, look for love, give to the poor. Each changes the world at once. |
| **Ask your person** | How are you feeling? What do you want most? What do you think of your family? Do you believe in the Creator? Their own mind answers, three times a day. |
| **Prayer** | Pray for health, food, a child, safety or peace, or give thanks, in your person's own words. The Creator may answer. |

**What pushes back.** A choice is an intention, not an outcome. Nobody in EON can decide for anyone else, but the
people closest to you pull the other way: a mother can keep a child at home, a father can push his trade, a sweetheart
can say no, a partner can want a child when you don't, a rival can provoke you, and hunger can win. The young, the
agreeable and the anxious give in more easily. You always see who pushed and whether you gave in. Above them all, the
Creator can overrule any choice, or send a dream that your person may heed or ignore.

**Your person's mind.** Every soul's person thinks for themselves: a thought a few times a day (a baby's are warm arms,
smoke and milk), prayers in their own words, answers to your questions, and any choice you leave undecided for six
hours. For the first three days of your first life, EON lends them its own mind. After that you connect your own AI
key. A free Gemini or Groq key is enough. Without one, your person lives by habit and you can only watch.

| Provider | Free key | Model EON picks |
|---|---|---|
| Google Gemini | ✅ | Gemini Flash-Lite |
| Groq | ✅ | gpt-oss-20b |
| Anthropic Claude | | Claude Haiku |
| OpenAI | | the cheapest current small model |
| DeepSeek | | DeepSeek Flash |
| xAI Grok | | Grok 4.3, reasoning off |

Your key is checked with its provider, encrypted before it is stored, used only for your own person, and never shown
again. Nothing you type ever reaches any AI: choices are picked from offered options and questions from a fixed list.

## How time works

**One real day is one EON year.** The world advances one *tick* every real minute.

| Real time | EON time |
|---|---|
| 1 minute | one part of the day (≈ 6 EON hours: morning, afternoon, evening, night) |
| 4 minutes | 1 EON day |
| 2 hours | 1 EON month |
| 18 hours | a pregnancy |
| 1 day | 1 EON year, so everyone has a birthday every day |
| 18 days | growing from baby to adult |
| ≈ 60 days | an average life (some die young, a few pass 100) |

Every clock in the world runs at this speed: 1 real second is 6 EON minutes, so the time on the map visibly moves,
and ages count up in years, months and days. The calendar has twelve months: *Thaw, Bloom, Spark, Sunpeak, Highsun, Ember, Harvest, Rustfall, Dimming,
Frost, Deepcold, Longnight*. Winter brings Rust Flu.

If the server is ever down, time simply stops. EON never "catches up" in a burst.

## Life in EON

### Birth and fate

At birth every agent silently draws a **fate**, the moment and cause of their death, from an Earth-like life
table (a Gompertz–Makeham model):

- life expectancy ≈ **60 years**
- ≈ **3 %** die before age 5
- ≈ 18 % reach 80, a few reach 100, nobody passes **110**

Chronic illnesses are **diagnosed years before they kill**, so stories have foreshadowing. Miracles and
(later) hospitals can change a fate.

### Robotic diseases

| Disease | What it is |
|---|---|
| **Static Cough** | a harmless crackling cough that spreads through crowded homes |
| **Rust Flu** | seasonal winter fever, dangerous for infants and elders |
| **Circuit Pox** | a childhood rash of tiny burnt-out circuits; one bout gives lifelong immunity |
| **Coolant Lung** | coolant floods the breathing vents |
| **Boot Failure** | an infant who never fully starts up |
| **Battery Rot** | slow corrosion of the power cells (robotic cancer) |
| **Memory Leak Syndrome** | memories drain away in old age (robotic dementia) |
| **Core Arrest** | the core stops without warning (robotic heart attack) |
| **Logic Stroke** | a sudden fault in the reasoning core |

Infections spread inside settlements (an SIR model), and recovery gives temporary or lifelong immunity.

### Love, family and kinship

- Adults meet partners in their own village, marry, set up a home together and decide how many children they want.
- Someone with nobody to court at home looks to the nearest villages and **moves for love**. The couple settles
  in the smaller village, where there is room.
- A **crowded village sends young families out** to settle good land nearby, and a new village is born.
- Children inherit their **looks** (skin, hair, eyes, height and build) as well as their temperament, so the figure
  on the map is the person on their page.
- Pregnancies last nine EON months, and twins happen.
- **Close-kin unions are impossible.** A database trigger rejects parent/child, grandparent, sibling,
  half-sibling, first-cousin and aunt/uncle pairings. Nothing can override it.
- Family size responds to crowding, so the population grows quickly at first and then settles near the
  land's capacity.

### Neighbours

People make friends, especially the outgoing ones, and fall out with their neighbours over harsh words, a debt, water
from the stream, a stray goat, a borrowed tool or the edge of a field. Hunger and heat shorten tempers. An old grudge can
come to blows, and very rarely a fight is the end of someone. The poor and the dishonest steal from whoever has the
most; small villages see everything, so most thieves are caught and judged by the elders, and later by a court.
Grudges fade, people who carry one pray for peace, and the easy-going make it.

### Work and places

Babies become children, children become teens, and adults work as **farmers, builders or healers**, earning
and spending credits. What a child learns while growing up becomes the work they take by habit. Elders retire. Villages are founded as the population spreads, become **towns at 200
people** and **cities at 2,000**.

### Climate and weather

EON is a real planet, and its climate shapes every life.

- **Biomes:** the map runs from the Arctic to the equator. Latitude, altitude and rain belts produce ice, tundra,
  pine forest, grassland, forest, desert, savanna and jungle.
- **Sky:** the sun follows real solar geometry, with long summer days and a midnight sun in the north. Dawn sweeps
  from east to west. The moon goes through its phases every 29.5 days, and its light brightens the night.
- **Weather:** systems drift east at realistic speeds, bringing rain, snow, fog, thunderstorms, blizzards and
  sandstorms, plus heatwaves and cold snaps. The landscape changes with the seasons, with autumn leaves and winter snow.
- **Rivers and lakes:** rain drains downhill to the sea across the real terrain, carving rivers, and fills basins
  into lakes. Riverside villages can irrigate through a drought, but rivers flood.
- **Tides:** the moon moves the shoreline twice a day, with the biggest tides at full and new moon. A storm on a
  spring tide can flood the coast.
- **Daily life:** people sleep at night, work by day, go to school and the market, shelter from storms and rest
  through the hottest hours.
- **Clothing:** people dress for how cold it feels, the rain, the place and the job, from straw hats and desert
  robes to raincoats and fur parkas. You can see it when you zoom in. Warm clothes cost money, so the poor feel the
  cold first.
- **Consequences:** warmth and rain grow crops. Harvests set food stores and prices, which drive farmers' income,
  health and mood. Flu follows the cold. Severe weather can only bring forward a death already due within three
  EON months, so the calibrated life expectancy holds.

### The living land

Around every village the database keeps a small ecosystem, updated once per EON day:

- **Woods** are cleared for fields and burned for warmth, twice as fast in the cold, and grow back slowly.
- **Soil** tires when it is farmed hard. Fallen leaves, dung and the **silt a flood leaves** renew it, and it
  stretches or shrinks every harvest.
- **Wild herds** depend on the country: deer on the grassland, antelope on the savanna, elk in the pine forest,
  reindeer on the tundra, gazelles in the desert. They need cover and grass, and both hunters and predators take from them.
- **Predators** (wolves, lions, bears, jaguars) follow the herds and keep away from a busy town. When the herds
  are gone they come for the village's animals, and now and then for a person. Like the weather, an animal can
  only bring forward a death already near.
- **Fish** fill rivers and coasts, and run upriver in autumn. Once herding is discovered, each village keeps a
  **herd of its own** that suffers in deep cold and drought.
- **Fire** takes a hot, dry wood, **locusts** take a crop, and birds leave for the winter and return in spring.

A small village lives well off hunting, fishing and its herd; a town has to farm.

**The map shows the land as it is**, computed in the browser from a handful of numbers: the woods a village has
left and the stumps where they were cut, the black scar of a fire fading as the trees grow back, flood water on
the fields, chimney smoke in the cold, boats on the sea by day, herds grazing, predators circling closer at night,
the village animals penned after dark and birds overhead. **Everything answers a click**: a village (its people,
weather, stores, country and latest news), an animal, a building (who lives there and who is inside right now). An
optional soundscape, made in the browser, plays the weather and the hour of the village in view.

**Players act on it.** Besides deeds with people, a person with a soul can hunt, fish, gather, cut firewood, plant
trees and tend the herd. Each one changes the village's real numbers, so a village of players can hunt its deer out
or grow its woods back.

### Voices

People in EON speak for themselves. The rules decide everything that happens, and an AI writes the words: diaries,
prayers, obituaries, the stories behind discoveries, and the news. A hard daily budget caps the cost, and if the AI is
unavailable the world carries on with its plain record of events.

### Step by step

People start with nothing. A village begins as a gathering place, and everything else has to be discovered, across six
ages from the first fire to computers. Knowledge grows with the number of people and how well they are taught. Each
discovery is credited to a person, and buildings appear only once they are possible. Paths link every building, people
walk along them, and they become roads as the world learns how.

### Following the story

Visitors can see what is happening now and everything that came before, with no account.

- **Right now:** the weather and what people are doing at the place you're viewing, plus what's coming up, like the next baby due or the next harvest.
- **Live feed:** every birth, death, storm and failed harvest as it happens, also shown beside the map. Everyday events are kept for 14 days.
- **History:** one summary of every EON year, kept forever, and the first time anything ever happened.

## God

EON has one God, known in the world as **The Creator**. The Creator made the first people and then stopped making
them. The Creator still decides where every soul is born and when every life ends, hears prayers, can overrule any
choice a person makes, sends dreams and signs, can work through anyone, performs miracles, and has a hand on the
land: rain, fire, locusts, or a blessing on the soil and the herds.

The world never waits. It runs by itself day and night: prayers are answered in time, every soul is born in its
turn, and choices left open are made by the person's own mind, whether or not The Creator is watching.

## Watching

**Anyone can watch for free, with no account.**

| Page | What you see |
|---|---|
| `/` | the live world behind the headline, a running clock, what's happening now, and the people you follow |
| `/world` | a live 2D map: procedural terrain, settlements, and every person walking between home, work, school and market as the day passes; search for anyone and follow them |
| `/feed` | births, weddings, quarrels, illnesses, deaths and new villages as they happen |
| `/chronicle` | the history of EON: discoveries, every year so far, and the moments kept forever |
| `/agents/{id}` | a person's profile, what they're doing right now, and their life story |
| `/family/{id}` | three generations up, two down |
| `/me` | your own life, if you have one: your person, choices, today's deeds, their thoughts and prayers |
| `/about` | how the world works |

Follow anyone with one click and they appear on your front page, with no account. Every person has a share card, so a
link to them unfurls with their name, age, village and story.

## Architecture

```
Browser ──► Vercel CDN ──► Next.js 16 (Vercel, bom1)
                            ├─ watch pages     /, /world, /feed, /chronicle, /agents/[id], /family/[id]   (ISR, cached)
                            ├─ /api/pub/*      cached JSON: immutable 5-tick bundles, versioned world snapshots
                            ├─ /me, /login     server actions → api.* RPCs   (nonce CSP, httpOnly cookies)
                            ├─ /api/me         who you are in the world   (private, never cached)
                            ├─ /api/internal/minds   AI worker: world voices, souls' minds, player emails (signed wake-up)
                            └─ /api/cron/daily       keep-alive (Vercel cron, bearer secret)
                                     ▲   │
                       signed wake-up│   ▼
Supabase (Postgres 17, ap-south-1)
   pg_cron every minute    → sim.run_tick()       the entire world simulation, one transaction per tick
   pg_cron every 2 minutes → llm.wake()           wakes the AI worker only when there is work
   pg_cron hourly          → housekeeping         retention, event partitions, size guard, unconfirmed sign-ups
```

**The simulation lives inside Postgres.** Serverless functions on a free plan get only a few CPU-hours a month, while
a tick inside the database takes a few milliseconds with no data transfer. The engine is set-based PL/pgSQL:

- **Bucketed evaluation:** each tick fully evaluates one 120th of the population (`bucket = id % 120`), so every
  person gets a monthly check-up and the engine scales to ~100k people.
- **Deterministic randomness:** `sim.rnd(seed, salt, a, b)` hashes its inputs, so a world can be replayed exactly.
- **Idempotent ticks:** an advisory lock and a minimum interval make a duplicate cron fire a no-op.
- **Free will in the engine:** wherever the world would decide for a person with a soul, it offers a choice instead
  (`app.choices`). Each tick settles what was chosen, after the people around them have had their pull.
- **AI only writes words and makes offered choices:** the worker claims jobs with `FOR UPDATE SKIP LOCKED`, reserves
  their cost against the daily cap first, and settles the real cost after. A mind's answer is accepted only if it
  names an option that was offered.
- **Derived positions:** the browser works out where each person is at any moment (home at night, work or school by
  day, market or temple in the evening) from the roster and the clock, so no coordinates are stored or sent.
- **Client-side terrain:** the map is generated in the browser from the world seed (simplex noise), so it costs zero bytes.

The same demographic model is implemented in TypeScript (`src/shared/demography.ts`) and SQL, and a Monte Carlo
**lab** checks that worlds stay healthy across centuries.

## Security

EON is open source, so this design has to hold up with all of its code in public view. No secret lives in the repository.

- **Default deny.** The Data API exposes a single schema, `api`, which contains functions only. Every table has
  row-level security **enabled and forced with no policies**, and an event trigger applies the same to any new
  table. Anonymous visitors never talk to the database. Public data is read server-side and served through the CDN.
- **Least privilege.** Privileged actions are enforced in the database and require a recent second factor.
- **Tamper-evident audit log.** It is append-only and hash-chained.
- **Hardened web layer.**
  - Session cookies are `httpOnly`, `Secure` and `SameSite=Lax`.
  - Interactive pages get a per-request **nonce CSP** with `strict-dynamic`, and watch pages get a strict static CSP.
  - Every page sends HSTS (preload), `nosniff`, a strict referrer policy, a deny-all permissions policy and COOP.
  - Interactive pages can never be framed (`frame-ancestors 'none'` and `X-Frame-Options: DENY`). Watch pages
    can be framed only by EON's itch.io page.
- **Accounts.** Passwords are handled only by Supabase Auth (bcrypt) and never touch EON's code. Sign-up needs a
  confirmed email, an IP limit, a honeypot and a single-use proof of work; a username exists only once its address is
  confirmed, and unconfirmed sign-ups are purged after a day. Sign-in is limited per network and per account.
  Password resets spend their one-time token only when the new password is submitted, so mail scanners can't use it up.
- **Player AI keys.**
  - Checked with their provider (one listing and one tiny call) before they are kept, with key checks rate-limited
    so EON can't be used to test stolen keys.
  - Sealed with **AES-256-GCM** under a master key that exists only in the app's environment, with the player's
    account id as additional data: a database dump alone reveals nothing, and a sealed key moved to another account
    won't open.
  - Opened only inside the worker, only for that player's own person, and never logged or sent back to the browser.
    Provider addresses are fixed in code, so a key can only ever reach its own provider.
- **Prompt injection.** No player's words reach any AI: choices are offered options, questions come from a fixed
  list, and facts are escaped inside a data tag the model is told never to obey. Answers are validated (only an
  offered option id), length-capped, filtered and shown as plain text, and one player's text never reaches another
  player's mind.
- **Privacy.** Visits are counted anonymously (Vercel Web Analytics: no cookies, URLs stripped of everything but
  campaign tags, sign-in callbacks not counted). A soul's thoughts are private to its player.
- **Abuse resistance.** A Postgres rate limiter guards every RPC: choices, deeds, questions, prayers and key checks
  included. Public endpoints reject unknown or malformed query parameters so nobody can bust the cache, and the cron
  and worker endpoints check a constant-time bearer token or a signed, time-limited wake-up.
- **Hygiene.**
  - CI runs `npm audit`, lint, type-check, unit tests, the database test suite and a production build.
  - Dependencies are pinned, and new releases wait two weeks before they are used. Dependabot is enabled.
  - Nightly backups are `pg_dump`s **encrypted with AES-256** before they leave the runner.

Found a vulnerability? Please report it privately: see [SECURITY.md](SECURITY.md).

## Caching and cost

EON is built to run on **free tiers**. [docs/ENGINEERING.md](docs/ENGINEERING.md) explains every technique behind this,
with measurements, and it's a good read if you want to learn them.

| Piece | How it stays cheap |
|---|---|
| Event bundles | `/api/pub/bundle/{k}` covers 5 ticks and is `immutable` once complete, so the CDN serves every viewer the same bytes |
| World snapshot | `/api/pub/world/{version}` is immutable while the population is unchanged |
| The land | `/api/pub/land/{month}` carries only woods, soil and herds, keyed by the EON month, so the heavy snapshot is never fetched again because a tree grew |
| Pages | Incremental static regeneration, revalidated every 15–300 s |
| Map | Terrain and agent positions are computed in the browser, on a background thread. A spatial grid finds what is on screen or under the pointer, results that hold for a while are remembered (land or sea, herd layouts, each person's half-hour plan), and trees, animals and people are drawn in batches: about 17 canvas calls where 22,000 were needed |
| Live data | One shared poller for the whole page, paused in hidden tabs. Clocks run on their own between polls |
| Navigation | Link prefetching is off, so a list of names doesn't trigger a server render for each one |
| Database size | Events are partitioned per day and dropped after 14 days (important ones are kept in the chronicle). A size guard throttles the world before it reaches the 500 MB free limit |
| AI text | The world's narrator uses Claude Haiku with a hard **$0.50/day** cap and template fallback. Players' people think with EON's key for their first three days, inside the same cap, and with their players' own keys after that |

## Project layout

```
src/
  app/                 Next.js App Router: pages, server actions, /api/pub/*, /api/me, /api/internal/minds, /api/cron/daily
    me/                a player's life: choices, today's deeds, questions, prayer, connecting their AI
  components/          map/WorldMap (canvas), live clock, feed, event lines, Find me, Your people
  lib/                 env validation, Supabase clients, key sealing, AI providers, the minds worker, email
  shared/              code shared by browser, server and lab: calendar, terrain, climate, nature, demography,
                       a soul's mind (prompts and answer checks), choices, providers
  proxy.ts             session refresh + nonce CSP for interactive routes
supabase/
  migrations/          schema → security → engine → public API → cron → climate → history → minds → free will → living world
  tests/               pgTAP: security model, engine, sign-up, souls, choices, keys, deeds, the living world
  config.toml          local stack + auth settings
lab/                   Monte Carlo demography lab (Node)
scripts/               dev-seed.ts (local only) and one-off maintenance
docs/                  ENGINEERING.md: the techniques behind EON
.github/               CI, nightly encrypted backup, Dependabot
```

## Local development

**Requirements:** Node.js 22+ and Docker (for the local Supabase stack).

```bash
npm install

# start a local Supabase (only the services EON needs)
npx supabase start -x imgproxy,edge-runtime,logflare,vector,supavisor,postgres-meta,studio,storage-api

# apply all migrations to the local database
npx supabase db reset

# point the app at the local stack
npx supabase status -o env   # copy API_URL, PUBLISHABLE_KEY and SECRET_KEY into .env.development.local

npm run dev                   # http://localhost:3000
```

[CONTRIBUTING.md](CONTRIBUTING.md) shows how to grow a local world with 25 years of history.

### Environment variables

Copy `.env.example` to `.env.local`. Never commit real values.

| Variable | Used for |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | browser-safe publishable key |
| `SUPABASE_SECRET_KEY` | server-only key used to read public world data |
| `SIGNUP_EMAIL_CONFIRMATION` | set to `on` to send confirmation emails, which needs custom SMTP in Supabase. Otherwise the sign-up form creates accounts straight away |
| `CRON_SECRET` | bearer token for `/api/cron/daily` |
| `ANTHROPIC_API_KEY` | Claude key for the world's writing |
| `ANTHROPIC_WORKSPACE_ID` | only with an organization-wide key: the workspace to bill |
| `MINDS_SECRET` | signs the database's request to wake the AI worker |
| `BYOK_KEK` | 32 random bytes, base64: the master key that encrypts player AI keys. It never goes to the database |
| `SMTP_USER`, `SMTP_PASS`, `MAIL_FROM` | SMTP relay for the "you are born" emails (the same one Supabase Auth uses). Optional |

## Testing

```bash
npm run lint && npm run typecheck
npm test                      # Vitest: life table, fertility, calendar, climate, nature, key sealing, providers, a soul's mind, choices, emails
npm run lab -- 10 300         # 10 worlds × 300 EON years, with pass/fail checks
npx supabase test db          # pgTAP on a fresh database: 187 checks of the security model, engine, sign-up, souls, choices, keys, deeds and the living world
```

The lab asserts that worlds survive, life expectancy stays near 60, under-5 deaths stay around 3 %, no close-kin union
ever happens, and the population settles near the land's capacity.

## Deployment

1. **Supabase.** Create a project, link it, and push the migrations (`npx supabase db push`). pg_cron starts
   ticking on its own.
2. **Vercel.** Import the repository, set the environment variables above, and deploy. Functions are pinned to
   `bom1` (Mumbai) to sit next to the database, and the daily cron in `vercel.json` keeps the project awake. After
   that, every push to `main` deploys automatically. Apply new migrations before pushing code that needs them.
3. **Supabase Auth.** Set the Site URL and redirect URLs to the Vercel domain.
4. **Email (recommended).** Supabase's built-in mail only reaches your own team, 2 messages an hour. Add a custom SMTP
   provider in Supabase, then set `SIGNUP_EMAIL_CONFIRMATION=on` to verify addresses and enable password emails.
5. **Backups (optional).** Add the `SUPABASE_DB_URL` and `BACKUP_PASSPHRASE` repository secrets to enable the
   nightly encrypted backup.

## Roadmap

- [x] **M0 Foundation:** Supabase, Next.js 16, security headers, CI
- [x] **M1 Genesis:** world engine (clock, fate, fertility, kinship, disease, the first people), live map, feed, chronicle, profiles, family trees
- [x] **M2 Players:** sign-up with email confirmation, a life at once, choices with outside influence, today's deeds, asking your person, own AI key (six providers), birth emails, Find me
- [x] **M3 Minds:** AI-written diaries, prayers, obituaries and news, and every soul's own mind, with a hard daily budget
- [ ] **M4 Towns:** markets, schools, hospitals and doctors, police, bribery, migration
- [ ] **M5 Nations:** cities, countries, governance, calamities
- [ ] **M6 Launch:** Cloudflare front, load tests, security review

## Contributing

EON is open source and contributions are very welcome, from new diseases to better map rendering to clearer docs.

- Start with [CONTRIBUTING.md](CONTRIBUTING.md) for setup and the rules that keep EON safe and free to run.
- Read [docs/ENGINEERING.md](docs/ENGINEERING.md) to see how it's built.
- Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE)
