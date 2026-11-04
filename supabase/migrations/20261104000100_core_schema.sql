-- EON core schema: the world, its places, its people, and what happens to them.
-- All data schemas are private; only the `api` schema (RPCs) is exposed to the Data API.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists sim;     -- world physics
create schema if not exists social;  -- posts, follows
create schema if not exists app;     -- accounts, God, souls, audit
create schema if not exists llm;     -- LLM job queue & budget
create schema if not exists secrets; -- encrypted player AI keys
create schema if not exists api;     -- the ONLY exposed schema (functions only)

revoke all on schema sim, social, app, llm, secrets from public, anon, authenticated;
revoke all on schema api from public;
grant usage on schema api to anon, authenticated, service_role;

-- Functions are executable by PUBLIC by default in Postgres; flip that for every schema we own.
alter default privileges in schema sim, social, app, llm, secrets, api revoke execute on functions from public;
alter default privileges in schema sim, social, app, llm, secrets, api revoke all on tables from anon, authenticated;
alter default privileges in schema sim, social, app, llm, secrets, api revoke all on sequences from anon, authenticated;

------------------------------------------------------------------------------
-- World singleton
------------------------------------------------------------------------------
create table sim.world (
  id               smallint primary key default 1 check (id = 1),
  seed             bigint not null default 0,
  tick             integer not null default 0,           -- 1 tick = 1 real minute = 1/1440 EON year
  paused           boolean not null default true,        -- the void before Genesis
  genesis_at       timestamptz,
  tick_started_at  timestamptz not null default '-infinity',
  last_tick_ms     integer not null default 0,
  genesis_end_tick integer not null default 43200,       -- first 30 EON years
  capacity_k       integer not null default 1200,        -- settles near 1.7 × K
  fertility_mult   real not null default 1 check (fertility_mult between 0 and 5),
  mortality_mult   real not null default 1 check (mortality_mult between 0.2 and 5),
  disease_mult     real not null default 1 check (disease_mult between 0 and 5),
  crime_mult       real not null default 1 check (crime_mult between 0 and 5),
  female_ratio     real not null default 0.5 check (female_ratio between 0.3 and 0.7),
  autopilot        boolean not null default true,
  roster_version   integer not null default 0,
  updated_at       timestamptz not null default now()
);
insert into sim.world default values;

create table sim.params (
  key   text primary key,
  value jsonb not null
);

-- Monthly life table: cdf[m] = P(death before m months of age), m = 0..1320.
create table sim.life_table (
  month smallint primary key check (month between 0 and 1320),
  cdf   double precision not null
);

------------------------------------------------------------------------------
-- Geography
------------------------------------------------------------------------------
create table sim.sites (            -- candidate land spots computed from the world seed
  id      integer primary key,
  x       real not null,
  y       real not null,
  region  smallint not null,
  taken   boolean not null default false
);

create table sim.countries (
  id           serial primary key,
  name         text not null,
  founded_tick integer not null
);

create table sim.settlements (
  id           serial primary key,
  name         text not null unique,
  kind         text not null default 'village' check (kind in ('village', 'town', 'city')),
  site_id      integer references sim.sites,
  x            real not null,
  y            real not null,
  region       smallint not null default 0,
  country_id   integer references sim.countries,
  founded_tick integer not null,
  treasury     bigint not null default 0,
  food         real not null default 1,
  price_idx    real not null default 1
);

create table sim.buildings (
  id            bigserial primary key,
  settlement_id integer not null references sim.settlements on delete cascade,
  kind          text not null check (kind in ('home', 'farm', 'workshop', 'clinic', 'market', 'temple', 'school', 'hall')),
  x             real not null,
  y             real not null,
  capacity      smallint not null default 6
);
create index on sim.buildings (settlement_id, kind);

------------------------------------------------------------------------------
-- People
------------------------------------------------------------------------------
create sequence sim.agent_id_seq;

