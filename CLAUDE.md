# LRS — Liquor Store Social

Social posting, Meta ads, monthly features, price creatives, shelf talkers, digital signage (OptiSigns) and reviews for The Sueño Company's four BC liquor stores. Live at lrs.thesuenocompany.com.

| store_id | Store | Address |
|---|---|---|
| hideaway | Hideaway Liquor Store | 973 Lakeshore Dr, Salmon Arm |
| downtown | Downtown Liquor Store | 111 Lakeshore Dr, Salmon Arm |
| brothers | Brothers Liquor Store & Tavern | 430 Main St, Sicamous |
| cobblestone | Cobblestone Liquor Store | 1479 Fisher Rd, Cobble Hill (Village West ad account; separate OptiSigns key) |

## The owner

Jason is not a developer. Do every step yourself: git, SQL reads, verification. Hand him something only when he truly has to do it, and then give one copy-pasteable block that starts with `cd ~/Projects/lrs`. Make UI entry points obvious, never hover-only or ghost-styled; "I can't find where to…" has been the most common complaint.

## Stack and deploy

- **The whole app is `index.html`** (~20k lines): React 18 UMD + Babel standalone + Tailwind CDN, no build step. Pushing to `main` deploys it to Netlify.
- **Supabase project `yyveikxfomxmedlxsulh` (TSC_SOCIAL)**, already linked in the CLI. Netlify does **not** deploy edge functions in `supabase/functions/*`; each one needs `supabase functions deploy <name>`.
- Migrations are `migration_*.sql` at the repo root. Append each new one to `migration_RUN_ALL.sql`. Check that a migration actually landed before building on it; unrun migrations caused many past "could not find column/table" errors.
- Daily jobs run through pg_cron and call edge functions with an `x-cron-secret` header.

## Before committing

1. Parse the `<script type="text/babel">` block with `@babel/parser` (plugins: jsx).
2. Scan for unbound identifiers with `@babel/traverse` (`ReferencedIdentifier` without a scope binding, minus browser globals). This has caught real bugs: a button calling a function from another component, and two upload handlers calling each other's save. Swallowed by empty `catch{}` blocks, those failed silently. `initSB` is a known leftover in the unused `SetupScreen`.
3. When something can be exercised headlessly, extract the function from `index.html` and test it against a stubbed Supabase client. Stubs must return copies of rows, as the real client does.

## Things that have bitten before

- `scheduled_posts.image_url` / `image_urls` store the image URL itself. Never delete a creative's file without repointing unpublished posts (`repointScheduledPosts`).
- `creatives` is unique on `(feature_id, template_id)`, so regenerating updates the row in place.
- Template text: `ad_template_fields.font_size` pins the size. When it's null, every product auto-fits and short names render huge. Use "Fit to box" + "Check all products" in the template editor.
- OptiSigns' API has no file-upload mutation, so signage uses links or the zip download.
- Meta posting/ads use a personal long-lived user token (`META_USER_TOKEN`, about 60 days).

## Copy rules for anything generated

Canadian spelling. No hashtags. Recipes in ounces. Monthly features say "this month", not "this week". Price posts end with a line break, then "Prices exclude tax & deposit - while supplies last".

## Roles

Managers can make single posts and use the product library. Bulk feature create/schedule, ads and the social inbox are admin-only.

## Never commit secrets

The GitHub repo is public. Tokens, API keys and the cron secret go in Supabase secrets or Vault, never in a file here.
