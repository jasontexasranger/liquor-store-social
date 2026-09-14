-- ============================================================================
-- Social posts join the campaign concept
-- ============================================================================
-- Campaigns were built for the creative library and later given to features,
-- and the features migration's own comment claimed "features, creatives and
-- posts all share one campaign concept" — but posts never actually got the
-- column. So a campaign could be created and tagged onto an image or a
-- feature row, and then had nowhere to go when someone wrote the post that
-- the campaign was for. This closes that.
--
-- Same shape as creatives.campaign_id and features.campaign_id: nulled rather
-- than cascaded, so archiving or deleting a campaign never takes scheduled
-- posts down with it.
-- ============================================================================

ALTER TABLE public.scheduled_posts
  ADD COLUMN IF NOT EXISTS campaign_id UUID REFERENCES public.campaigns(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.scheduled_posts.campaign_id IS
  'Optional campaign this post belongs to. NULL = not part of a campaign.';

CREATE INDEX IF NOT EXISTS scheduled_posts_campaign_idx
  ON public.scheduled_posts (campaign_id) WHERE campaign_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';

-- Verify -----------------------------------------------------------------
-- SELECT p.scheduled_at, p.store_id, c.name
--   FROM public.scheduled_posts p
--   LEFT JOIN public.campaigns c ON c.id = p.campaign_id
--  ORDER BY p.scheduled_at DESC LIMIT 20;