create table sim.agents (
  id                 bigint primary key default nextval('sim.agent_id_seq'),
  name               text not null,
  surname            text not null,
  sex                char(1) not null check (sex in ('F', 'M')),
  birth_tick         integer not null,
  fate_tick          integer not null,
  fate_cause         text not null,
  fate_u             double precision not null,
  mother_id          bigint,
  father_id          bigint,
  lineage            bigint[] not null default '{}',   -- parents + grandparents (kin guard)
  generation         smallint not null default 0,
  is_founder         boolean not null default false,
  settlement_id      integer not null references sim.settlements,
  home_id            bigint references sim.buildings,
  occupation         text not null default 'baby',
  partner_id         bigint,
  soul_id            bigint unique,                     -- set when a human player lives this life
  controller         text not null default 'auto' check (controller in ('auto', 'soul', 'god')),
  trait_o            smallint not null, trait_c smallint not null, trait_e smallint not null,
  trait_a            smallint not null, trait_n smallint not null,
  piety              smallint not null, honesty smallint not null,
  health             smallint not null default 100,
  happiness          smallint not null default 60,
  wealth             bigint not null default 0,
  education          smallint not null default 0,
  reputation         smallint not null default 50,
  desired_kids       smallint not null default 0,
  kids               smallint not null default 0,
  fertile_after_tick integer not null default 0,
  diagnosed          text,                              -- chronic diagnosis known to the agent
  appearance_seed    integer not null,
  bucket             smallint not null                  -- id % 120 → evaluated once per EON month
) with (fillfactor = 80);

create index agents_bucket_idx on sim.agents (bucket);
create index agents_fate_idx on sim.agents (fate_tick);
create index agents_single_idx on sim.agents (settlement_id, sex, birth_tick) where partner_id is null;
create index agents_mother_idx on sim.agents (mother_id);
create index agents_father_idx on sim.agents (father_id);

create table sim.dead (
  id            bigint primary key,
  name          text not null,
  surname       text not null,
  sex           char(1) not null,
  birth_tick    integer not null,
  death_tick    integer not null,
  cause         text not null,
  mother_id     bigint,
  father_id     bigint,
  lineage       bigint[] not null default '{}',
  generation    smallint not null default 0,
  is_founder    boolean not null default false,
  settlement_id integer,
  occupation    text,
  kids          smallint not null default 0,
  soul_id       bigint,
  notable       boolean not null default false
);
create index on sim.dead (mother_id);
create index on sim.dead (father_id);
create index on sim.dead (death_tick);

create table sim.unions (
  id         bigserial primary key,
  female_id  bigint not null,
  male_id    bigint not null,
  kind       text not null default 'partner' check (kind in ('partner', 'married')),
  start_tick integer not null,
  end_tick   integer,
  end_reason text
);
create unique index unions_active_f on sim.unions (female_id) where end_tick is null;
create unique index unions_active_m on sim.unions (male_id) where end_tick is null;

create table sim.relationships (
  a        bigint not null,
  b        bigint not null,
  kind     text not null check (kind in ('friend', 'rival')),
  affinity smallint not null default 0,
  since    integer not null,
  primary key (a, b),
  check (a < b)
);

create table sim.pregnancies (
  id             bigserial primary key,
  mother_id      bigint not null,
  father_id      bigint not null,
  conceived_tick integer not null,
  due_tick       integer not null,
  soul_id        bigint,
  outcome        text check (outcome in ('born', 'lost'))
);
create unique index pregnancies_active on sim.pregnancies (mother_id) where outcome is null;
create index pregnancies_due on sim.pregnancies (due_tick) where outcome is null;

------------------------------------------------------------------------------
-- Health
------------------------------------------------------------------------------
create table sim.diseases (
  id             smallint primary key,
  name           text not null unique,
  kind           text not null check (kind in ('infectious', 'chronic')),
  beta           real not null default 0,      -- daily transmission factor
  duration_ticks integer not null default 0,
  severity       smallint not null default 10, -- health penalty while sick
  winter_only    boolean not null default false,
  immunity_ticks integer not null default 0,   -- protection after recovery
  description    text not null
);

