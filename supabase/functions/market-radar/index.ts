// supabase/functions/market-radar/index.ts
// Market Radar — a weekly scan of visible liquor-brand advertising and
// promotion activity around our region (Okanagan / Shuswap), across the
// public ad transparency libraries (Meta, Google, TikTok) plus local news,
// events, and public social posts. Advisory only: nothing here publishes or
// schedules anything by itself, it just gives an admin a weekly digest and a
// one-line suggested response per brand to act on (or not) themselves.
//
// Actions:
//   scan          — run a fresh scan and save it as a new report. Callable
//                    two ways: by pg_cron (weekly, via the x-cron-secret
//                    header, no user session) or by an admin clicking
//                    "Run scan now" in the app (via their session, checked
//                    against user_roles).
//   list          — recent reports + their entries, admin only.
//   markReviewed  — flag a report as looked at, admin only.
//
// Required edge function secrets:
//   ANTHROPIC_API_KEY         — same key aiWrite/assistantChat already use
//   CRON_SECRET                — same shared secret social-scheduler uses
//   SUPABASE_URL               — auto-set
//   SUPABASE_SERVICE_ROLE_KEY  — auto-set
//
// Optional edge function secret:
//   SCRAPECREATORS_API_KEY     — api.scrapecreators.com key. Web search can
//                                 only see earned media (news, events, public
//                                 posts) — it can't see inside Meta's actual
//                                 Ad Library. If this key is set, every brand
//                                 Claude finds gets a follow-up check against
//                                 the real Ad Library to confirm whether it
//                                 currently has a live paid Meta/Instagram ad
//                                 running. If unset, the scan still runs —
//                                 entries just won't have that badge.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

// Two separate, unconnected markets — Hideaway/Downtown/Brothers are in the
// Shuswap, Cobblestone is on Vancouver Island. A brand active near one tells
// you nothing about the other, so every entry gets tagged with which one it
// applies to rather than treating this as a single combined region.
const REGIONS = [
  { id: 'shuswap',  label: 'Okanagan / Shuswap, BC (around Salmon Arm and Sicamous) — Hideaway, Downtown, Brothers' },
  { id: 'cowichan', label: 'Cowichan Valley, Vancouver Island, BC (around Cobble Hill) — Cobblestone' },
];
const REGION = REGIONS.map(r => r.label).join(' • ');

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

// ─── The scan itself ────────────────────────────────────────────────────────

interface RadarEntry {
  brand: string;
  // 'national' is only ever set by the Ad Library category sweep below
  // (checkMetaAds discovery mode), for a brand with a live ad but no
  // regional signal — Claude's own research never tags an entry this way.
  region: 'shuswap' | 'cowichan' | 'national';
  category: string;
  activity: 'low' | 'medium' | 'high';
  channels: string[];
  summary: string;
  suggested_action?: string;
  sources?: { title?: string; url: string }[];
}

