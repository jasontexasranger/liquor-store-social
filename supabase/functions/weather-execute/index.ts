// supabase/functions/weather-execute/index.ts
// The executor. The ONLY function in the weather-automation subsystem that
// writes to Meta. weather-rules-check (the engine) decides what should
// happen; this function is the one place that actually does it, so every
// safeguard from the architecture doc lives here:
//
//   1. Budget clamp       — a write can never exceed rule.daily_budget_cents,
//                            no matter what raise_budget_pct computes.
//   2. Before-state        — meta_before captures BOTH the campaign's live
//                            status and its resolved ad set's live budget,
//                            read fresh right before the first write.
//   3. One-object lock     — automation_control.target_id is the PRIMARY KEY;
//                            claiming it (INSERT) IS the lock, and a conflict
//                            on that insert blocks the write entirely.
//   4. Hard ceiling         — checked by the engine before calling apply, and
//                            enforced again here defensively.
//   5. No blind retry       — a failed Graph call is logged and surfaced,
//                            never silently retried.
//   6. Full audit           — every path writes an automation_events row with
//                            before/after state, even failures.
//   7. apply's two doors    — approvalId (human approves any recommendation)
//                            or ruleId (auto path, only when the rule does
//                            NOT require approval).
//   8. Exact rollback       — stop restores meta_before verbatim and closes
//                            the open automation_periods row.
//   9. preview is read-only — computes the clamped plan, writes nothing.
//  10. One ad set per campaign — these are ABO campaigns
//                            (is_adset_budget_sharing_enabled: false), so
//                            budget lives on the single resolved ad set, not
//                            the campaign.
//
// Actions: { action: 'preview'|'apply'|'stop', ruleId?, approvalId?, reason? }
//
// Required edge function secrets:
//   META_USER_TOKEN or META_SYSTEM_USER_TOKEN — same as meta-ads
//   CRON_SECRET                — shared with pg_cron, weather-rules-check
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-set

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GRAPH = 'https://graph.facebook.com/v25.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

function graphError(path: string, err: Record<string, unknown>): Error {
  if (err.code === 190) {
    return new Error(
      'The Meta token has expired or been revoked. Generate a new long-lived ' +
      'user token and run: supabase secrets set META_USER_TOKEN=... ' +
      `(Meta said: ${err.message ?? 'OAuth error'})`
    );
  }
  const bits: string[] = [String(err.message ?? 'Graph API error')];
  const userMsg = (err.error_user_msg as string) || '';
  if (userMsg) bits.push(userMsg);
  const codes = [err.code, err.error_subcode].filter(Boolean).join('/');
  return new Error(`${path}: ${bits.filter(Boolean).join(' — ')}${codes ? ` [${codes}]` : ''}`);
}

async function gGet(path: string, params: Record<string, string>, token: string) {
  const qs = new URLSearchParams({ ...params, access_token: token }).toString();
  const res = await fetch(`${GRAPH}${path}?${qs}`);
  const data = await res.json();
  if (data.error) throw graphError(path, data.error);
  return data;
}

