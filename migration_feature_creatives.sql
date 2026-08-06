-- ============================================================================
-- Monthly feature creatives
-- ============================================================================
-- Price ads generated in bulk from a month's features need to be findable
-- later by the month they belong to, not just by when someone happened to
-- press the button. created_at is close to that in practice but wrong the
-- moment you regenerate August in September, or backfill an earlier month.
--
-- feature_id and template_id are what make regeneration safe: rerunning a
-- month replaces the images it produced last time instead of piling up
-- duplicates.
-- ============================================================================

ALTER TABLE public.creatives
  ADD COLUMN IF NOT EXISTS period      DATE,
  ADD COLUMN IF NOT EXISTS feature_id  UUID REFERENCES public.features(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS template_id UUID,
  ADD COLUMN IF NOT EXISTS source      TEXT NOT NULL DEFAULT 'upload';

COMMENT ON COLUMN public.creatives.period IS
  'First of the month this creative belongs to. NULL for ad-hoc uploads.';
COMMENT ON COLUMN public.creatives.source IS
  'upload = added by hand. feature_batch = generated from a monthly feature.';

-- template_id is deliberately not a foreign key: deleting a template should
-- not cascade into, or block, creatives that were already produced from it.

CREATE INDEX IF NOT EXISTS creatives_period_idx
  ON public.creatives (period DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS creatives_feature_idx
  ON public.creatives (feature_id) WHERE feature_id IS NOT NULL;

-- One image per feature per template. A rerun deletes and reinserts rather
-- than upserting — the storage object changes too — so this is a guard
-- against double-clicks and overlapping sessions, not the normal path.
CREATE UNIQUE INDEX IF NOT EXISTS creatives_feature_template_unique
  ON public.creatives (feature_id, template_id)
  WHERE feature_id IS NOT NULL AND template_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';
