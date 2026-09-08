// supabase/functions/weather-report/index.ts
// Fills in real results for automation_periods, and feeds real spend back
// into automation_control so the ceiling in weather-execute enforces on
// actual dollars spent, not an estimate.
//
// For every open period (still running) and every period closed within the
// last 48 hours (Meta attribution can land conversions a day or two late,
// so a period's numbers are worth one more pass after it closes), this
// pulls two Graph Insights windows for the period's campaign:
//   - triggered: the period itself (started_at .. ended_at ?? now)
//   - baseline:  an equal-length window immediately before started_at
//
// Known limitation, disclosed rather than glossed over: Meta's standard
// Insights time_range is date-granularity, not hour-granularity. A period
// that starts or ends mid-day gets whichever whole days it touches, which
// means a same-day trigger's "baseline" and "triggered" windows can share a
// day and blend pre- and post-trigger hours together. Hourly breakdowns
// exist on the Graph API but are unreliable this far back and add real
// complexity for a precision gain that matters least on exactly the
// short, same-day windows most likely to occur here. Flagged, not hidden.
//
// purchases/revenue_cents stay NULL — never 0 — when the campaign's
// insights response has no purchase-type entry in `actions` at all, which
// is the normal case for these reach/traffic campaigns without a pixel.
// link_clicks is a genuine 0 when absent, since link-click tracking exists
// on every campaign regardless of pixel setup.
//
// Required edge function secrets:
//   META_USER_TOKEN or META_SYSTEM_USER_TOKEN
//   CRON_SECRET
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-set

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GRAPH = 'https://graph.facebook.com/v25.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

function graphError(path: string, err: Record<string, unknown>): Error {
  const bits: string[] = [String(err.message ?? 'Graph API error')];
  const codes = [err.code, err.error_subcode].filter(Boolean).join('/');
  return new Error(`${path}: ${bits.join(' — ')}${codes ? ` [${codes}]` : ''}`);
}

async function gGet(path: string, params: Record<string, string>, token: string) {
  const qs = new URLSearchParams({ ...params, access_token: token }).toString();
  const res = await fetch(`${GRAPH}${path}?${qs}`);
  const data = await res.json();
  if (data.error) throw graphError(path, data.error);
  return data;
}

function getSystemToken(): string {
  const user = Deno.env.get('META_USER_TOKEN');
  if (user) return user;
  const sys = Deno.env.get('META_SYSTEM_USER_TOKEN');
  if (sys) return sys;
  throw new Error('No Meta token configured. Set META_USER_TOKEN or META_SYSTEM_USER_TOKEN.');
}

async function requireAdminOrCron(req: Request, sb: ReturnType<typeof createClient>): Promise<void> {
  const cronSecret = Deno.env.get('CRON_SECRET');
  const provided = req.headers.get('x-cron-secret');
  if (cronSecret && provided === cronSecret) return;

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) throw new Error('Missing Authorization header');
  const token = authHeader.replace('Bearer ', '');
  const { data: { user }, error } = await sb.auth.getUser(token);
  if (error || !user) throw new Error('Invalid session');
  const { data: role } = await sb.from('user_roles').select('role').eq('user_id', user.id).single();
  const ADMIN_EMAILS = ['jasontexasranger@gmail.com', 'jason@vwdevelopments.com', 'tim@vwdevelopments.com'];
  if (role?.role !== 'admin' && !ADMIN_EMAILS.includes(user.email ?? '')) {
    throw new Error('Admin access required');
  }
}

const PURCHASE_ACTION_TYPES = new Set(['purchase', 'omni_purchase', 'offsite_conversion.fb_pixel_purchase']);

function extractMetrics(insightRow: Record<string, unknown> | undefined) {
  if (!insightRow) return { spendCents: 0, impressions: 0, linkClicks: 0, purchases: null as number | null, revenueCents: null as number | null };

  const spendCents = Math.round(Number(insightRow.spend ?? 0) * 100);
  const impressions = Number(insightRow.impressions ?? 0);

  const actions = (insightRow.actions ?? []) as Array<{ action_type: string; value: string }>;
  const actionValues = (insightRow.action_values ?? []) as Array<{ action_type: string; value: string }>;

  const linkClickEntry = actions.find(a => a.action_type === 'link_click');
  const linkClicks = linkClickEntry ? Math.round(Number(linkClickEntry.value)) : 0;

  const purchaseEntry = actions.find(a => PURCHASE_ACTION_TYPES.has(a.action_type));
  const purchases = purchaseEntry ? Math.round(Number(purchaseEntry.value)) : null;

  const revenueEntry = purchaseEntry ? actionValues.find(a => a.action_type === purchaseEntry.action_type) : undefined;
  const revenueCents = revenueEntry ? Math.round(Number(revenueEntry.value) * 100) : null;

  return { spendCents, impressions, linkClicks, purchases, revenueCents };
}

function ymd(d: Date) {
  return d.toISOString().slice(0, 10);
}

async function fetchWindow(campaignId: string, since: Date, until: Date, token: string) {
  const data = await gGet(`/${campaignId}/insights`, {
    fields: 'spend,impressions,actions,action_values',
    level: 'campaign',
    time_range: JSON.stringify({ since: ymd(since), until: ymd(until) }),
  }, token);
  return extractMetrics((data.data ?? [])[0]);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    await requireAdminOrCron(req, sb);
    const token = getSystemToken();

    const cutoff = new Date(Date.now() - 48 * 3600_000).toISOString();
    const { data: periods, error } = await sb.from('automation_periods')
      .select('*')
      .or(`status.eq.open,ended_at.gte.${cutoff}`);
    if (error) throw error;

    const results = [];
    for (const period of periods ?? []) {
      try {
        const startedAt = new Date(period.started_at);
        const triggeredEnd = period.ended_at ? new Date(period.ended_at) : new Date();
        const durationMs = Math.max(triggeredEnd.getTime() - startedAt.getTime(), 3600_000); // at least 1hr window
        const baselineEnd = new Date(startedAt.getTime() - 1000);
        const baselineStart = new Date(baselineEnd.getTime() - durationMs);

        const [triggered, baseline] = await Promise.all([
          fetchWindow(period.target_id, startedAt, triggeredEnd, token),
          fetchWindow(period.target_id, baselineStart, baselineEnd, token),
        ]);

        await sb.from('automation_periods').update({
          spend_cents: triggered.spendCents,
          impressions: triggered.impressions,
          link_clicks: triggered.linkClicks,
          purchases: triggered.purchases,
          revenue_cents: triggered.revenueCents,
          baseline_spend_cents: baseline.spendCents,
          baseline_impressions: baseline.impressions,
          baseline_link_clicks: baseline.linkClicks,
          baseline_purchases: baseline.purchases,
          baseline_revenue_cents: baseline.revenueCents,
        }).eq('id', period.id);

        // Feed real spend back into the live ceiling check — only while the
        // lock this period belongs to still exists. If it's already been
        // rolled back (lock gone), leave incremental_spend_cents alone;
        // that number is now historical, not a live ceiling input.
        if (period.status === 'open') {
          await sb.from('automation_control')
            .update({ incremental_spend_cents: triggered.spendCents })
            .eq('target_id', period.target_id).eq('rule_id', period.rule_id);
        }

        results.push({ periodId: period.id, targetId: period.target_id, spendCents: triggered.spendCents, ok: true });
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        results.push({ periodId: period.id, targetId: period.target_id, ok: false, error: message });
      }
    }

    return Response.json({ processed: results.length, results }, { headers: corsHeaders });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return Response.json({ error: message }, { status: 400, headers: corsHeaders });
  }
});
