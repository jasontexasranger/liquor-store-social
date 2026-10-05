// supabase/functions/sueno-reviews/index.ts
// ============================================================================
// Sueño Reviews feed — mirrors reviews.thesuenocompany.com into our tables
// ============================================================================
// The reviews site publishes four static JSON files built from Google Business
// Profile (reviews, via the GBP API) and Windsor.ai (profile performance).
//
// Why this runs server-side rather than in the browser: those files send no
// Access-Control-Allow-Origin header. A fetch from lrs.thesuenocompany.com
// fails with a bare "Failed to fetch" — verified, not assumed. Deno has no
// same-origin policy, so the fetch simply works here.
//
// Why it caches instead of proxying: the source publishes a FIXED 12-MONTH
// WINDOW. When that window rolls forward, the oldest month stops being
// published. Proxying per page load would silently drop a month of history
// every month. See migration_sueno_reviews.sql for the full reasoning.
//
// This does NOT replace google-reviews. Places gives a lifetime rating and
// count; this gives a windowed average over a known set of reviews. Different
// numbers measuring different things — the leaderboard rating stays on Places.
//
// Actions:
//   sync   — fetch all four files, upsert everything, write a sync-log row.
//            Reachable by pg_cron (x-cron-secret header, no session) or by an
//            admin's "Sync now" button (their own session).
//   status — what the last sync did and how fresh the source is. Any
//            signed-in user, because the Reviews page shows it.
//
// Required edge function secrets:
//   CRON_SECRET                 — same shared secret the other crons use
//   SUPABASE_URL                — auto-set
//   SUPABASE_SERVICE_ROLE_KEY   — auto-set
//
// No key is needed for the source itself: it is a public static site. That is
// also why nothing here sends credentials to it.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

const SOURCE = 'https://reviews.thesuenocompany.com';

// Their store IDs → ours. Verified by matching each profile's address against
// the addresses already hard-coded in the google-reviews function, not by
// guessing from the names — which would have gone wrong for Downtown, listed
// on Google as "Salmon Arm Liquor Store".
//
// 'fort-mac-liquor' is deliberately absent: it is published as
// "awaiting_access" with a null account, has no store in meta_accounts, and
// carries no data. Anything unmapped is skipped and named in the sync log
// rather than guessed at — a wrong store attribution is worse than a gap.
const STORE_MAP: Record<string, string> = {
  'hideaway-liquor':    'hideaway',
  'downtown-liquor':    'downtown',
  'brothers-liquor':    'brothers',
  'cobblestone-liquor': 'cobblestone',
};

// ─── Helpers ──────────────────────────────────────────────────────────────

async function getJson(file: string): Promise<any> {
  const resp = await fetch(`${SOURCE}/${file}`, {
    headers: { Accept: 'application/json' },
  });
  if (!resp.ok) throw new Error(`${file} failed (${resp.status})`);
  const body = await resp.text();
  try {
    return JSON.parse(body);
  } catch {
    // A static host that has lost the file will serve the SPA's index.html
    // with a 200. Parsing it as JSON is the only way to catch that, and
    // saying so beats "Unexpected token <".
    throw new Error(`${file} returned ${resp.status} but not JSON (${body.length} bytes) — the file may have been renamed or removed upstream`);
  }
}

// Empty string and whitespace both mean "nothing here" in this source. Keep
// them out of the DB so `reply IS NULL` can be trusted as "needs a reply".
const clean = (v: unknown): string | null => {
  const s = typeof v === 'string' ? v.trim() : '';
  return s === '' ? null : s;
};

const num = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? v : null;

const ts = (v: unknown): string | null => {
  const s = clean(v);
  if (!s) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
};

async function requireAdmin(authHeader: string | null, sb: ReturnType<typeof createClient>) {
  if (!authHeader) throw new Error('Missing Authorization header');
  const token = authHeader.replace('Bearer ', '');
  const { data: { user }, error } = await sb.auth.getUser(token);
  if (error || !user) throw new Error('Invalid or expired session');
  const { data: role } = await sb
    .from('user_roles').select('role').eq('user_id', user.id).single();
  if (role?.role !== 'admin') throw new Error('Admin only');
  return user.id;
}

async function requireSignedIn(authHeader: string | null, sb: ReturnType<typeof createClient>) {
  if (!authHeader) throw new Error('Missing Authorization header');
  const { data: { user }, error } = await sb.auth.getUser(authHeader.replace('Bearer ', ''));
  if (error || !user) throw new Error('Invalid or expired session');
  return user.id;
}

