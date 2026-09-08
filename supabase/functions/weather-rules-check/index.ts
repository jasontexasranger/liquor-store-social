// supabase/functions/weather-rules-check/index.ts
// The engine. Loops active automation_rules, pulls a weather snapshot for
// each rule's store, decides what should happen, and — only when this
// invocation was authenticated by pg_cron — asks weather-execute to
// actually touch Meta. This function never calls the Graph API itself;
// weather-execute is the only function with write access, per the
// architecture doc's safeguard list.
//
// canAct = !!cronSecret-matched. A manual "check now" from the admin UI
// (a real admin session, no x-cron-secret) is allowed to evaluate
// conditions and raise approvals for review, but never auto-executes or
// auto-rolls-back a live campaign — those paths downgrade to
// decision='preview_only' so the person can see what *would* happen.
//
// Request body (all optional): { ruleId?: string }
//   - omitted: check every active rule (the cron path)
//   - present: check a single rule (the "check now" UI path)
//
// Required edge function secrets:
//   CRON_SECRET                — shared with pg_cron, weather-provider, weather-execute
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-set

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

type Rule = {
  id: string; name: string; store_id: string;
  target_campaign_id: string; target_campaign_name: string | null;
  weather_condition: string; threshold: number; consecutive_days: number; lead_time_hours: number;
  action_type: string; action_value: number | null;
  daily_budget_cents: number; max_incremental_spend_cents: number;
  active: boolean; approval_required: boolean;
};

async function auth(req: Request, sb: ReturnType<typeof createClient>): Promise<{ canAct: boolean }> {
  const cronSecret = Deno.env.get('CRON_SECRET');
  const provided = req.headers.get('x-cron-secret');
  if (cronSecret && provided === cronSecret) return { canAct: true };

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
  return { canAct: false }; // authenticated admin, but never allowed to auto-act — preview only
}

function fnUrl(name: string) {
  return `${Deno.env.get('SUPABASE_URL')}/functions/v1/${name}`;
}

async function callFn(name: string, body: unknown) {
  const cronSecret = Deno.env.get('CRON_SECRET')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const res = await fetch(fnUrl(name), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-cron-secret': cronSecret,
      'Authorization': `Bearer ${serviceKey}`,
      'apikey': serviceKey,
    },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, json };
}

// ─── Condition evaluation ───────────────────────────────────────────────────
// Open-Meteo's `daily` array is 7 entries, index 0 = today. lead_time_hours
// picks which day a forward-looking condition (forecast_*, precip_prob_above,
// snow_expected) reads from; consecutive_* always reads a run starting today.
function dayIndexForLeadTime(rule: Rule) {
  return Math.min(Math.floor((rule.lead_time_hours || 0) / 24), 6);
}

type DailySnapshot = {
  date: string; tempMaxC: number | null; tempMinC: number | null;
  precipProbMaxPct: number | null; snowfallCm: number | null; weatherCode: number | null;
};
type WeatherSnapshot = {
  current: { tempC: number | null; precipitationMm: number | null; windSpeedKmh: number | null; weatherCode: number | null };
  daily: DailySnapshot[];
  airQuality: unknown; alerts: unknown[]; capabilities: Record<string, boolean>; missing: string[];
};

function evalCondition(rule: Rule, snap: WeatherSnapshot): boolean {
  const daily = snap.daily || [];
  const idx = dayIndexForLeadTime(rule);
  switch (rule.weather_condition) {
    case 'temp_above':
      return snap.current?.tempC != null && snap.current.tempC > rule.threshold;
    case 'temp_below':
      return snap.current?.tempC != null && snap.current.tempC < rule.threshold;
    case 'forecast_high_above': {
      const d = daily[idx];
      return !!d && d.tempMaxC != null && d.tempMaxC > rule.threshold;
    }
    case 'forecast_low_below': {
      const d = daily[idx];
      return !!d && d.tempMinC != null && d.tempMinC < rule.threshold;
    }
    case 'consecutive_above': {
      const window = daily.slice(0, rule.consecutive_days);
      return window.length === rule.consecutive_days && window.every(d => d.tempMaxC != null && d.tempMaxC > rule.threshold);
    }
    case 'consecutive_below': {
      const window = daily.slice(0, rule.consecutive_days);
      return window.length === rule.consecutive_days && window.every(d => d.tempMinC != null && d.tempMinC < rule.threshold);
    }
    case 'precip_prob_above': {
      const d = daily[idx];
      return !!d && d.precipProbMaxPct != null && d.precipProbMaxPct > rule.threshold;
    }
    case 'snow_expected': {
      const d = daily[idx];
      return !!d && d.snowfallCm != null && d.snowfallCm > 0;
    }
    default:
      return false;
  }
}

