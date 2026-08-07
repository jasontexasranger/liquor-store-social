-- ============================================================================
-- Rejected is its own status
-- ============================================================================
-- Rejecting a post used to mark it 'missed', which is also what happens when a
-- post's time passes without anyone approving it. Those are not the same event:
-- one is a decision, the other is a lapse you want to see and fix. Sharing a
-- status meant the calendar could not hide deliberate rejections while still
-- showing the ones that slipped.
--
-- No CHECK constraint on scheduled_posts.status, so this is a data change only.
-- ============================================================================

UPDATE public.scheduled_posts
   SET status = 'rejected'
 WHERE status = 'missed'
   AND error_msg ILIKE 'Rejected%';

-- Verify:
-- SELECT status, error_msg, count(*)
--   FROM public.scheduled_posts GROUP BY status, error_msg ORDER BY status;

NOTIFY pgrst, 'reload schema';
