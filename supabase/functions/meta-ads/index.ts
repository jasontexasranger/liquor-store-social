// supabase/functions/meta-ads/index.ts
// Admin-only Meta Ads edge function
// Actions: createCampaign | listCampaigns | toggleCampaign | getInsights
//          analyzeWithAI | generateAdCopy
//
// Required edge function secrets:
//   META_SYSTEM_USER_TOKEN       — Meta Business system-user token
//   ANTHROPIC_API_KEY            — For AI copy generation and analysis
//   SUPABASE_URL                 — auto-set
//   SUPABASE_SERVICE_ROLE_KEY    — auto-set

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GRAPH = 'https://graph.facebook.com/v25.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// ─── Graph helpers ────────────────────────────────────────────────────────────

async function gGet(path: string, params: Record<string, string>, token: string) {
  const qs = new URLSearchParams({ ...params, access_token: token }).toString();
  const res = await fetch(`${GRAPH}${path}?${qs}`);
  const data = await res.json();
  if (data.error) throw new Error(data.error.message ?? 'Graph API error');
  return data;
}

async function gPost(path: string, body: Record<string, unknown>, token: string) {
  const res = await fetch(`${GRAPH}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...body, access_token: token }),
  });
  const data = await res.json();
  if (data.error) throw new Error(data.error.message ?? 'Graph API error');
  return data;
}

// Get user token via system-user token exchange
function getSystemToken(): string {
  const t = Deno.env.get('META_SYSTEM_USER_TOKEN');
  if (!t) throw new Error('META_SYSTEM_USER_TOKEN not configured');
  return t;
}

// ─── Auth: admin only ─────────────────────────────────────────────────────────

async function requireAdmin(authHeader: string | null, sb: ReturnType<typeof createClient>): Promise<string> {
  if (!authHeader) throw new Error('Missing Authorization header');
  const token = authHeader.replace('Bearer ', '');
  const { data: { user }, error } = await sb.auth.getUser(token);
  if (error || !user) throw new Error('Invalid session');

  const { data: role } = await sb
    .from('user_roles')
    .select('role')
    .eq('user_id', user.id)
    .single();

  // Also allow hardcoded admin emails as fallback
  const ADMIN_EMAILS = ['jasontexasranger@gmail.com', 'jason@vwdevelopments.com', 'tim@vwdevelopments.com'];
  if (role?.role !== 'admin' && !ADMIN_EMAILS.includes(user.email ?? '')) {
    throw new Error('Admin access required');
  }
  return user.id;
}

// ─── AI helper ───────────────────────────────────────────────────────────────

async function callClaude(prompt: string, maxTokens = 800): Promise<string> {
  const key = Deno.env.get('ANTHROPIC_API_KEY');
  if (!key) throw new Error('ANTHROPIC_API_KEY not configured');
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: maxTokens,
      messages: [{ role: 'user', content: prompt }],
    }),
  });
  const data = await res.json();
  if (data.error) throw new Error(data.error.message ?? 'Claude API error');
  return data.content?.[0]?.text ?? '';
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
    await requireAdmin(req.headers.get('Authorization'), sb);

    // ── createCampaign ───────────────────────────────────────────────────────
    if (action === 'createCampaign') {
      const {
        storeId, campName, objective, dailyBudget,
        lat, lng, radius, ageMin, ageMax, placements,
        headline, bodyText, ctaType, destUrl, imageUrl,
      } = params as {
        storeId: string; campName: string; objective: string;
        dailyBudget: number; lat: number; lng: number; radius: number;
        ageMin: number; ageMax: number; placements: string[];
        headline: string; bodyText: string; ctaType: string;
        destUrl: string; imageUrl?: string;
      };

      const { data: acct } = await sb
        .from('meta_accounts')
        .select('fb_page_id, ad_account_id')
        .eq('store_id', storeId)
        .single();
      if (!acct) throw new Error('Store not found in meta_accounts');

      // No fallback: spending money against a guessed ad account is worse than
      // failing. Each store must be mapped explicitly in meta_accounts.
      const adAccountId = acct.ad_account_id;
      if (!adAccountId) {
        throw new Error(
          `No ad account configured for store "${storeId}". ` +
          'Set meta_accounts.ad_account_id before creating campaigns.'
        );
      }
      const token = getSystemToken();

      const steps: Array<{ label: string; status: string; detail: string }> = [];
      const addStep = (label: string, status: string, detail = '') =>
        steps.push({ label, status, detail });

      // Campaign
      addStep('Creating campaign…', 'running');
      const objMeta: Record<string, string> = {
        OUTCOME_AWARENESS: 'REACH',
        OUTCOME_TRAFFIC: 'LINK_CLICKS',
        OUTCOME_SALES: 'OFFSITE_CONVERSIONS',
      };
      const camp = await gPost(`/${adAccountId}/campaigns`, {
        name: campName,
        objective,
        status: 'PAUSED',
        special_ad_categories: [],
      }, token);
      steps[steps.length - 1] = { label: 'Campaign created', status: 'done', detail: `ID: ${camp.id}` };

      // Ad Set
      addStep('Creating ad set…', 'running');
      const targeting: Record<string, unknown> = {
        geo_locations: {
          custom_locations: [{ latitude: lat, longitude: lng, radius, distance_unit: 'kilometer' }],
        },
        age_min: ageMin,
        age_max: ageMax,
      };
      const fbPlacements = placements.filter((p: string) => p.startsWith('facebook')).map((p: string) => p.replace('facebook_', '')).filter(Boolean);
      const igPlacements = placements.filter((p: string) => p.startsWith('instagram')).map((p: string) => p.replace('instagram_', '')).filter(Boolean);
      if (fbPlacements.length) targeting.facebook_positions = fbPlacements;
      if (igPlacements.length) targeting.instagram_positions = igPlacements;

      const adSet = await gPost(`/${adAccountId}/adsets`, {
        name: `${campName} — Ad Set`,
        campaign_id: camp.id,
        daily_budget: Math.round(dailyBudget * 100),
        billing_event: 'IMPRESSIONS',
        optimization_goal: objMeta[objective] ?? 'REACH',
        targeting,
        status: 'PAUSED',
        page_id: acct.fb_page_id,
      }, token);
      steps[steps.length - 1] = { label: 'Ad set created', status: 'done', detail: `ID: ${adSet.id}` };

      // Optional image upload
      let imageHash: string | null = null;
      if (imageUrl) {
        addStep('Uploading image…', 'running');
        // Fetch image as binary, re-upload to Meta ad images
        const imgRes = await fetch(imageUrl);
        const imgBlob = await imgRes.blob();
        const imgBase64 = btoa(
          new Uint8Array(await imgBlob.arrayBuffer()).reduce((d, b) => d + String.fromCharCode(b), '')
        );
        const imgName = `image_${Date.now()}.jpg`;
        const uploadRes = await gPost(`/${adAccountId}/adimages`, { [imgName]: imgBase64 }, token);
        imageHash = uploadRes.images ? Object.values(uploadRes.images)[0]?.hash ?? null : null;
        steps[steps.length - 1] = { label: 'Image uploaded', status: 'done', detail: imageHash ? `Hash: ${imageHash}` : 'Uploaded' };
      }

      // Creative
      addStep('Creating ad creative…', 'running');
      const linkUrl = destUrl?.trim() || `https://www.facebook.com/${acct.fb_page_id}`;
      const linkData: Record<string, unknown> = {
        message: bodyText,
        name: headline,
        link: linkUrl,
        call_to_action: { type: ctaType, value: { link: linkUrl } },
      };
      if (imageHash) linkData.image_hash = imageHash;

      const creative = await gPost(`/${adAccountId}/adcreatives`, {
        name: `${campName} — Creative`,
        object_story_spec: { page_id: acct.fb_page_id, link_data: linkData },
      }, token);
      steps[steps.length - 1] = { label: 'Creative created', status: 'done', detail: `ID: ${creative.id}` };

      // Ad
      addStep('Creating ad…', 'running');
      const ad = await gPost(`/${adAccountId}/ads`, {
        name: `${campName} — Ad`,
        adset_id: adSet.id,
        creative: { creative_id: creative.id },
        status: 'PAUSED',
      }, token);
      steps[steps.length - 1] = { label: 'Ad created', status: 'done', detail: `ID: ${ad.id}` };

      addStep('🎉 Campaign created — all assets PAUSED', 'done', 'Activate in Meta Ads Manager when ready.');
      return Response.json({ steps, campaignId: camp.id }, { headers: corsHeaders });
    }

    // ── listCampaigns ────────────────────────────────────────────────────────
    if (action === 'listCampaigns') {
      // Resolved server-side from the store, so the client can never point the
      // dashboard at an arbitrary ad account.
      const { storeId } = params as { storeId?: string };
      if (!storeId) throw new Error('storeId required');

      const { data: acct } = await sb
        .from('meta_accounts')
        .select('ad_account_id')
        .eq('store_id', storeId)
        .single();
      const accountId = acct?.ad_account_id;
      if (!accountId) {
        throw new Error(`No ad account configured for store "${storeId}".`);
      }
      const token = getSystemToken();
      const data = await gGet(`/${accountId}/campaigns`, {
        fields: 'name,status,objective,daily_budget,insights{spend,impressions,clicks,ctr}',
        limit: '100',
      }, token);
      return Response.json({ campaigns: data.data ?? [] }, { headers: corsHeaders });
    }

    // ── toggleCampaign ───────────────────────────────────────────────────────
    if (action === 'toggleCampaign') {
      const { campaignId, newStatus } = params as { campaignId: string; newStatus: 'ACTIVE' | 'PAUSED' };
      if (!campaignId) throw new Error('campaignId required');
      const token = getSystemToken();
      await gPost(`/${campaignId}`, { status: newStatus }, token);
      return Response.json({ ok: true, status: newStatus }, { headers: corsHeaders });
    }

    // ── getInsights ──────────────────────────────────────────────────────────
    if (action === 'getInsights') {
      const { campaignId, dateRange } = params as { campaignId: string; dateRange?: { since: string; until: string } };
      if (!campaignId) throw new Error('campaignId required');
      const token = getSystemToken();
      const insightParams: Record<string, string> = {
        fields: 'spend,impressions,clicks,ctr,reach,frequency,cost_per_result,actions',
        level: 'campaign',
      };
      if (dateRange) {
        insightParams.time_range = JSON.stringify(dateRange);
      }
      const data = await gGet(`/${campaignId}/insights`, insightParams, token);
      return Response.json({ insights: data.data ?? [] }, { headers: corsHeaders });
    }

    // ── analyzeWithAI ────────────────────────────────────────────────────────
    if (action === 'analyzeWithAI') {
      const { campaignId, campaignName, insights } = params as {
        campaignId: string;
        campaignName: string;
        insights: Record<string, string>[];
      };

      const insightSummary = JSON.stringify(insights, null, 2);
      const prompt = `You are a digital advertising analyst for a liquor store chain in British Columbia, Canada.

Campaign: "${campaignName}" (ID: ${campaignId})
Insights data:
${insightSummary}

Write a concise 3-4 paragraph analysis covering:
1. Performance summary (key metrics, what's working)
2. Concerns or areas needing attention
3. 2-3 specific, actionable recommendations for optimization
4. Budget recommendation (increase, maintain, or reduce — with reasoning)

Keep it practical and specific to a retail liquor store context.`;

      const analysis = await callClaude(prompt, 1000);

      // Store analysis
      await sb.from('ad_analyses').insert({
        campaign_id: campaignId,
        insights: insights,
        ai_analysis: analysis,
      });

      return Response.json({ analysis }, { headers: corsHeaders });
    }

    // ── generateAdCopy ───────────────────────────────────────────────────────
    if (action === 'generateAdCopy') {
      const { storeName, product, category, tone, objective } = params as {
        storeName: string;
        product?: string;
        category?: string;
        tone: string;
        objective: string;
      };

      const objLabel: Record<string, string> = {
        OUTCOME_AWARENESS: 'brand awareness',
        OUTCOME_TRAFFIC: 'website traffic',
        OUTCOME_SALES: 'sales / conversions',
      };

      const prompt = `Write a Meta ad for a liquor store.

Store: ${storeName} (BC, Canada)
${product ? `Product: ${product}` : ''}
${category ? `Category: ${category}` : ''}
Tone: ${tone}
Objective: ${objLabel[objective] ?? objective}

Respond with ONLY these two lines (no intro, no explanation):
HEADLINE: [max 25 chars]
BODY: [max 125 chars — engaging, no price promises, no alcohol health claims]`;

      const copy = await callClaude(prompt, 200);
      return Response.json({ copy }, { headers: corsHeaders });
    }

    throw new Error(`Unknown action: ${action}`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return Response.json({ error: msg }, { status: 400, headers: corsHeaders });
  }
});