async function checkOneRule(sb: ReturnType<typeof createClient>, rule: Rule, canAct: boolean) {
  const writeRun = async (conditionMet: boolean, decision: string, detail: string, snapshot: unknown = {}) => {
    const { data, error } = await sb.from('automation_runs').insert({
      rule_id: rule.id, snapshot, condition_met: conditionMet, decision, detail,
    }).select('id').single();
    if (error) console.error('failed to write automation_runs row', error);
    return { ruleId: rule.id, ruleName: rule.name, decision, detail, runId: data?.id ?? null };
  };

  // 1. Resolve location.
  const { data: account } = await sb.from('meta_accounts')
    .select('lat, lng').eq('store_id', rule.store_id).single();
  if (!account || account.lat == null || account.lng == null) {
    return writeRun(false, 'error', `No lat/lng set for store "${rule.store_id}" — set it under the store's Meta account settings.`);
  }

  // 2. Weather snapshot.
  const wx = await callFn('weather-provider', { action: 'weather', latitude: account.lat, longitude: account.lng });
  if (!wx.ok) {
    return writeRun(false, 'error', `weather-provider failed: ${wx.json?.error || wx.status}`);
  }
  const snapshot = wx.json as WeatherSnapshot;
  const conditionMet = evalCondition(rule, snapshot);

  // 3. Existing lock on this target?
  const { data: lock } = await sb.from('automation_control')
    .select('rule_id, incremental_spend_cents').eq('target_id', rule.target_campaign_id).maybeSingle();

  if (lock && lock.rule_id !== rule.id) {
    await sb.from('automation_events').insert({
      rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'conflict_blocked',
      detail: `Campaign already controlled by rule ${lock.rule_id}`, created_by: null,
    });
    return writeRun(conditionMet, 'error', `Target campaign is already controlled by another active rule.`, snapshot);
  }

  const lockedByThisRule = !!lock;

  // 4. Condition holds.
  if (conditionMet) {
    if (lockedByThisRule) {
      // Already active. Enforce the spend ceiling before doing nothing.
      if ((lock!.incremental_spend_cents ?? 0) >= rule.max_incremental_spend_cents) {
        if (canAct) {
          const r = await callFn('weather-execute', { action: 'stop', ruleId: rule.id, reason: 'ceiling' });
          return writeRun(true, r.ok ? 'ceiling_rolled_back' : 'error',
            r.ok ? 'Spend ceiling reached — rolled back.' : `Ceiling rollback failed: ${r.json?.error}`, snapshot);
        }
        return writeRun(true, 'preview_only', 'Spend ceiling reached — would roll back (manual check, no action taken).', snapshot);
      }
      return writeRun(true, 'holding', 'Condition still met; rule already active, under spend ceiling.', snapshot);
    }

    // Fresh trigger — preview the change first so approvals show real numbers.
    const preview = await callFn('weather-execute', { action: 'preview', ruleId: rule.id });
    if (!preview.ok) {
      return writeRun(true, 'error', `Preview failed: ${preview.json?.error || preview.status}`, snapshot);
    }

    if (rule.approval_required) {
      const { data: existing } = await sb.from('automation_approvals')
        .select('id').eq('rule_id', rule.id).eq('status', 'pending').maybeSingle();
      const run = await writeRun(true, 'recommend', 'Condition met — awaiting approval.', snapshot);
      if (existing) {
        await sb.from('automation_approvals').update({
          run_id: run.runId, planned_change: preview.json.planned,
        }).eq('id', existing.id);
      } else {
        await sb.from('automation_approvals').insert({
          rule_id: rule.id, run_id: run.runId, status: 'pending', planned_change: preview.json.planned,
        });
      }
      await sb.from('automation_events').insert({
        rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'recommended',
        after_state: preview.json.planned, detail: 'Weather condition met; queued for approval.', created_by: null,
      });
      return run;
    }

    // Auto path.
    if (canAct) {
      const r = await callFn('weather-execute', { action: 'apply', ruleId: rule.id });
      return writeRun(true, r.ok ? 'auto_executed' : 'error',
        r.ok ? 'Condition met — executed automatically.' : `Auto-execute failed: ${r.json?.error}`, snapshot);
    }
    return writeRun(true, 'preview_only', 'Condition met — would auto-execute (manual check, no action taken).', snapshot);
  }

  // 5. Condition no longer holds.
  if (lockedByThisRule) {
    if (canAct) {
      const r = await callFn('weather-execute', { action: 'stop', ruleId: rule.id, reason: 'condition_cleared' });
      return writeRun(false, r.ok ? 'rolled_back' : 'error',
        r.ok ? 'Condition cleared — rolled back.' : `Rollback failed: ${r.json?.error}`, snapshot);
    }
    return writeRun(false, 'preview_only', 'Condition cleared — would roll back (manual check, no action taken).', snapshot);
  }

  return writeRun(false, 'no_change', 'Condition not met; nothing active.', snapshot);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { canAct } = await auth(req, sb);

    const body = await req.json().catch(() => ({})) as { ruleId?: string };

    let query = sb.from('automation_rules').select('*').eq('active', true);
    if (body.ruleId) query = sb.from('automation_rules').select('*').eq('id', body.ruleId);
    const { data: rules, error } = await query;
    if (error) throw error;

    const results = [];
    for (const rule of (rules ?? []) as Rule[]) {
      try {
        results.push(await checkOneRule(sb, rule, canAct));
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        results.push({ ruleId: rule.id, ruleName: rule.name, decision: 'error', detail: message });
      }
    }

    return Response.json({ checked: results.length, canAct, results }, { headers: corsHeaders });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return Response.json({ error: message }, { status: 400, headers: corsHeaders });
  }
});
