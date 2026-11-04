# Contributing to EON

Thanks for helping build a world. EON is open source, and every part of it can be improved: its
demography, its diseases, its map, its words and its code.

## Ways to help

- **Fix or report a bug.** See the [open issues](https://github.com/samim-reza/EON/issues).
- **Build the next milestone.** The [roadmap](README.md#roadmap) lists what's coming: players, AI-written
  text, towns, hospitals, police, nations.
- **Improve the simulation.** New diseases, better life events, a more believable economy.
- **Improve the map and pages.** Performance, accessibility and mobile layouts always need work.
- **Improve the docs.** If something confused you, it will confuse the next person too.

Planning something large? Open an issue first, so nobody spends a week on work that won't fit.

## Set up your machine

You need **Node.js 22+** and **Docker**.

```bash
git clone https://github.com/samim-reza/EON.git
cd EON
npm install

# start a local Supabase and apply every migration
npx supabase start -x imgproxy,edge-runtime,logflare,vector,supavisor,postgres-meta,studio,storage-api
npx supabase db reset

# copy API_URL, PUBLISHABLE_KEY and SECRET_KEY into .env.development.local as
# NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY and SUPABASE_SECRET_KEY
npx supabase status -o env

npm run dev
```

Open <http://localhost:3000>. Local sign-up emails appear in Mailpit at <http://127.0.0.1:54324>.

### Be God locally

The real God account is locked to one email hash, so a fresh local database has no God. To work on the
God console, re-point the lock at a throwaway local address:

```bash
docker exec -i supabase_db_EON psql -U postgres -d postgres < scripts/dev-god.sql
GOD_EMAIL=god@eon.local node --env-file=.env.development.local scripts/create-god.mjs god-login.txt
```

Sign in at `/god` with the password from `god-login.txt` (git-ignored), set up an authenticator app, and
press **Let there be EON**.

To skip ahead, grow a local world with history. A 25-year world takes several minutes to build:

```bash
npx tsx scripts/dev-seed.ts 4242 25 | docker exec -i supabase_db_EON psql -U postgres -d postgres
```

## Where things live

| You want to change | Look in |
|---|---|
| How agents live and die | `supabase/migrations/`, and `src/shared/params/demography.json` for the numbers |
| What the public API returns | `api.pub_*` in the migrations, and `src/app/api/pub/` |
| The map | `src/components/map/` and `src/shared/world.ts` |
| Pages | `src/app/` |
| The calendar and clock | `src/shared/time.ts` |

[docs/ENGINEERING.md](docs/ENGINEERING.md) explains the techniques EON relies on and why it uses them.

## Rules that keep EON safe and free to run

**Security**

- Every table keeps row-level security enabled and forced, with no policies. Data leaves only through functions.
- Only the `api` schema is exposed, and it holds functions only. `SECURITY DEFINER` functions must set
  `search_path = ''`.
- Public data goes through `api.pub_*`, granted to `service_role` only. Browsers never call them directly.
- Anything only God may do must call `app.assert_god()`, and must write to the audit log through `app.audit()`.
- API routes must reject unknown query parameters, so nobody can bust the CDN cache.
- Never commit secrets, real email addresses or database dumps.

**Simulation**

- Never edit a migration that has already shipped. Add a new one.
- Randomness in the engine must come from `sim.rnd`, never `random()`, so that a world can be replayed.
- A tick has to stay fast. Prefer set-based SQL to row-by-row loops, and never scan every agent in every tick.
- If you change births or deaths, run the lab and keep the targets: life expectancy near 60, about 3% of deaths
  under 5, and no close-kin unions.

**Cost**

- A page view must not cause a server call for each viewer. Prefer cached endpoints, and derive data in the
  browser where you can.
- Use `prefetch={false}` on `<Link>`s, especially in lists.
- Live data should go through the shared store in `src/components/world-time.ts`, not through a new poller.

## Before you open a pull request

```bash
npm run lint && npm run typecheck
npm test
npm run lab -- 10 300     # if you touched demography
npx supabase test db      # if you touched SQL
```

CI runs all of these on every pull request, plus a production build.

- Keep each pull request to one change, and explain why it's needed.
- Add a test for behaviour you change. Security and engine changes need a pgTAP test in `supabase/tests/`.
- Include a screenshot for anything visual, at phone width too.
- Write commit messages in the imperative: "Add Coolant Fever", not "Added" or "Adds".

## Reporting a security problem

Please don't open a public issue. See [SECURITY.md](SECURITY.md).

## Code of conduct

Everyone taking part agrees to our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your work is released under the project's [MIT License](LICENSE).