const SYSTEM_PROMPT = `You are a market-intelligence researcher for a small liquor-store group,
The Sueño Company. It runs four stores in two separate, unconnected markets —
treat these as two independent research jobs, not one combined region:

1. "shuswap" — Hideaway, Downtown, and Brothers Liquor Stores, around Salmon
   Arm and Sicamous, in the Okanagan / Shuswap region of interior BC.
2. "cowichan" — Cobblestone Liquor Store, around Cobble Hill, in the Cowichan
   Valley on Vancouver Island, BC. This is hundreds of km from the Shuswap
   stores — a brand's activity near one market says nothing about the other.

Today's date is ${new Date().toISOString().slice(0, 10)}. This is a WEEKLY
scan, so it should surface what's current, not a brand's entire history —
any news article or PR coverage you cite must be dated within the last 30
days of today. If a news piece is older than that, don't use it to justify
an entry (an old article surfacing in search results doesn't mean the
brand is currently active). Ongoing, undated things — an active Meta ad
that's currently running, a brand's regular social posting, a festival or
event happening soon — are fine regardless of when you happened to find
them, since those describe current state rather than a moment in the past.

Research BOTH markets this week. Find which liquor brands are visibly
advertising or promoting themselves in EACH region, across ANY category —
beer, wine, whisky, rum, gin, vodka, tequila, other spirits, RTD/coolers,
cider, liqueurs — not just one category. Tag every entry with which region
it belongs to.

Check these sources for each region:
- Meta Ad Library (facebook.com/ads/library) for brand pages advertising
  in Canada / British Columbia
- Google Ads Transparency Center (adstransparency.google.com)
- TikTok Creative Center (ads.tiktok.com/business/creativecenter)
- Local news, event and festival sites, restaurant/bar pages, and sponsor
  pages for that specific area — news/PR articles must be within the last
  30 days
- Public social posts, brand pages, hashtags, and influencer posts visible
  without logging in

Creative visibility is a real signal; exact ad spend is not something you can
know from these sources, so never invent a dollar figure — describe activity
in terms of what you actually observed (channel, frequency, recency, tone).

For each brand you find meaningful activity for, decide a simple activity
label:
- high — active on multiple channels, or frequent/recent creative
- medium — active on one channel, or occasional creative
- low — a single stale or minor sighting, worth noting but not urgent

For "suggested_action", write one short, concrete, in-region idea for how the
relevant Sueño store(s) could respond — e.g. matching the brand's promotion
with a feature, price ad, tasting, or shelf placement of a Sueño product that
competes or complements. Keep it to one sentence. Leave it out if nothing
sensible comes to mind for that entry.

When you're done researching, reply with ONLY a fenced JSON code block
(\`\`\`json ... \`\`\`) containing an array of entries, nothing else before or
after it. Each entry:
{"brand":"","region":"shuswap|cowichan",
 "category":"beer|wine|whisky|rum|gin|vodka|tequila|other spirit|RTD/cooler|cider|liqueur|other",
 "activity":"low|medium|high","channels":["Meta Ads","Local news",...],
 "summary":"one or two sentences on what you found and where",
 "suggested_action":"one sentence, or omit",
 "sources":[{"title":"","url":""}]}

Aim for roughly 5-10 entries per region (10-20 total) — whatever the research
actually turns up for each, don't pad it out, and don't skip either region
even if one has less to report. If you genuinely find nothing worth
reporting in a region, just include fewer entries for it. If nothing at all
is found across both, reply with an empty JSON array: \`\`\`json\n[]\n\`\`\``;

// ─── Real Ad Library verification (ScrapeCreators) ─────────────────────────
// Claude's web_search tool can only see earned media — it has no way to look
// inside Meta's actual Ad Library. This does: a real keyword search against
// api.scrapecreators.com, scoped to Canada, active ads only. Best-effort —
// if the key isn't set, or a lookup fails/times out, the entry just goes
// through without the badge rather than failing the whole scan.
//
// Meta's public Ad Library data has no province/region breakdown for
// ordinary commercial ads (only political/issue ads expose delivery-by-
// region), so `country=CA` alone can surface a completely unrelated local
// advertiser anywhere in Canada whose ad copy just happens to mention the
// brand word — e.g. a Quebec convenience store's own post about "Corona".
// Since there's no real geo field to filter on, two cheap proxies stand in:
// (1) the advertiser's actual page name has to resemble the brand name,
// not just the ad text, and (2) predominantly-French ad copy is treated as
// a signal of Quebec-local content and skipped, on the assumption that a
// BC/Shuswap/Cowichan-relevant brand's own advertising is in English.
interface MetaAdCheck {
  active: boolean;
  count: number;
  sampleUrl: string | null;
  platforms: string[];
}

function significantWords(s: string): string[] {
  // Normalize accented Latin letters (ñ, é, etc.) to their base letter before
  // stripping punctuation, so "Sueños" becomes the word "suenos" rather than
  // fracturing into "sue" + "os" — the earlier version did the latter, which
  // still happened to work by accident but was one stray apostrophe away from
  // a false match or a false miss.
  const normalized = s.normalize('NFD').replace(/[̀-ͯ]/g, '');
  return normalized.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(w => w.length > 2);
}

