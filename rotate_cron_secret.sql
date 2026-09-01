-- ============================================================================
-- Rotate CRON_SECRET across every existing pg_cron job, and schedule the new
-- hourly ad-spend check.
--
-- Run this ONCE, right after saving the new CRON_SECRET value as an Edge
-- Function secret (Dashboard → Edge Functions → Secrets). It updates the
-- x-cron-secret header baked into each job's stored command so the cron
-- jobs keep authenticating after the rotation, and adds the new
-- lrs-ad-spend-check job (hourly, checks Meta ad spend against the $500 cap).
--
-- Safe to re-run: alter_job just overwrites the command again, and the
-- final cron.schedule call upserts (same jobname = updates in place).
-- ============================================================================

DO $$
DECLARE
  new_secret text := '29b0639c3ac905bc349b548dc0b7a298ae4bb3cad33f2b9a2971ecc26c535293';
  jid bigint;
BEGIN
  -- lrs-publish-scheduled-posts (social-scheduler, every minute)
  SELECT jobid INTO jid FROM cron.job WHERE jobname = 'lrs-publish-scheduled-posts';
  IF jid IS NOT NULL THEN
    PERFORM cron.alter_job(jid, command := format($f$SELECT net.http_post(
      url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/social-scheduler',
      headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', %L),
      body    := '{}'::jsonb
    );$f$, new_secret));
  END IF;

  -- signage-sweep (optisigns, daily 09:10)
  SELECT jobid INTO jid FROM cron.job WHERE jobname = 'signage-sweep';
  IF jid IS NOT NULL THEN
    PERFORM cron.alter_job(jid, command := format($f$select net.http_post(
      url := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/optisigns',
      headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <ANON_KEY>','x-cron-secret', %L),
      body := '{"action":"sweepSignage"}'::jsonb
    );$f$, new_secret));
  END IF;

  -- lrs-market-radar-weekly (market-radar, Mondays 15:00)
  SELECT jobid INTO jid FROM cron.job WHERE jobname = 'lrs-market-radar-weekly';
  IF jid IS NOT NULL THEN
    PERFORM cron.alter_job(jid, command := format($f$select net.http_post(
      url := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/market-radar',
      headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', %L),
      body := '{"action":"scan"}'::jsonb
    );$f$, new_secret));
  END IF;

  -- lrs-ad-spend-check (meta-ads, hourly at :07) — new job for the spend-cap alert feature
  PERFORM cron.schedule('lrs-ad-spend-check', '7 * * * *', format($f$
    SELECT net.http_post(
      url     := 'https://yyveikxfomxmedlxsulh.supabase.co/functions/v1/meta-ads',
      headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', %L),
      body    := jsonb_build_object('action','checkSpendCaps')
    );
  $f$, new_secret));
END $$;

-- Verify -----------------------------------------------------------------
-- SELECT jobname, schedule FROM cron.job ORDER BY jobid;
