-- ============================================================================
-- Multiple images per post
-- ============================================================================
-- Facebook takes multi-photo posts (upload unpublished, attach by media_fbid);
-- Instagram takes carousels of 2–10. Both need an ordered list, so image_url
-- alone is no longer enough.
--
-- image_url is kept and always mirrors image_urls[1], so anything still
-- reading the single column keeps working.
-- ============================================================================

ALTER TABLE public.scheduled_posts
  ADD COLUMN IF NOT EXISTS image_urls TEXT[] DEFAULT '{}';

-- Backfill existing rows from the single column.
UPDATE public.scheduled_posts
   SET image_urls = ARRAY[image_url]
 WHERE image_url IS NOT NULL
   AND (image_urls IS NULL OR cardinality(image_urls) = 0);

NOTIFY pgrst, 'reload schema';