function looksFrench(text: string): boolean {
  if (!text) return false;
  const markers = /\b(vous|notre|votre|dépanneur|épicerie|être|avec|pour|chez|magasin|québec|québécois|c'est|nos produits)\b/i;
  const accented = (text.match(/[éèêàçùûôî]/gi) || []).length;
  return markers.test(text) || accented > text.length * 0.02;
}

async function checkMetaAds(brand: string, key: string): Promise<MetaAdCheck | null> {
  try {
    const url = new URL('https://api.scrapecreators.com/v1/facebook/adLibrary/search/ads');
    url.searchParams.set('query', brand);
    url.searchParams.set('country', 'CA');
    url.searchParams.set('status', 'ACTIVE');
    // keyword_unordered rather than keyword_exact_phrase: exact-phrase was
    // too strict and produced false negatives on real brands (e.g. brand
    // "Sueños Tequila" not matching an actual live ad from page "Sueños
    // Artisan Tequila", because the extra word broke the exact phrase).
    // Precision is handled on our side instead, via the page-name overlap
    // and French-language checks below.
    url.searchParams.set('search_type', 'keyword_unordered');

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    const res = await fetch(url, { headers: { 'x-api-key': key }, signal: controller.signal });
    clearTimeout(timeout);
    if (!res.ok) return null;

    const data = await res.json();
    const results: Array<{
      ad_archive_id?: string;
      page_name?: string;
      publisher_platform?: string[];
      snapshot?: { body?: { text?: string } };
    }> = Array.isArray(data.searchResults) ? data.searchResults : [];
    if (!results.length) return { active: false, count: 0, sampleUrl: null, platforms: [] };

    const brandWords = significantWords(brand);
    const relevant = results.filter(r => {
      const pageWords = significantWords(r.page_name || '');
      const nameMatches = brandWords.some(w => pageWords.includes(w)) || pageWords.some(w => brandWords.includes(w));
      return nameMatches && !looksFrench(r.snapshot?.body?.text || '');
    });
    if (!relevant.length) return { active: false, count: 0, sampleUrl: null, platforms: [] };

    const pick = relevant[0];
    return {
      active: true,
      count: relevant.length,
      sampleUrl: pick.ad_archive_id
        ? `https://www.facebook.com/ads/library/?id=${pick.ad_archive_id}`
        : null,
      platforms: Array.isArray(pick.publisher_platform) ? pick.publisher_platform : [],
    };
  } catch {
    return null; // network error, timeout, or bad JSON — just skip this brand
  }
}

// ─── Ad Library category sweep (national) ──────────────────────────────────
// checkMetaAds() above only verifies brands Claude's web search already
// found — so anything Claude's search missed entirely (no news, no public
// social post) never gets checked at all, no matter how good the Ad Library
// check is. This runs the other direction: it queries the Ad Library
// directly for broad alcohol categories, so a brand running Meta ads gets
// caught even if it never showed up anywhere else this week.
//
// There's still no province/region field on ordinary commercial ads (same
// limitation as above), so this can only ever be a Canada-wide sweep, not a
// BC one. Two things make that usable rather than just a firehose of
// Diageo/Molson-scale national campaigns: (1) it's capped to a handful of
// results per category term, and (2) any advertiser whose name matches the
// curated regional-producer lists below gets tagged into the actual
// shuswap/cowichan region instead of the generic 'national' bucket, so the
// weekly report can visually separate "a local competitor is advertising"
// from "national brand X still runs ads, as always."
const CATEGORY_TERMS: { term: string; category: string }[] = [
  { term: 'craft beer',       category: 'beer' },
  { term: 'BC wine',          category: 'wine' },
  { term: 'canadian whisky',  category: 'whisky' },
  { term: 'craft distillery', category: 'other spirit' },
  { term: 'tequila',          category: 'tequila' },
  { term: 'vodka',            category: 'vodka' },
  { term: 'hard seltzer',     category: 'RTD/cooler' },
  { term: 'craft cider',      category: 'cider' },
  { term: 'liquor store',     category: 'other' },
];

// Not exhaustive — a lightweight name-match heuristic, not a verified
// directory. Wrong or missing entries here just mean a producer shows up
// as 'national' instead of its real region; nothing is lost or misreported,
// it's just a less specific label.
const SHUSWAP_PRODUCERS = [
  'sunnybrae', 'larch hills', 'recline ridge', 'marionette', 'ovino',
  'celista', 'crannog', 'rockridge', 'shuswap', 'salmon arm', 'sicamous',
];
const COWICHAN_PRODUCERS = [
  'unsworth', 'blue grouse', 'merridale', 'averill creek', 'cherry point',
  'zanatta', 'deep roots', 'small block', 'riot brewing', '39 days',
  'craig street', 'cowichan', 'cobble hill', 'duncan',
];

function guessRegion(pageName: string): 'shuswap' | 'cowichan' | 'national' {
  const words = significantWords(pageName).join(' ');
  const lower = pageName.toLowerCase();
  if (SHUSWAP_PRODUCERS.some(p => lower.includes(p) || words.includes(p))) return 'shuswap';
  if (COWICHAN_PRODUCERS.some(p => lower.includes(p) || words.includes(p))) return 'cowichan';
  return 'national';
}

async function searchAdLibrary(query: string, key: string): Promise<Array<{
  ad_archive_id?: string;
  page_name?: string;
  publisher_platform?: string[];
  snapshot?: { body?: { text?: string } };
}>> {
  try {
    const url = new URL('https://api.scrapecreators.com/v1/facebook/adLibrary/search/ads');
    url.searchParams.set('query', query);
    url.searchParams.set('country', 'CA');
    url.searchParams.set('status', 'ACTIVE');
    url.searchParams.set('search_type', 'keyword_unordered');

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    const res = await fetch(url, { headers: { 'x-api-key': key }, signal: controller.signal });
    clearTimeout(timeout);
    if (!res.ok) return [];

    const data = await res.json();
    return Array.isArray(data.searchResults) ? data.searchResults : [];
  } catch {
    return [];
  }
}

async function discoverCategoryAds(
  key: string,
  alreadyFound: string[], // brand names Claude's research already surfaced this week
): Promise<Array<RadarEntry & {
  meta_ads_active: true; meta_ads_count: number;
  meta_ads_sample_url: string | null; meta_ads_platforms: string[];
}>> {
  const alreadyWords = alreadyFound.map(significantWords);
  const seen = new Set<string>();
  const out: Array<RadarEntry & {
    meta_ads_active: true; meta_ads_count: number;
    meta_ads_sample_url: string | null; meta_ads_platforms: string[];
  }> = [];

  for (const { term, category } of CATEGORY_TERMS) {
    const results = await searchAdLibrary(term, key);
    let addedForTerm = 0;
    for (const r of results) {
      if (addedForTerm >= 4) break; // cap per category so this stays a digest, not a firehose
      const pageName = (r.page_name || '').trim();
      if (!pageName) continue;
      const bodyText = r.snapshot?.body?.text || '';
      if (looksFrench(bodyText)) continue;

      const pageWords = significantWords(pageName);
      const dupeKey = pageWords.join(' ');
      if (!dupeKey || seen.has(dupeKey)) continue;
      // Skip anything that's already one of this week's Claude-found brands
      // — this sweep is for filling gaps, not creating duplicate entries.
      const alreadyCovered = alreadyWords.some(bw =>
        bw.length > 0 && (bw.some(w => pageWords.includes(w)) || pageWords.some(w => bw.includes(w)))
      );
      if (alreadyCovered) continue;
      seen.add(dupeKey);

      out.push({
        brand: pageName.slice(0, 200),
        region: guessRegion(pageName),
        category,
        activity: 'medium',
        channels: ['Meta Ads'],
        summary: bodyText
          ? `Live Meta ad found via category search ("${term}"): "${bodyText.slice(0, 200)}"`
          : `Live Meta ad found via category search ("${term}") — no ad copy available.`,
        sources: r.ad_archive_id
          ? [{ title: 'Meta Ad Library', url: `https://www.facebook.com/ads/library/?id=${r.ad_archive_id}` }]
          : [],
        meta_ads_active: true,
        meta_ads_count: 1,
        meta_ads_sample_url: r.ad_archive_id ? `https://www.facebook.com/ads/library/?id=${r.ad_archive_id}` : null,
        meta_ads_platforms: Array.isArray(r.publisher_platform) ? r.publisher_platform : [],
      });
      addedForTerm++;
    }
  }
  return out;
}

async function runScan(sb: ReturnType<typeof createClient>, triggeredBy: string | null) {
  const key = Deno.env.get('ANTHROPIC_API_KEY');
  if (!key) throw new Error('ANTHROPIC_API_KEY is not configured in Edge Function secrets');

  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'claude-sonnet-5',
      max_tokens: 16000,
      system: SYSTEM_PROMPT,
      messages: [{
        role: 'user',
        content: 'Run this week\'s scan now and report back with the JSON block as instructed.',
      }],
      tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 20 }],
    }),
  });
  const data = await res.json();
  if (data.error) throw new Error(data.error.message ?? 'Claude API error');

  // The response can interleave server_tool_use / web_search_tool_result
  // blocks with text blocks — only the text blocks matter here.
  const text = (Array.isArray(data.content) ? data.content : [])
    .filter((b: { type?: string }) => b.type === 'text')
    .map((b: { text?: string }) => b.text ?? '')
    .join('\n');

  // Debug helper: on any parse failure, save a 'failed' report row with a
  // snippet of what Claude actually returned + why the API call stopped, so
  // failures are inspectable from the DB instead of vanishing into a toast.
  const saveFailure = async (reason: string) => {
    await sb.from('market_radar_reports').insert({
      region: REGION,
      status: 'failed',
      error_msg: `${reason} | stop_reason=${data.stop_reason ?? 'n/a'} | tail=${text.slice(-1500)}`,
    });
  };

  const match = text.match(/```json\s*([\s\S]*?)```/) ?? text.match(/(\[[\s\S]*\])/);
  if (!match) {
    await saveFailure('no readable JSON block found');
    throw new Error('Scan finished but returned no readable results');
  }

  let entries: RadarEntry[];
  try {
    entries = JSON.parse(match[1]);
  } catch {
    await saveFailure('JSON.parse failed');
    throw new Error('Scan finished but the results were not valid JSON');
  }
  if (!Array.isArray(entries)) {
    await saveFailure('parsed value was not an array');
    throw new Error('Scan results were not a list');
  }

  const { data: report, error: reportErr } = await sb
    .from('market_radar_reports')
    .insert({ region: REGION, status: 'complete' })
    .select()
    .single();
  if (reportErr) throw new Error(reportErr.message);

  const cleaned = entries
    .filter(e => e && typeof e.brand === 'string' && e.brand.trim())
    .map(e => ({
      report_id: report.id,
      brand: e.brand.trim().slice(0, 200),
      region: (REGIONS.some(r => r.id === e.region) ? e.region : 'shuswap'),
      category: (e.category || 'other').trim().slice(0, 60),
      activity: (['low', 'medium', 'high'].includes(e.activity) ? e.activity : 'low'),
      channels: Array.isArray(e.channels) ? e.channels.slice(0, 10).map(String) : [],
      summary: String(e.summary || '').slice(0, 1000),
      suggested_action: e.suggested_action ? String(e.suggested_action).slice(0, 500) : null,
      sources: Array.isArray(e.sources) ? e.sources.slice(0, 8) : [],
    }));

  // Verify each Claude-found brand against the real Meta Ad Library, if
  // configured. Best-effort and parallel — a slow/failed lookup just leaves
  // that one entry without the badge, it never blocks the scan from saving.
  const scKey = Deno.env.get('SCRAPECREATORS_API_KEY');
  const verifiedRows = scKey
    ? await Promise.all(cleaned.map(async row => {
        const check = await checkMetaAds(row.brand, scKey);
        return {
          ...row,
          meta_ads_active: check?.active ?? null,
          meta_ads_count: check?.count ?? null,
          meta_ads_sample_url: check?.sampleUrl ?? null,
          meta_ads_platforms: check?.platforms ?? [],
        };
      }))
    : cleaned;

  // Separately, sweep the Ad Library directly for broad alcohol categories —
  // catches brands running live Meta ads that never showed up in Claude's
  // web-search research at all (no news, no public post to find).
  const discoveredRows = scKey
    ? (await discoverCategoryAds(scKey, cleaned.map(r => r.brand))).map(d => ({
        report_id: report.id,
        ...d,
      }))
    : [];

  const rows = [...verifiedRows, ...discoveredRows];
  if (rows.length) {
    const { error: entriesErr } = await sb.from('market_radar_entries').insert(rows);
    if (entriesErr) throw new Error(entriesErr.message);
  }

  void triggeredBy; // reserved for future audit trail — reports aren't per-user today
  return report;
}