// ─── Main handler ─────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  try {
    const { action } = await req.json() as { action: string };

    // ── status ───────────────────────────────────────────────────────────
    if (action === 'status') {
      await requireSignedIn(req.headers.get('Authorization'), sb);
      const { data: last } = await sb.from('sueno_review_sync')
        .select('ran_at, ok, reviews_seen, visibility_rows, theme_rows, staff_rows, source_checked_at, skipped_stores, error')
        .order('ran_at', { ascending: false }).limit(1).maybeSingle();
      return Response.json({ last: last ?? null }, { headers: corsHeaders });
    }

    if (action !== 'sync') throw new Error(`Unknown action: ${action}`);

    // ── sync ─────────────────────────────────────────────────────────────
    const cronSecret = Deno.env.get('CRON_SECRET');
    const provided = req.headers.get('x-cron-secret');
    if (!(cronSecret && provided === cronSecret)) {
      await requireAdmin(req.headers.get('Authorization'), sb);
    }

    const skipped = new Set<string>();
    const counts = { reviews: 0, visibility: 0, themes: 0, issues: 0, staff: 0, labels: 0 };
    let sourceCheckedAt: string | null = null;

    try {
      // All four fetched up front and in parallel. If any one fails the whole
      // sync fails rather than writing a half-updated picture — a review whose
      // theme annotation didn't land reads as "nobody mentioned service",
      // which is a wrong answer, not a missing one.
      const [data, visibility, themes, staffMentions] = await Promise.all([
        getJson('liquor-data.json'),
        getJson('liquor-visibility.json'),
        getJson('liquor-themes.json'),
        getJson('staff-mentions.json'),
      ]);

      sourceCheckedAt = ts(data?.lastCheckedAt);
      const syncedAt = new Date().toISOString();

      // ── Reviews ───────────────────────────────────────────────────────
      // The same review appears in several reports (a weekly and a monthly
      // both cover the same day), so dedupe by ID before writing. Keeping the
      // last-seen copy is right: reports are ordered newest-first and a later
      // report carries any edited text or newly posted reply.
      const byId = new Map<string, Record<string, unknown>>();
      for (const report of (data?.reports ?? [])) {
        for (const rv of (report?.reviews ?? [])) {
          const id = clean(rv?.id);
          const theirStore = clean(rv?.restaurant);
          if (!id || !theirStore) continue;

          const storeId = STORE_MAP[theirStore];
          if (!storeId) { skipped.add(theirStore); continue; }

          const rating = num(rv?.rating);
          const date = clean(rv?.date);
          // rating and date are the two fields nothing downstream can work
          // without — a review with neither a star nor a day can't be
          // averaged or placed on a timeline, so it is dropped rather than
          // stored as a zero.
          if (rating === null || !date) continue;

          byId.set(id, {
            id,
            store_id: storeId,
            author: clean(rv?.author),
            rating: Math.round(rating),
            review_text: clean(rv?.text),
            review_date: date,
            source_created_at: ts(rv?.createdAt),
            source_updated_at: ts(rv?.updatedAt),
            reply: clean(rv?.reply),
            reply_updated_at: ts(rv?.replyUpdatedAt),
            synced_at: syncedAt,
          });
        }
      }
      const reviewRows = [...byId.values()];
      if (reviewRows.length) {
        const { error } = await sb.from('sueno_reviews')
          .upsert(reviewRows, { onConflict: 'id' });
        if (error) throw new Error(`reviews: ${error.message}`);
      }
      counts.reviews = reviewRows.length;

      // ── Visibility ────────────────────────────────────────────────────
      const visRows = [];
      for (const row of (visibility?.rows ?? [])) {
        const theirStore = clean(row?.restaurant);
        const month = clean(row?.month);
        if (!theirStore || !month) continue;
        const storeId = STORE_MAP[theirStore];
        if (!storeId) { skipped.add(theirStore); continue; }

        visRows.push({
          store_id: storeId,
          month,
          days_returned: num(row?.daysReturned),
          expected_days: num(row?.expectedDays),
          impressions_desktop_maps: num(row?.impressions_desktop_maps),
          impressions_desktop_search: num(row?.impressions_desktop_search),
          impressions_mobile_maps: num(row?.impressions_mobile_maps),
          impressions_mobile_search: num(row?.impressions_mobile_search),
          search_impressions: num(row?.search_impressions),
          maps_impressions: num(row?.maps_impressions),
          total_impressions: num(row?.total_impressions),
          call_clicks: num(row?.call_clicks),
          website_clicks: num(row?.website_clicks),
          direction_requests: num(row?.direction_requests),
          menu_clicks: num(row?.business_food_menu_clicks),
          source_retrieved_at: ts(row?.retrievedAt),
          synced_at: syncedAt,
        });
      }
      if (visRows.length) {
        const { error } = await sb.from('sueno_review_visibility')
          .upsert(visRows, { onConflict: 'store_id,month' });
        if (error) throw new Error(`visibility: ${error.message}`);
      }
      counts.visibility = visRows.length;

      // ── Themes, issues, staff praise ──────────────────────────────────
      // Only annotations whose review we actually stored are kept. An
      // annotation for an unknown review would be a row that can never join
      // to anything and would inflate every count that touches it.
      const knownReviews = new Set(byId.keys());
      const themeRows = [], issueRows = [], staffRows = [];

      for (const a of (themes?.annotations ?? [])) {
        const rid = clean(a?.id);
        if (!rid || !knownReviews.has(rid)) continue;

        for (const [theme, sentiment] of Object.entries(a?.themes ?? {})) {
          const s = clean(sentiment);
          // The CHECK constraint only allows four sentiments. Anything new
          // upstream is skipped rather than failing the whole sync.
          if (!s || !['positive', 'negative', 'mixed', 'neutral'].includes(s)) continue;
          themeRows.push({ review_id: rid, theme, sentiment: s, synced_at: syncedAt });
        }
        for (const code of (a?.issues ?? [])) {
          const c = clean(code);
          if (c) issueRows.push({ review_id: rid, issue_code: c, synced_at: syncedAt });
        }
        for (const p of (a?.staffPraise ?? [])) {
          const name = clean(p?.name);
          if (!name) continue;
          staffRows.push({
            review_id: rid, name, sentiment: 'positive',
            quote: clean(p?.quote), source: 'theme_praise', synced_at: syncedAt,
          });
        }
      }

      // staff-mentions.json is keyed by review ID and, unlike staffPraise,
      // includes neutral and critical mentions. Kept under its own `source`
      // so the recognition board can filter to positives only — these are
      // customer accounts, not a performance assessment.
      for (const [rid, entry] of Object.entries(staffMentions ?? {})) {
        if (!knownReviews.has(rid)) continue;
        for (const m of ((entry as any)?.staffMentions ?? [])) {
          const name = clean(m?.name);
          if (!name) continue;
          staffRows.push({
            review_id: rid, name, sentiment: clean(m?.sentiment),
            quote: clean(m?.quote), source: 'staff_mentions', synced_at: syncedAt,
          });
        }
      }

      if (themeRows.length) {
        const { error } = await sb.from('sueno_review_themes')
          .upsert(themeRows, { onConflict: 'review_id,theme' });
        if (error) throw new Error(`themes: ${error.message}`);
      }
      if (issueRows.length) {
        const { error } = await sb.from('sueno_review_issues')
          .upsert(issueRows, { onConflict: 'review_id,issue_code' });
        if (error) throw new Error(`issues: ${error.message}`);
      }
      if (staffRows.length) {
        // Two sources can name the same person on the same review; the unique
        // key includes `source`, so both survive without duplicating either.
        const { error } = await sb.from('sueno_review_staff')
          .upsert(staffRows, { onConflict: 'review_id,name,source' });
        if (error) throw new Error(`staff: ${error.message}`);
      }
      counts.themes = themeRows.length;
      counts.issues = issueRows.length;
      counts.staff = staffRows.length;

      // Issue labels, mirrored so the UI never hardcodes a list that drifts.
      const labelRows = Object.entries(themes?.issueDescriptions ?? {})
        .map(([issue_code, description]) => ({
          issue_code, description: String(description), synced_at: syncedAt,
        }));
      if (labelRows.length) {
        const { error } = await sb.from('sueno_review_issue_labels')
          .upsert(labelRows, { onConflict: 'issue_code' });
        if (error) throw new Error(`issue labels: ${error.message}`);
      }
      counts.labels = labelRows.length;

      await sb.from('sueno_review_sync').insert({
        ok: true,
        reviews_seen: counts.reviews,
        visibility_rows: counts.visibility,
        theme_rows: counts.themes,
        staff_rows: counts.staff,
        source_checked_at: sourceCheckedAt,
        skipped_stores: skipped.size ? [...skipped] : null,
        detail: counts,
      });

      return Response.json({
        ok: true, counts,
        sourceCheckedAt,
        skippedStores: [...skipped],
      }, { headers: corsHeaders });

    } catch (e) {
      // A failed sync must leave a trace. Without this row the tables just
      // keep serving the last good data and look perfectly healthy, which is
      // exactly how a dead feed goes unnoticed for a month.
      const message = e instanceof Error ? e.message : String(e);
      await sb.from('sueno_review_sync').insert({
        ok: false,
        source_checked_at: sourceCheckedAt,
        skipped_stores: skipped.size ? [...skipped] : null,
        error: message,
        detail: counts,
      });
      throw e;
    }

  } catch (e) {
    return Response.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 400, headers: corsHeaders },
    );
  }
});
