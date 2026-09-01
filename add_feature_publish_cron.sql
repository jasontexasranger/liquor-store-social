-- ============================================================================
-- Schedule the daily monthly-features auto-publish job
-- ============================================================================
-- Adds a pg_cron job that calls the new feature-publish edge function every
-- morning. That function republishes each store's website JSON snapshot
-- (website/{store}.json) from whatever's in the current month's features —
-- the same file the manual "Push to website" button writes — so a store no
-- longer shows last month's specials just because nobody remembered to
-- re-click Publish. A store that hasn't built next month's features yet is
-- simply skipped that day; nothing changes until there's something to show.
--
-- Reuses the CRON_SECRET already set as an edge function secret (the same
-- one social-scheduler, market-radar, optisigns and meta-ads use) — nothing
-- new to configure, this just adds one more job that authenticates with it.
--
-- 13:15 UTC = 6:15am Pacific (5:15am during standard time) — before stores
-- open, so any overnight feature edits are live for the day.
--
-- Safe to re-run: cron.schedule upserts by jobname.
-- ============================================================================

SELECT cron.schedule(
  'lrs-feature-publish-daily',
  '15 13 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/feature-publish',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-cron-secret', '29b0639c3ac905bc349b548dc0b7a298ae4bb3cad33f2b9a2971ecc26c535293'
    ),
    body    := '{}'::jsonb
  );
  $$
);

-- Verify -----------------------------------------------------------------
-- SELECT jobname, schedule, active FROM cron.job ORDER BY jobid;
-- Remove job:  SELECT cron.unschedule('lrs-feature-publish-daily');
