// supabase/functions/google-reviews/index.ts
// Google Reviews — a daily rating/review-count leaderboard, plus each
// store's most recent reviews, via Google's Places API (New). This never
// scrapes Google Maps: scraping is against Google's terms and the page
// markup shifts without warning, which makes it a bad foundation for
// something that has to keep running unattended. The trade-off is Places
// API only exposes a store's 5 most recent reviews, not full history —
// fine here, since this is a live leaderboard, not a replacement for a
// one-off deep report.
//
// Actions:
//   setupPlaceIds — admin only, one-time (safe to re-run). Looks up each
//                   store's Google Place ID via Places Text Search and
//                   saves it to meta_accounts.google_place_id.
//   sync          — pulls rating/count/reviews for every store that has a
//                   google_place_id set. Callable two ways: by pg_cron
//                   (daily, via the x-cron-secret header, no user session)
//                   or by an admin's "Sync now" button (via their session).
//
// Required edge function secrets:
//   GOOGLE_PLACES_API_KEY     — Google Cloud API key, restricted to
//                                 Places API (New)
//   CRON_SECRET                — same shared secret market-radar and
//                                 social-scheduler use
//   SUPABASE_URL                — auto-set
//   SUPABASE_SERVICE_ROLE_KEY   — auto-set

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

const PLACES_BASE = 'https://places.googleapis.com/v1';

// Google's own listing names don't always match ours — "Downtown" is
// listed as "Salmon Arm Liquor Store", "Cobblestone" as "Cobblestone Beer
// & Wine" — so each store gets an exact, hand-verified query rather than
// deriving one from our internal display name.
const SEARCH_QUERIES: Record<string, string> = {
  hideaway:    'Hideaway Liquor Store, 973 Lakeshore Dr W, Salmon Arm, BC',
  downtown:    'Salmon Arm Liquor Store, 111 Lakeshore Dr NE, Salmon Arm, BC',
  brothers:    'Brothers Liquor Store, 430 Main St, Sicamous, BC',
  cobblestone: 'Cobblestone Beer & Wine, 1479 Fisher Rd, Cobble Hill, BC',
};

// ─── Auth helper (admin-authenticated calls only) ──────────────────────────

async function requireAdmin(authHeader: string | null, sb: ReturnType<typeof createClient>): Promise<string> {
  if (!authHeader) throw new Error('Missing Authorization header');
  const token = authHeader.replace('Bearer ', '');
  const { data: { user }, error } = await sb.auth.getUser(token);
  if (error || !user) throw new Error('Invalid or expired session');

  const { data: role } = await sb
    .from('user_roles')
    .select('role')
    .eq('user_id', user.id)
    .single();
  if (role?.role !== 'admin') throw new Error('Admin only');
  return user.id;
}

// ─── Places API (New) helpers ───────────────────────────────────────────────

async function findPlaceId(query: string, apiKey: string): Promise<{ id: string; name: string } | null> {
  const resp = await fetch(`${PLACES_BASE}/places:searchText`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': 'places.id,places.displayName,places.formattedAddress',
    },
    body: JSON.stringify({ textQuery: query }),
  });
  if (!resp.ok) throw new Error(`Places text search failed (${resp.status}): ${await resp.text()}`);
  const data = await resp.json();
  const first = (data.places || [])[0];
  if (!first) return null;
  return { id: first.id, name: first.displayName?.text || query };
}

interface PlaceDetails {
  rating?: number;
  userRatingCount?: number;
  reviews?: Array<{
    rating: number;
    relativePublishTimeDescription?: string;
    publishTime?: string;
    text?: { text?: string };
    authorAttribution?: { displayName?: string };
  }>;
}

async function fetchPlaceDetails(placeId: string, apiKey: string): Promise<PlaceDetails> {
  const resp = await fetch(`${PLACES_BASE}/places/${placeId}`, {
    headers: {
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': 'rating,userRatingCount,reviews',
    },
  });
  if (!resp.ok) throw new Error(`Place details failed (${resp.status}): ${await resp.text()}`);
  return await resp.json();
}

