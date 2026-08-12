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
  region: 'shuswap' | 'cowichan';
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
  pages for that specific area
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
      max_tokens: 8000,
      system: SYSTEM_PROMPT,
      messages: [{
        role: 'user',
        content: 'Run this week\'s scan now and report back with the JSON block as instructed.',
      }],
      tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 15 }],
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

  if (entries.length) {
    const rows = entries
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
    if (rows.length) {
      const { error: entriesErr } = await sb.from('market_radar_entries').insert(rows);
      if (entriesErr) throw new Error(entriesErr.message);
    }
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