insert into sim.diseases (id, name, kind, beta, duration_ticks, severity, winter_only, immunity_ticks, description) values
  (1, 'Static Cough',         'infectious', 0.35, 20, 5,  false, 240,    'A crackling cough that spreads through crowded homes. Harmless but annoying.'),
  (2, 'Rust Flu',             'infectious', 0.55, 28, 20, true,  1440,   'Seasonal fever that corrodes energy for a week. Dangerous for infants and elders.'),
  (3, 'Circuit Pox',          'infectious', 0.70, 40, 10, false, 200000, 'Childhood rash of tiny burnt-out circuits. Once survived, never again.'),
  (10, 'Core Arrest',         'chronic',    0, 0, 0,  false, 0, 'The core stops without warning. The robotic heart attack.'),
  (11, 'Battery Rot',         'chronic',    0, 0, 30, false, 0, 'Slow corrosion of the power cells. Treatable if found early.'),
  (12, 'Memory Leak Syndrome','chronic',    0, 0, 25, false, 0, 'Memories drain away year by year. Affects the old.'),
  (13, 'Coolant Lung',        'chronic',    0, 0, 25, false, 0, 'Coolant floods the breathing vents after infection.');

create table sim.infections (
  agent_id   bigint not null,
  disease_id smallint not null references sim.diseases,
  since_tick integer not null,
  until_tick integer not null,
  primary key (agent_id, disease_id)
);
create index on sim.infections (disease_id);

------------------------------------------------------------------------------
-- History
------------------------------------------------------------------------------
create sequence sim.event_id_seq;

create table sim.events (
  id            bigint not null default nextval('sim.event_id_seq'),
  tick          integer not null,
  kind          text not null,
  importance    smallint not null default 1,   -- 0 trivia, 1 normal, 2 notable, 3 historic
  agent_id      bigint,
  other_id      bigint,
  settlement_id integer,
  data          jsonb not null default '{}',
  primary key (tick, id)
) partition by range (tick);
-- Partitions (one per real day = 1440 ticks) are created by sim.ensure_event_partitions().

create table sim.chronicle (            -- historic events kept forever
  id            bigint primary key,
  tick          integer not null,
  kind          text not null,
  agent_id      bigint,
  other_id      bigint,
  settlement_id integer,
  data          jsonb not null default '{}'
);
create index on sim.chronicle (tick desc);
create index on sim.chronicle (agent_id);

create table sim.world_stats (
  tick        integer primary key,
  population  integer not null,
  births      integer not null,
  deaths      integer not null,
  pregnant    integer not null,
  sick        integer not null,
  avg_wealth  integer not null,
  tick_ms     integer not null
);

------------------------------------------------------------------------------
-- Accounts & God
------------------------------------------------------------------------------
create table app.profiles (
  user_id    uuid primary key references auth.users on delete cascade,
  username   text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  country    text check (char_length(country) <= 56),
  created_at timestamptz not null default now()
);

create table app.god_actions (
  id        bigserial primary key,
  at        timestamptz not null default now(),
  actor     text not null,              -- 'god' or 'autopilot'
  action    text not null,
  target    text,
  params    jsonb not null default '{}',
  tick      integer not null,
  prev_hash text not null,
  hash      text not null
);

create unlogged table app.rate_limits (
  key          text not null,
  window_start timestamptz not null,
  count        integer not null default 0,
  primary key (key, window_start)
);

------------------------------------------------------------------------------
-- Social (filled in later milestones)
------------------------------------------------------------------------------
create table social.posts (
  id         bigserial primary key,
  tick       integer not null,
  agent_id   bigint not null,
  kind       text not null check (kind in ('post', 'obituary', 'news', 'prayer', 'diary')),
  body       text not null check (char_length(body) <= 600),
  source     text not null check (source in ('llm', 'template', 'player', 'god')),
  created_at timestamptz not null default now()
);
create index on social.posts (tick desc);
create index on social.posts (agent_id, tick desc);
