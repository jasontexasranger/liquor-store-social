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

// Meta's top-level message is often just "Invalid parameter", with the part
// that tells you what to fix buried in error_user_msg or error_data. Throwing
// only the message loses exactly the information needed, so everything useful
// gets folded in — plus the endpoint, since a build makes five calls and
// otherwise you cannot tell which one failed.
function graphError(path: string, err: Record<string, unknown>): Error {
  // 190 is the whole OAuth family: expired, revoked, password changed. With a
  // personal token that lapses every couple of months this is the error most
  // likely to turn up one quiet morning, so it says what to do about it.
  if (err.code === 190) {
    return new Error(
      'The Meta token has expired or been revoked. Generate a new long-lived ' +
      'user token and run: supabase secrets set META_USER_TOKEN=... ' +
      `(Meta said: ${err.message ?? 'OAuth error'})`
    );
  }
  const bits: string[] = [];
  const userMsg = (err.error_user_msg as string) || '';
  const title   = (err.error_user_title as string) || '';
  const blame   = (err.error_data as Record<string, unknown>)?.blame_field_specs;

  bits.push(String(err.message ?? 'Graph API error'));
  if (title && !bits[0].includes(title)) bits.push(title);
  if (userMsg) bits.push(userMsg);
  if (Array.isArray(blame) && blame.length) {
    bits.push('Field: ' + blame.flat().join(', '));
  }
  const codes = [err.code, err.error_subcode].filter(Boolean).join('/');
  const detail = bits.filter(Boolean).join(' — ');
  return new Error(`${path}: ${detail}${codes ? ` [${codes}]` : ''}`);
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

// The token used for everything ads-related.
//
// A system user token is the right long-term answer, but it can only touch
// Pages the business portfolio owns. Two of the four Pages belong to the
// stores' own portfolios, so a system user cannot post as them however its
// permissions are set. A personal long-lived user token carries the roles the
// person holds directly, which covers all four.
//
// So META_USER_TOKEN wins when present, and the system user token remains the
// fallback — meaning the day those ownership requests are accepted, deleting
// META_USER_TOKEN is the whole migration. Graph does not care which it is
// given; only the identity behind it differs. The trade is expiry: a user
// token lasts about 60 days.
function getSystemToken(): string {
  const user = Deno.env.get('META_USER_TOKEN');
  if (user) return user;
  const sys = Deno.env.get('META_SYSTEM_USER_TOKEN');
  if (sys) return sys;
  throw new Error(
    'No Meta token configured. Set META_USER_TOKEN (a long-lived personal token) ' +
    'or META_SYSTEM_USER_TOKEN in the Edge Function secrets.'
  );
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
        cards, optimizeOrder, endCard,
        startTime, endTime, genders, budgetType,
      } = params as {
        storeId: string; campName: string; objective: string;
        dailyBudget: number; lat: number; lng: number; radius: number;
        ageMin: number; ageMax: number; placements: string[];
        headline: string; bodyText: string; ctaType: string;
        destUrl: string; imageUrl?: string;
        // Carousel. Two to ten cards, each its own image, headline, description
        // and optional link. Absent or shorter than two means a single image ad.
        cards?: Array<{ imageUrl: string; headline?: string; description?: string; link?: string }>;
        optimizeOrder?: boolean;   // let Meta reorder cards by performance
        endCard?: boolean;         // append the Page profile card at the end
        startTime?: string;        // ISO. Absent means start when unpaused.
        endTime?: string;          // ISO. Absent means run until stopped.
        genders?: number[];        // [1] men, [2] women, empty or absent = all
        budgetType?: string;       // 'daily' | 'lifetime'
      };

      const lifetime = budgetType === 'lifetime';
      if (lifetime && !endTime) {
        throw new Error('A lifetime budget needs an end date — Meta has to know what to spread it over');
      }
      if (startTime && endTime && new Date(endTime) <= new Date(startTime)) {
        throw new Error('The end date has to be after the start date');
      }
      if (endTime && new Date(endTime) <= new Date()) {
        throw new Error('The end date is in the past');
      }

      const carousel = Array.isArray(cards) ? cards.filter(c => c && c.imageUrl) : [];
      if (carousel.length === 1) {
        throw new Error('A carousel needs at least two cards — remove the extra image to run a single-image ad');
      }
      if (carousel.length > 10) {
        throw new Error('Meta allows at most 10 carousel cards');
      }

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
      // OUTCOME_SALES normally optimises for OFFSITE_CONVERSIONS, which needs a
      // pixel and a promoted_object. There isn't one, and asking for it is
      // rejected — so sales campaigns optimise for clicks until a pixel exists.
      const objMeta: Record<string, string> = {
        OUTCOME_AWARENESS: 'REACH',
        OUTCOME_TRAFFIC: 'LINK_CLICKS',
        OUTCOME_SALES: 'LINK_CLICKS',
      };
      const camp = await gPost(`/${adAccountId}/campaigns`, {
        name: campName,
        objective,
        status: 'PAUSED',
        special_ad_categories: [],
        // Meta insists this is stated outright when the budget sits on the ad
        // set rather than the campaign. False keeps each ad set's budget its
        // own; true lets Meta move 20% of it between ad sets. These campaigns
        // have a single ad set, so sharing has nothing to share with.
        is_adset_budget_sharing_enabled: false,
      }, token);
      steps[steps.length - 1] = { label: 'Campaign created', status: 'done', detail: `ID: ${camp.id}` };

      // Ad Set
      addStep('Creating ad set…', 'running');
      // British Columbia's legal drinking age is 19, and Meta requires alcohol
      // ads to be targeted no lower. Clamped here rather than trusted from the
      // browser — this is a compliance floor, not a preference.
      const MIN_AGE = 19;
      const targeting: Record<string, unknown> = {
        geo_locations: {
          custom_locations: [{ latitude: lat, longitude: lng, radius, distance_unit: 'kilometer' }],
        },
        age_min: Math.max(MIN_AGE, ageMin || MIN_AGE),
        age_max: ageMax,
      };
      // Meta reads an absent or empty genders array as everyone, which is what
      // we want — sending [1,2] explicitly is the same thing said louder.
      if (Array.isArray(genders) && genders.length === 1) {
        targeting.genders = genders;
      }
      // Meta's position names don't follow from the platform prefix, so they
      // are mapped explicitly rather than derived by stripping it. Facebook
      // Reels really is "facebook_reels" while Instagram's is plain "reels",
      // and Facebook Stories is "story", not "stories". Guessing gets you
      // "Invalid value reels for the placement field facebook_positions".
      const PLACEMENT_MAP: Record<string, { network: string; position: string }> = {
        facebook_feed:        { network: 'facebook',  position: 'feed' },
        facebook_story:       { network: 'facebook',  position: 'story' },
        facebook_reels:       { network: 'facebook',  position: 'facebook_reels' },
        facebook_marketplace: { network: 'facebook',  position: 'marketplace' },
        facebook_video_feeds: { network: 'facebook',  position: 'video_feeds' },
        facebook_search:      { network: 'facebook',  position: 'search' },
        instagram_stream:     { network: 'instagram', position: 'stream' },
        instagram_stories:    { network: 'instagram', position: 'story' },
        instagram_reels:      { network: 'instagram', position: 'reels' },
        instagram_explore:    { network: 'instagram', position: 'explore' },
        instagram_profile:    { network: 'instagram', position: 'profile_feed' },
      };

      const fbPlacements: string[] = [];
      const igPlacements: string[] = [];
      for (const p of placements) {
        const m = PLACEMENT_MAP[p];
        if (!m) throw new Error(`Unknown placement "${p}"`);
        (m.network === 'facebook' ? fbPlacements : igPlacements).push(m.position);
      }

      // Naming positions without naming the platforms they belong to is
      // rejected, so the platform list is derived from what was chosen.
      const platforms: string[] = [];
      if (fbPlacements.length) platforms.push('facebook');
      if (igPlacements.length) platforms.push('instagram');
      if (platforms.length) targeting.publisher_platforms = platforms;
      if (fbPlacements.length) targeting.facebook_positions = fbPlacements;
      if (igPlacements.length) targeting.instagram_positions = igPlacements;

      // No page_id here: ad sets have no such field, and sending it is what
      // Meta reports as "Invalid parameter". Where a Page needs naming it goes
      // in promoted_object, which only some optimisation goals accept.
      const adSetBody: Record<string, unknown> = {
        name: `${campName} — Ad Set`,
        campaign_id: camp.id,
        billing_event: 'IMPRESSIONS',
        optimization_goal: objMeta[objective] ?? 'REACH',
        // Stated outright rather than left to the ad account's default. Some
        // accounts default to a bid cap, which then demands a bid amount we
        // have no sensible figure for. "Highest volume" spends the budget as
        // efficiently as Meta can without us naming a price per result.
        bid_strategy: 'LOWEST_COST_WITHOUT_CAP',
        targeting,
        status: 'PAUSED',
      };
      if (lifetime) {
        adSetBody.lifetime_budget = Math.round(dailyBudget * 100);
      } else {
        adSetBody.daily_budget = Math.round(dailyBudget * 100);
      }
      if (startTime) adSetBody.start_time = startTime;
      if (endTime)   adSetBody.end_time   = endTime;
      if ((objMeta[objective] ?? 'REACH') === 'LINK_CLICKS') {
        adSetBody.destination_type = 'WEBSITE';
      }
      const adSet = await gPost(`/${adAccountId}/adsets`, adSetBody, token);
      steps[steps.length - 1] = { label: 'Ad set created', status: 'done', detail: `ID: ${adSet.id}` };

      // Meta needs the bytes in its own image library; a URL isn't enough.
      //
      // /adimages does not accept a JSON body keyed by filename — that shape is
      // for multipart uploads, and posting it as JSON is what Meta reports as
      // "The provided image file is invalid". Base64 goes in a form field
      // called `bytes`, which is the documented way to upload without
      // assembling a multipart body by hand.
      const uploadImage = async (url: string, i: number): Promise<string | null> => {
        const imgRes = await fetch(url);
        if (!imgRes.ok) throw new Error(`Could not fetch ad image ${i + 1} (${imgRes.status})`);
        const imgBlob = await imgRes.blob();
        const bytes = new Uint8Array(await imgBlob.arrayBuffer());
        if (!bytes.length) throw new Error(`Ad image ${i + 1} was empty`);

        // Chunked: reduce() over a multi-megabyte array builds the string one
        // character at a time and apply() on the whole thing blows the stack.
        let bin = '';
        for (let j = 0; j < bytes.length; j += 8192) {
          bin += String.fromCharCode.apply(null, Array.from(bytes.subarray(j, j + 8192)));
        }

        const form = new FormData();
        form.append('bytes', btoa(bin));
        form.append('access_token', token);

        const up = await fetch(`${GRAPH}/${adAccountId}/adimages`, { method: 'POST', body: form });
        const data = await up.json();
        if (data.error) throw graphError(`/${adAccountId}/adimages`, data.error);

        const images = data.images as Record<string, { hash?: string }> | undefined;
        const hash = images ? Object.values(images)[0]?.hash ?? null : null;
        if (!hash) throw new Error(`Meta accepted ad image ${i + 1} but returned no hash`);
        return hash;
      };

      const linkUrl = destUrl?.trim() || `https://www.facebook.com/${acct.fb_page_id}`;

      let imageHash: string | null = null;
      const cardHashes: Array<string | null> = [];

      if (carousel.length >= 2) {
        addStep(`Uploading ${carousel.length} carousel images…`, 'running');
        for (let i = 0; i < carousel.length; i++) {
          cardHashes.push(await uploadImage(carousel[i].imageUrl, i));
        }
        const ok = cardHashes.filter(Boolean).length;
        if (ok < 2) throw new Error('Fewer than two carousel images uploaded successfully');
        steps[steps.length - 1] = { label: `${ok} carousel images uploaded`, status: 'done', detail: '' };
      } else if (imageUrl) {
        addStep('Uploading image…', 'running');
        imageHash = await uploadImage(imageUrl, 0);
        steps[steps.length - 1] = { label: 'Image uploaded', status: 'done', detail: imageHash ? `Hash: ${imageHash}` : 'Uploaded' };
      }

      // Creative
      addStep('Creating ad creative…', 'running');
      const linkData: Record<string, unknown> = {
        message: bodyText,
        link: linkUrl,
        call_to_action: { type: ctaType, value: { link: linkUrl } },
      };

      if (carousel.length >= 2) {
        // With child_attachments the top-level name and image_hash are ignored,
        // and setting them anyway makes Meta reject the creative.
        linkData.child_attachments = carousel.map((c, i) => {
          const cardLink = (c.link || '').trim() || linkUrl;
          const att: Record<string, unknown> = {
            link: cardLink,
            image_hash: cardHashes[i],
            call_to_action: { type: ctaType, value: { link: cardLink } },
          };
          if (c.headline?.trim())    att.name = c.headline.trim();
          if (c.description?.trim()) att.description = c.description.trim();
          return att;
        }).filter(a => a.image_hash);

        // Meta reorders cards by performance unless told the sequence matters —
        // it does for a "1, 2, 3" story, so this is opt-in.
        linkData.multi_share_optimized = !!optimizeOrder;
        linkData.multi_share_end_card  = !!endCard;
      } else {
        linkData.name = headline;
        if (imageHash) linkData.image_hash = imageHash;
      }

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

      addStep('Campaign created — everything is PAUSED', 'done', 'Review it, then switch it on in Ads Manager.');

      // Ads Manager wants the bare numeric account id; meta_accounts stores it
      // with the act_ prefix the Graph paths need.
      const bareAccount = String(adAccountId).replace(/^act_/, '');
      const managerUrl =
        `https://adsmanager.facebook.com/adsmanager/manage/campaigns` +
        `?act=${bareAccount}&selected_campaign_ids=${camp.id}`;

      return Response.json({
        steps,
        campaignId: camp.id,
        adSetId: adSet.id,
        adId: ad.id,
        adAccountId: bareAccount,
        managerUrl,
      }, { headers: corsHeaders });
    }

    // ── tokenStatus ──────────────────────────────────────────────────────────
    // How long is left, and what the token can do. Worth being able to check
    // before a campaign fails rather than after.
    if (action === 'tokenStatus') {
      const token = getSystemToken();
      const data = await gGet('/debug_token', { input_token: token }, token);
      const d = (data.data ?? {}) as Record<string, unknown>;
      const expiresAt = Number(d.expires_at ?? 0);
      return Response.json({
        type: d.type ?? 'unknown',
        appId: d.app_id ?? null,
        valid: !!d.is_valid,
        scopes: d.scopes ?? [],
        // 0 means it never expires, which is what a system user token reports.
        expiresAt: expiresAt || null,
        daysLeft: expiresAt ? Math.floor((expiresAt * 1000 - Date.now()) / 86400000) : null,
        source: Deno.env.get('META_USER_TOKEN') ? 'user' : 'system_user',
      }, { headers: corsHeaders });
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