// ─── Main handler ─────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const apiKey = Deno.env.get('GOOGLE_PLACES_API_KEY');

    const { action } = await req.json() as Record<string, unknown> & { action: string };

    // ── sync ─────────────────────────────────────────────────────────────
    // Reachable two ways: pg_cron's daily job (no user session — authorized
    // by the shared x-cron-secret header, same pattern as market-radar) or
    // an admin's "Sync now" button (authorized by their own session).
    if (action === 'sync') {
      const cronSecret = Deno.env.get('CRON_SECRET');
      const provided = req.headers.get('x-cron-secret');
      if (!(cronSecret && provided === cronSecret)) {
        await requireAdmin(req.headers.get('Authorization'), sb);
      }
      if (!apiKey) throw new Error('GOOGLE_PLACES_API_KEY not configured');

      const { data: stores, error: storesErr } = await sb
        .from('meta_accounts')
        .select('store_id, google_place_id')
        .not('google_place_id', 'is', null);
      if (storesErr) throw new Error(storesErr.message);

      const results: Array<{ store_id: string; ok: boolean; error?: string }> = [];
      for (const store of stores ?? []) {
        const storeId = store.store_id as string;
        const placeId = store.google_place_id as string;
        try {
          const details = await fetchPlaceDetails(placeId, apiKey);
          const fetchedAt = new Date().toISOString();

          if (typeof details.rating === 'number' && typeof details.userRatingCount === 'number') {
            const { error } = await sb.from('store_review_snapshots').insert({
              store_id: storeId,
              rating: details.rating,
              review_count: details.userRatingCount,
              fetched_at: fetchedAt,
            });
            if (error) throw new Error(error.message);
          }

          // Recent reviews are always a full refresh — Google only ever
          // hands us its current top 5, so old rows would just be stale.
          await sb.from('store_review_recent').delete().eq('store_id', storeId);
          const reviews = details.reviews ?? [];
          if (reviews.length) {
            const rows = reviews.map(r => ({
              store_id: storeId,
              author_name: r.authorAttribution?.displayName ?? null,
              rating: r.rating,
              relative_time: r.relativePublishTimeDescription ?? null,
              review_time: r.publishTime ? Math.floor(new Date(r.publishTime).getTime() / 1000) : null,
              review_text: r.text?.text ?? null,
              fetched_at: fetchedAt,
            }));
            const { error } = await sb.from('store_review_recent').insert(rows);
            if (error) throw new Error(error.message);
          }

          results.push({ store_id: storeId, ok: true });
        } catch (e) {
          results.push({ store_id: storeId, ok: false, error: e instanceof Error ? e.message : String(e) });
        }
      }

      return Response.json({ results }, { headers: corsHeaders });
    }

    // Everything past this point is an in-app admin action.
    await requireAdmin(req.headers.get('Authorization'), sb);

    // ── setupPlaceIds ────────────────────────────────────────────────────
    if (action === 'setupPlaceIds') {
      if (!apiKey) throw new Error('GOOGLE_PLACES_API_KEY not configured');

      const results: Array<{ store_id: string; ok: boolean; name?: string; error?: string }> = [];
      for (const [storeId, query] of Object.entries(SEARCH_QUERIES)) {
        try {
          const found = await findPlaceId(query, apiKey);
          if (!found) throw new Error('No match found');
          const { error } = await sb
            .from('meta_accounts')
            .update({ google_place_id: found.id })
            .eq('store_id', storeId);
          if (error) throw new Error(error.message);
          results.push({ store_id: storeId, ok: true, name: found.name });
        } catch (e) {
          results.push({ store_id: storeId, ok: false, error: e instanceof Error ? e.message : String(e) });
        }
      }
      return Response.json({ results }, { headers: corsHeaders });
    }

    throw new Error(`Unknown action: ${action}`);
  } catch (e) {
    return Response.json(
      { error: e instanceof Error ? e.message : String(e) },
      { status: 400, headers: corsHeaders },
    );
  }
});