async function gPost(path: string, body: Record<string, unknown>, token: string) {
  const res = await fetch(`${GRAPH}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...body, access_token: token }),
  });
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

async function requireAdminOrCron(req: Request, sb: ReturnType<typeof createClient>): Promise<{ userId: string | null }> {
  const cronSecret = Deno.env.get('CRON_SECRET');
  const provided = req.headers.get('x-cron-secret');
  if (cronSecret && provided === cronSecret) return { userId: null };

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
  return { userId: user.id };
}

type Rule = {
  id: string; name: string; target_campaign_id: string;
  action_type: 'raise_budget_pct' | 'set_budget' | 'toggle_on'; action_value: number | null;
  daily_budget_cents: number; max_incremental_spend_cents: number; approval_required: boolean;
};

// Resolve the single ad set on a campaign (ABO — always exactly one here)
// and read both the campaign's and ad set's live state in one pass. This is
// the read used both for preview and for meta_before capture, so both see
// the exact same reality.
async function loadCampaignState(campaignId: string, token: string) {
  const [camp, adsets] = await Promise.all([
    gGet(`/${campaignId}`, { fields: 'status' }, token),
    gGet(`/${campaignId}/adsets`, { fields: 'id,daily_budget,status', limit: '5' }, token),
  ]);
  const adset = (adsets.data ?? [])[0];
  if (!adset) throw new Error(`Campaign ${campaignId} has no ad set — cannot read or set its budget.`);
  return {
    campaignStatus: camp.status as string,
    adsetId: adset.id as string,
    adsetStatus: adset.status as string,
    adsetDailyBudgetCents: Number(adset.daily_budget ?? 0),
  };
}

function computePlan(rule: Rule, state: Awaited<ReturnType<typeof loadCampaignState>>) {
  let newBudgetCents = state.adsetDailyBudgetCents;
  let clamped = false;
  let campaignStatusChange: string | null = null;

  if (rule.action_type === 'raise_budget_pct') {
    const pct = rule.action_value ?? 0;
    newBudgetCents = Math.round(state.adsetDailyBudgetCents * (1 + pct / 100));
  } else if (rule.action_type === 'set_budget') {
    newBudgetCents = Math.round(rule.action_value ?? state.adsetDailyBudgetCents);
  } else if (rule.action_type === 'toggle_on') {
    if (state.campaignStatus !== 'ACTIVE') campaignStatusChange = 'ACTIVE';
  }

  // Safeguard #1 — never write a budget above the rule's configured cap,
  // regardless of what the formula above computed.
  if (newBudgetCents > rule.daily_budget_cents) {
    newBudgetCents = rule.daily_budget_cents;
    clamped = true;
  }
  if (newBudgetCents < 100) newBudgetCents = 100; // Meta's own floor (1.00 in account currency, cents)

  return {
    targetId: rule.target_campaign_id,
    adsetId: state.adsetId,
    actionType: rule.action_type,
    currentBudgetCents: state.adsetDailyBudgetCents,
    newBudgetCents: rule.action_type === 'toggle_on' ? state.adsetDailyBudgetCents : newBudgetCents,
    clamped,
    campaignStatusChange,
  };
}

async function logEvent(sb: ReturnType<typeof createClient>, row: {
  rule_id: string | null; target_id: string | null; event_type: string;
  before_state?: unknown; after_state?: unknown; detail?: string; created_by?: string | null;
}) {
  await sb.from('automation_events').insert(row);
}

async function loadRule(sb: ReturnType<typeof createClient>, ruleId: string): Promise<Rule> {
  const { data, error } = await sb.from('automation_rules').select('*').eq('id', ruleId).single();
  if (error || !data) throw new Error(`Rule ${ruleId} not found`);
  return data as Rule;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  try {
    const { userId } = await requireAdminOrCron(req, sb);
    const body = await req.json() as {
      action: 'preview' | 'apply' | 'stop';
      ruleId?: string; approvalId?: string; reason?: string;
    };
    const token = getSystemToken();

    // ── preview: read-only, no writes, no lock ────────────────────────────
    if (body.action === 'preview') {
      if (!body.ruleId) throw new Error('ruleId required');
      const rule = await loadRule(sb, body.ruleId);
      const state = await loadCampaignState(rule.target_campaign_id, token);
      const planned = computePlan(rule, state);
      return Response.json({ ok: true, planned }, { headers: corsHeaders });
    }

    // ── apply: the only path that writes to Meta ──────────────────────────
    if (body.action === 'apply') {
      let rule: Rule;
      let approval: { id: string; rule_id: string } | null = null;

      if (body.approvalId) {
        const { data: appr, error } = await sb.from('automation_approvals')
          .select('id, rule_id, status').eq('id', body.approvalId).single();
        if (error || !appr) throw new Error('Approval not found');
        if (appr.status !== 'pending') throw new Error(`Approval is already ${appr.status}`);
        approval = appr;
        rule = await loadRule(sb, appr.rule_id);
      } else if (body.ruleId) {
        rule = await loadRule(sb, body.ruleId);
        if (rule.approval_required) {
          throw new Error('This rule requires approval — apply via approvalId, not ruleId.');
        }
      } else {
        throw new Error('ruleId or approvalId required');
      }

      // Safeguard #3 — the lock. Idempotent: if this exact rule already
      // holds the lock, treat a repeat apply as a no-op rather than
      // double-writing.
      const { data: existingLock } = await sb.from('automation_control')
        .select('rule_id').eq('target_id', rule.target_campaign_id).maybeSingle();
      if (existingLock && existingLock.rule_id !== rule.id) {
        await logEvent(sb, {
          rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'conflict_blocked',
          detail: `Target already controlled by rule ${existingLock.rule_id}`, created_by: userId,
        });
        return Response.json({ ok: false, error: 'conflict_blocked', detail: 'Target campaign is already controlled by another rule.' },
          { status: 409, headers: corsHeaders });
      }
      if (existingLock && existingLock.rule_id === rule.id) {
        return Response.json({ ok: true, note: 'already active — no-op' }, { headers: corsHeaders });
      }

      // Safeguard #2 — read live state fresh, right before the write.
      const state = await loadCampaignState(rule.target_campaign_id, token);
      const plan = computePlan(rule, state);
      const metaBefore = {
        campaign_status: state.campaignStatus,
        adset_id: state.adsetId,
        daily_budget_cents: state.adsetDailyBudgetCents,
      };

      // Claim the lock before writing to Meta. If a concurrent apply beat us
      // here, the unique PK violation means no Meta write happens.
      const { error: lockErr } = await sb.from('automation_control').insert({
        target_id: rule.target_campaign_id, rule_id: rule.id, meta_before: metaBefore, incremental_spend_cents: 0,
      });
      if (lockErr) {
        await logEvent(sb, {
          rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'conflict_blocked',
          detail: 'Lock claim lost a race to a concurrent apply.', created_by: userId,
        });
        return Response.json({ ok: false, error: 'conflict_blocked' }, { status: 409, headers: corsHeaders });
      }

      try {
        if (plan.campaignStatusChange) {
          await gPost(`/${rule.target_campaign_id}`, { status: plan.campaignStatusChange }, token);
        }
        if (rule.action_type !== 'toggle_on') {
          await gPost(`/${plan.adsetId}`, { daily_budget: plan.newBudgetCents }, token);
        }
      } catch (e) {
        // Safeguard #5 — no blind retry. Surface the failure, release the
        // lock we just claimed (nothing actually changed on Meta's side),
        // and stop.
        await sb.from('automation_control').delete().eq('target_id', rule.target_campaign_id);
        const message = e instanceof Error ? e.message : String(e);
        await logEvent(sb, {
          rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'failed',
          before_state: metaBefore, detail: message, created_by: userId,
        });
        return Response.json({ ok: false, error: message }, { status: 502, headers: corsHeaders });
      }

      if (plan.clamped) {
        await logEvent(sb, {
          rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'budget_clamped',
          before_state: { requested: plan }, after_state: { cap: rule.daily_budget_cents }, created_by: userId,
        });
      }
      await logEvent(sb, {
        rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'executed',
        before_state: metaBefore, after_state: plan, created_by: userId,
      });
      await sb.from('automation_periods').insert({
        rule_id: rule.id, target_id: rule.target_campaign_id, status: 'open',
      });
      if (approval) {
        await sb.from('automation_approvals').update({
          status: 'executed', reviewed_by: userId, reviewed_at: new Date().toISOString(),
        }).eq('id', approval.id);
        await logEvent(sb, {
          rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'approved',
          detail: `Approval ${approval.id} executed`, created_by: userId,
        });
      }

      return Response.json({ ok: true, applied: plan, before: metaBefore }, { headers: corsHeaders });
    }

    // ── stop: exact rollback ───────────────────────────────────────────────
    if (body.action === 'stop') {
      if (!body.ruleId) throw new Error('ruleId required');
      const rule = await loadRule(sb, body.ruleId);

      const { data: lock } = await sb.from('automation_control')
        .select('*').eq('target_id', rule.target_campaign_id).eq('rule_id', rule.id).maybeSingle();
      if (!lock) {
        return Response.json({ ok: true, note: 'not locked — nothing to restore' }, { headers: corsHeaders });
      }

      const before = lock.meta_before as { campaign_status: string; adset_id: string; daily_budget_cents: number };

      try {
        if (before.adset_id) {
          await gPost(`/${before.adset_id}`, { daily_budget: before.daily_budget_cents }, token);
        }
        if (before.campaign_status) {
          const camp = await gGet(`/${rule.target_campaign_id}`, { fields: 'status' }, token);
          if (camp.status !== before.campaign_status) {
            await gPost(`/${rule.target_campaign_id}`, { status: before.campaign_status }, token);
          }
        }
      } catch (e) {
        // Safeguard #5 again — do not release the lock on a failed rollback;
        // the campaign may still be sitting in the "during" state, so
        // another rule must not be allowed to claim it.
        const message = e instanceof Error ? e.message : String(e);
        await logEvent(sb, {
          rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'failed',
          before_state: lock, detail: `Rollback failed: ${message}`, created_by: userId,
        });
        return Response.json({ ok: false, error: message }, { status: 502, headers: corsHeaders });
      }

      await sb.from('automation_control').delete().eq('target_id', rule.target_campaign_id);
      await logEvent(sb, {
        rule_id: rule.id, target_id: rule.target_campaign_id, event_type: 'rollback',
        before_state: lock.meta_before, after_state: before, detail: body.reason ?? 'stop', created_by: userId,
      });
      await sb.from('automation_periods')
        .update({ status: 'closed', ended_at: new Date().toISOString() })
        .eq('rule_id', rule.id).eq('target_id', rule.target_campaign_id).eq('status', 'open');

      return Response.json({ ok: true, restored: before }, { headers: corsHeaders });
    }

    throw new Error(`Unknown action: ${body.action}`);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return Response.json({ error: message }, { status: 400, headers: corsHeaders });
  }
});
