<!-- This file is the source of truth. Mirror to AGENTS.md / GEMINI.md /
     .cursorrules / .windsurfrules whenever it changes — see the
     `multi-agent-context-sync` skill in ~/.claude/skills/. -->

# MP Program — Marketplace Seller Acquisition Hub

## What this is

`index.html` is a **single-page Supabase-backed app** that tracks every
marketplace **referral / seller-acquisition program** CedCommerce runs. Each
program has its own sellers, conversions, payments and campaigns:

| Program id | Marketplace | Model | Counts as converted |
|---|---|---|---|
| `temu-uk` | Temu UK | £800 agency incentive per new seller with ≥1 real sale | Row filled **green** in the UK sheet's *Seller status UK* tab |
| `temu-us` | Temu US | Referral link (start 16 Feb 2026); incentive amount TBC | **Y** in *breaking the first sale (Y or N)* |
| `shein-us-ab-brands` | SHEIN US | Revenue share, cap 0.5% of qualified GMV (3P) | All required qualification checks (A/B brand SKU, US presence, >$5M revenue, non-CN entity) |

Single-file architecture stays — all UI + JS lives in `index.html`.

## Identity & access

- Sign-in: Google OAuth via Supabase, `hd=threecolts.com`. Email/password
  sign-up is **disabled** in Supabase Auth.
- **Every @threecolts.com account can view** (RLS `is_staff()`). Writes need a
  `team_permissions` row (editor flags) or `super_admin`.
- Super admin: `hsrivastava@threecolts.com` — **exact-string match only**
  (both in `index.html` and `is_super_admin()` in SQL). `kgupta@threecolts.com`
  is seeded as super_admin in `team_permissions`.

## Critical patterns (don't regress)

1. `esc()` on every string interpolated into `innerHTML`.
2. Event delegation for `data-act` buttons; add actions to the delegated handler.
3. `fetchAll()` paginates with `Range` headers (PostgREST 1000-row cap).
4. CSV imports: `pMap` (5 in flight) + intra-batch dedupe.
5. `DB.from()` wrapper writes `audit_log`. `upsert(data, conflictCol)`;
   `team_permissions` conflicts on `email`.
6. Modals: ESC-close, focus-trap, aria. `populateForms()` uses `setOptions()`
   so re-opening a modal never resets a select's value (that bug overwrote
   seller statuses before v2.0.0).
7. Statuses are scoped per marketplace (`seller_statuses.market`: null = Temu,
   `'SHEIN'` = SHEIN funnel). Use `activeStatuses()` / `isConverted()`.
8. Program-specific data lives in `sellers.meta` / `programs.meta` (jsonb),
   shown read-only in the seller modal (`renderSellerMeta`).

## Schema & data

- `supabase/schema.sql` — **full** idempotent schema + RLS + lookups (v2.0.0).
  Supersedes `schema_migration.sql` (kept for history).
- `scripts/build_seed.py` — builds `data/seed/seed.json` from the two final
  program workbooks in `~/Downloads` + the April UK prospect baseline
  (`uk_sellers_import.sql`). Sheet values override the baseline.
- `scripts/load_seed.py [schema|auth|data|verify]` — provisions Supabase from
  `.env` (Management API + secret key) and verifies RLS (anon must see 0 rows).
- `data/` is gitignored: seller PII + the **confidential SHEIN A/B brand list**
  (`data/shein-ab-brands/`). The brand list lives only in the `ab_brands` table
  (staff-only RLS). Never ship it as a static asset.

## Deploy

- Cloudflare Worker `mp-ced-seller-acquisition`, static assets from
  `./public` — which contains **only** a symlink to `../index.html` plus
  `_headers`. Never point `assets.directory` back at the repo root: in v1.x
  that published `uk_sellers_import.sql` (PII).
- `wrangler deploy` from the repo root.
- Run `scripts/load_seed.py schema` before deploying HTML that needs new columns.

## Out of scope (don't rebuild)

- The `cloudflare/workers-autoconfig` branch.
- `webinar-emails/` — separate Zoho webinar campaign (Aug 2026), not part of the hub.

## When working on this repo

1. Read this file end-to-end.
2. Invoke `supabase-spa-hardening` before touching input handling or Supabase calls.
3. Invoke `plan-first-workflow` before any change beyond a one-line tweak.
4. Mirror this file to `AGENTS.md`, `GEMINI.md`, `.cursorrules`, `.windsurfrules`.

## Critical files

- `index.html` — the entire app
- `supabase/schema.sql` — DDL, RLS, seed lookups
- `scripts/build_seed.py`, `scripts/load_seed.py` — data pipeline
- `wrangler.jsonc`, `public/` — Cloudflare deploy