// ─── Main handler ─────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { action, ...params } = await req.json() as Record<string, unknown> & { action: string };

    // ── scan ─────────────────────────────────────────────────────────────────
    // Reachable two ways: pg_cron's weekly job (no user session — authorized by
    // the shared x-cron-secret header, same pattern as social-scheduler), or an
    // admin's "Run scan now" button (authorized by their own session).
    if (action === 'scan') {
      const cronSecret = Deno.env.get('CRON_SECRET');
      const provided = req.headers.get('x-cron-secret');
      let triggeredBy: string | null = null;

      if (cronSecret && provided === cronSecret) {
        // automated weekly run
      } else {
        triggeredBy = await requireAdmin(req.headers.get('Authorization'), sb);
      }

      const report = await runScan(sb, triggeredBy);
      return Response.json({ report }, { headers: corsHeaders });
    }

    // Everything past this point is an in-app admin action.
    const adminId = await requireAdmin(req.headers.get('Authorization'), sb);

    // ── list ─────────────────────────────────────────────────────────────────
    if (action === 'list') {
      const limit = Math.min(Math.max(Number(params.limit) || 10, 1), 50);
      const { data: reports, error: reportsErr } = await sb
        .from('market_radar_reports')
        .select('*')
        .order('run_at', { ascending: false })
        .limit(limit);
      if (reportsErr) throw new Error(reportsErr.message);

      const ids = (reports ?? []).map((r: { id: string }) => r.id);
      const { data: entries } = ids.length
        ? await sb.from('market_radar_entries').select('*').in('report_id', ids)
        : { data: [] };

      const byReport: Record<string, unknown[]> = {};
      (entries ?? []).forEach((e: { report_id: string }) => {
        (byReport[e.report_id] ??= []).push(e);
      });

      const withEntries = (reports ?? []).map((r: { id: string }) => ({
        ...r,
        entries: byReport[r.id] ?? [],
      }));
      return Response.json({ reports: withEntries }, { headers: corsHeaders });
    }

    // ── markReviewed ─────────────────────────────────────────────────────────
    if (action === 'markReviewed') {
      const { id, reviewed } = params as { id: string; reviewed?: boolean };
      if (!id) throw new Error('id required');
      const { error } = await sb
        .from('market_radar_reports')
        .update(reviewed === false
          ? { reviewed_at: null, reviewed_by: null }
          : { reviewed_at: new Date().toISOString(), reviewed_by: adminId })
        .eq('id', id);
      if (error) throw new Error(error.message);
      return Response.json({ ok: true }, { headers: corsHeaders });
    }

    throw new Error('Unknown action: ' + action);
  } catch (e) {
    return Response.json(
      { error: e instanceof Error ? e.message : String(e) },
      { status: 400, headers: corsHeaders },
    );
  }
});
