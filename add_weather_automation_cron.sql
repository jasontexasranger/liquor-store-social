-- ============================================================================
-- Schedule the weather-triggered ad automation engine + reporting
-- ============================================================================
-- Two jobs:
--
--   lrs-weather-rules-check   every 2 hours, on the hour
--     Calls weather-rules-check with an empty body, which loops every
--     active=true automation_rules row, pulls fresh weather for that rule's
--     store, and decides recommend / auto_executed / rolled_back / holding /
--     no_change per rule. Because this call carries x-cron-secret, canAct is
--     true — this is the only path that lets the engine actually execute or
--     roll back a live campaign (an admin's manual "check now" from the UI
--     never gets that; it always previews).
--
--   lrs-weather-report         every 2 hours, offset 30 minutes after the
--                              rules check
--     Fills in real spend/impressions/clicks/purchases for every open (or
--     recently-closed) automation_periods row from Graph Insights, and
--     feeds real spend back into automation_control.incremental_spend_cents
--     so the next rules-check enforces the spend ceiling on actual dollars.
--     Offset by 30 minutes so a rule that just fired has at least a little
--     delivery data before the first report pass reads it.
--
-- Reuses the CRON_SECRET already set as an edge function secret (same one
-- feature-publish, social-scheduler, market-radar, optisigns and meta-ads
-- use) — nothing new to configure.
--
-- Both weather-rules-check and weather-report must have "Verify JWT" turned
-- OFF in the Supabase dashboard (Edge Functions → function → Settings) —
-- pg_net sends no JWT, only the x-cron-secret header these functions check
-- for themselves. weather-provider and weather-execute also need "Verify
-- JWT" off, since weather-rules-check calls them server-to-server the same
-- way.
--
-- Safe to re-run: cron.schedule upserts by jobname.
-- ============================================================================

SELECT cron.schedule(
  'lrs-weather-rules-check',
  '0 */2 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/weather-rules-check',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-cron-secret', '29b0639c3ac905bc349b548dc0b7a298ae4bb3cad33f2b9a2971ecc26c535293'
    ),
    body    := '{}'::jsonb
  );
  $$
);

SELECT cron.schedule(
  'lrs-weather-report',
  '30 */2 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/weather-report',
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
-- Remove jobs:
--   SELECT cron.unschedule('lrs-weather-rules-check');
--   SELECT cron.unschedule('lrs-weather-report');
