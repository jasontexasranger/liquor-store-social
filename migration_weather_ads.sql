-- ============================================================================
-- Weather-triggered ad automation
-- ============================================================================
-- A generic trigger -> condition -> action -> rollback -> reporting engine,
-- ported from WEATHER-TRIGGER-ARCHITECTURE.md. Weather is the first trigger
-- type; everything downstream (control locking, safeguards, audit, periods)
-- is trigger-agnostic on purpose, so a future trigger type (an inventory
-- level, a calendar event) only needs a new evaluator branch, not a new
-- table.
--
-- Six tables, all prefixed automation_ so they read as one subsystem:
--   automation_rules      one row per rule someone built
--   automation_control    the "lock": one row per Meta object a rule is
--                          actively controlling, holding the exact
--                          before-state so rollback is precise, not guessed
--   automation_events      append-only audit log — the answer to "why did
--                          this ad change"
--   automation_runs        one row per rule per engine check — the answer
--                          to "why didn't it fire"
--   automation_approvals   pending recommendations for approval-mode rules
--   automation_periods     a tagged window from trigger-fire to rollback,
--                          later filled with real spend/results and a
--                          baseline so lift is visible
--
-- Safety posture (matches the architecture doc's non-negotiables):
--   - new rules start inactive AND approval-required
--   - every rule must define an undo (stop_action NOT NULL)
--   - automation_control.target_id is the PRIMARY KEY, which *is* the
--     one-rule-per-object lock
--   - everything here is admin-only; there is no manager-delegated access
--     to spend automation the way there is to ordinary ads management
-- ============================================================================

-- 1. Rules -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.automation_rules (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  TEXT NOT NULL,
  trigger_type          TEXT NOT NULL DEFAULT 'weather'
                        CHECK (trigger_type IN ('weather')),

  -- Which store's location the weather snapshot is taken from, and which
  -- live Meta campaign this rule is allowed to touch. One rule, one campaign
  -- — a rule that should affect several campaigns is several rules, which
  -- keeps the one-object lock meaningful.
  store_id              TEXT NOT NULL,
  target_campaign_id    TEXT NOT NULL,
  target_campaign_name  TEXT,   -- cached label so the UI doesn't refetch just to show a name

  -- Weather condition. First-class columns rather than only trigger_config,
  -- because weather is the trigger this ships with — but trigger_config
  -- stays as the documented escape hatch for whatever comes next.
  weather_condition     TEXT NOT NULL CHECK (weather_condition IN (
                          'temp_above', 'temp_below',
                          'forecast_high_above', 'forecast_low_below',
                          'consecutive_above', 'consecutive_below',
                          'precip_prob_above', 'snow_expected'
                        )),
  threshold             NUMERIC NOT NULL,   -- °C, or % for precip_prob_above
  consecutive_days      INT NOT NULL DEFAULT 1 CHECK (consecutive_days BETWEEN 1 AND 7),
  lead_time_hours       INT NOT NULL DEFAULT 0 CHECK (lead_time_hours BETWEEN 0 AND 168),
  trigger_config        JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Action. raise_budget_pct/set_budget act on the campaign's ad set;
  -- toggle_on acts on the campaign itself. Every action is clamped to
  -- daily_budget_cents by the executor, never trusted as given.
  action_type           TEXT NOT NULL CHECK (action_type IN (
                          'raise_budget_pct', 'set_budget', 'toggle_on'
                        )),
  action_value          NUMERIC,   -- % for raise_budget_pct, cents for set_budget, unused for toggle_on
  daily_budget_cents            INT NOT NULL CHECK (daily_budget_cents > 0),
  max_incremental_spend_cents   INT NOT NULL CHECK (max_incremental_spend_cents > 0),

  -- The undo. Only one kind exists today (restore exactly what meta_before
  -- captured), but this stays an explicit column — not an assumption baked
  -- into the executor — so "every rule has an undo" is enforced by the
  -- database, not by code review.
  stop_action            TEXT NOT NULL DEFAULT 'restore_previous'
                         CHECK (stop_action = 'restore_previous'),

  active                 BOOLEAN NOT NULL DEFAULT false,
  approval_required      BOOLEAN NOT NULL DEFAULT true,

  created_by             UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ,

  CONSTRAINT automation_rules_stop_required CHECK (stop_action IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS automation_rules_active_idx ON public.automation_rules (active) WHERE active;
CREATE INDEX IF NOT EXISTS automation_rules_store_idx  ON public.automation_rules (store_id);

DROP TRIGGER IF EXISTS automation_rules_touch ON public.automation_rules;
CREATE TRIGGER automation_rules_touch
  BEFORE UPDATE ON public.automation_rules
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 2. Control — the lock --------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.automation_control (
  target_id                 TEXT PRIMARY KEY,   -- Meta campaign id; uniqueness IS the lock
  rule_id                   UUID NOT NULL REFERENCES public.automation_rules(id) ON DELETE CASCADE,
  meta_before                JSONB NOT NULL,     -- {campaign_status, adset_id, daily_budget_cents} snapshot before the first change
  incremental_spend_cents    INT NOT NULL DEFAULT 0,
  started_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_control_rule_idx ON public.automation_control (rule_id);

-- 3. Events — append-only audit log -------------------------------------------
CREATE TABLE IF NOT EXISTS public.automation_events (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id      UUID REFERENCES public.automation_rules(id) ON DELETE SET NULL,
  target_id    TEXT,
  event_type   TEXT NOT NULL CHECK (event_type IN (
                 'executed', 'rollback', 'failed', 'conflict_blocked',
                 'ceiling_hit', 'budget_clamped', 'approved', 'rejected', 'recommended'
               )),
  before_state JSONB,
  after_state  JSONB,
  detail       TEXT,
  created_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,   -- null = system (cron)
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_events_rule_idx    ON public.automation_events (rule_id, created_at DESC);
CREATE INDEX IF NOT EXISTS automation_events_target_idx  ON public.automation_events (target_id, created_at DESC);

-- 4. Runs — one per rule per engine check -------------------------------------
CREATE TABLE IF NOT EXISTS public.automation_runs (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id        UUID NOT NULL REFERENCES public.automation_rules(id) ON DELETE CASCADE,
  snapshot       JSONB NOT NULL,     -- the weather data this check saw
  condition_met  BOOLEAN NOT NULL,
  decision       TEXT NOT NULL CHECK (decision IN (
                   'recommend', 'auto_executed', 'rolled_back', 'ceiling_rolled_back',
                   'holding', 'no_change', 'preview_only', 'error'
                 )),
  detail         TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_runs_rule_idx ON public.automation_runs (rule_id, created_at DESC);

-- 5. Approvals — pending recommendations --------------------------------------
CREATE TABLE IF NOT EXISTS public.automation_approvals (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id        UUID NOT NULL REFERENCES public.automation_rules(id) ON DELETE CASCADE,
  run_id         UUID REFERENCES public.automation_runs(id) ON DELETE SET NULL,
  status         TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','approved','modified','ignored','expired','executed')),
  planned_change JSONB,   -- the executor's preview() output at the moment this was raised
  reviewed_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One pending approval per rule at a time — the engine dedupes against this
-- rather than spamming a new recommendation every check.
CREATE UNIQUE INDEX IF NOT EXISTS automation_approvals_pending_unique
  ON public.automation_approvals (rule_id) WHERE status = 'pending';

-- 6. Periods — triggered window + baseline ------------------------------------
CREATE TABLE IF NOT EXISTS public.automation_periods (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id                 UUID NOT NULL REFERENCES public.automation_rules(id) ON DELETE CASCADE,
  target_id               TEXT NOT NULL,
  status                  TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  started_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at                TIMESTAMPTZ,

  -- Triggered-window metrics, filled by weather-report. "results"/"revenue"
  -- stay NULL rather than a guessed number when there's no purchase-tracking
  -- action on the campaign (these are traffic/reach campaigns without a
  -- pixel) — see the report function's own comment.
  spend_cents             INT, impressions INT, link_clicks INT,
  purchases               INT, revenue_cents INT,

  -- Baseline: the equal-length window immediately before started_at.
  baseline_spend_cents    INT, baseline_impressions INT, baseline_link_clicks INT,
  baseline_purchases      INT, baseline_revenue_cents INT,

  created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_periods_rule_idx   ON public.automation_periods (rule_id, started_at DESC);
CREATE INDEX IF NOT EXISTS automation_periods_open_idx   ON public.automation_periods (status) WHERE status = 'open';

-- 7. RLS — admin-only across all six -------------------------------------------
ALTER TABLE public.automation_rules     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.automation_control   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.automation_events    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.automation_runs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.automation_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.automation_periods   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS automation_rules_admin     ON public.automation_rules;
DROP POLICY IF EXISTS automation_control_admin   ON public.automation_control;
DROP POLICY IF EXISTS automation_events_admin    ON public.automation_events;
DROP POLICY IF EXISTS automation_runs_admin      ON public.automation_runs;
DROP POLICY IF EXISTS automation_approvals_admin ON public.automation_approvals;
DROP POLICY IF EXISTS automation_periods_admin   ON public.automation_periods;

-- One helper (public.is_admin(), already used across the app), applied the
-- same way to all six tables — no per-table policy drift. The edge
-- functions use the service-role client for writes (including the
-- cron-triggered engine/executor/report, which have no user session at
-- all), so these policies are what stands between the browser and the
-- tables, not what the functions rely on internally.
CREATE POLICY automation_rules_admin ON public.automation_rules
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY automation_control_admin ON public.automation_control
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY automation_events_admin ON public.automation_events
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY automation_runs_admin ON public.automation_runs
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY automation_approvals_admin ON public.automation_approvals
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY automation_periods_admin ON public.automation_periods
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

NOTIFY pgrst, 'reload schema';

-- 8. Verify --------------------------------------------------------------------
-- SELECT name, active, approval_required, weather_condition, threshold, action_type
--   FROM public.automation_rules ORDER BY created_at DESC;
-- SELECT target_id, rule_id, incremental_spend_cents, started_at FROM public.automation_control;
-- SELECT event_type, target_id, detail, created_at FROM public.automation_events ORDER BY created_at DESC LIMIT 20;
