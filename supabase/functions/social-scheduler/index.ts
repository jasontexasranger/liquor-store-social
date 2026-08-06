// supabase/functions/social-scheduler/index.ts
// Called by pg_cron every minute. Claims pending scheduled_posts that are due
// and publishes them to Facebook and/or Instagram.
//
// Required edge function secrets:
//   PT_{PAGE_ID}                 — Permanent page access token per store, e.g.:
//                                  PT_470483222987070   (Hideaway)
//                                  PT_1240518919373546  (Downtown)
//   META_SYSTEM_USER_TOKEN       — Optional fallback system-user token
//   CRON_SECRET                  — Random string shared only with pg_cron SQL
//   SUPABASE_URL                 — auto-set
//   SUPABASE_SERVICE_ROLE_KEY    — auto-set

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GRAPH = 'https://graph.facebook.com/v25.0';
const POST_SUFFIX = '\n\nPrices exclude tax & deposit - while supplies last';

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

async function getPageToken(pageId: string): Promise<string> {
  // 1. Direct per-page token secret (e.g. PT_470483222987070)
  const direct = Deno.env.get('PT_' + pageId);
  if (direct) return direct;

  // 2. Fallback: system-user token exchange
  const sut = Deno.env.get('META_SYSTEM_USER_TOKEN');
  if (!sut) throw new Error('No page token configured for page ' + pageId + '. Add PT_' + pageId + ' secret.');
  const data = await gGet('/' + pageId, { fields: 'access_token' }, sut);
  if (!data.access_token) throw new Error('No page token for ' + pageId);
  return data.access_token;
}

const MAX_IMAGES = 10;

// Rows written before multi-image support only have image_url.
function imagesOf(post: Record<string, unknown>): string[] {
  const arr = Array.isArray(post.image_urls) ? post.image_urls as string[] : [];
  const list = arr.length ? arr : (post.image_url ? [post.image_url as string] : []);
  return list.filter(u => typeof u === 'string' && u.trim()).slice(0, MAX_IMAGES);
}

async function publishFB(pageId: string, token: string, caption: string, images: string[]): Promise<string> {
  const full = caption + POST_SUFFIX;

  if (!images.length) {
    const r = await gPost(`/${pageId}/feed`, { message: full }, token);
    return r.id;
  }
  if (images.length === 1) {
    const r = await gPost(`/${pageId}/photos`, { url: images[0], caption: full }, token);
    return r.post_id ?? r.id;
  }

  // Upload each unpublished, then attach them to a single feed post.
  const mediaIds: string[] = [];
  for (const url of images) {
    const up = await gPost(`/${pageId}/photos`, { url, published: false }, token);
    if (!up.id) throw new Error('Facebook rejected one of the images');
    mediaIds.push(up.id);
  }
  const body: Record<string, unknown> = { message: full };
  mediaIds.forEach((id, i) => { body[`attached_media[${i}]`] = { media_fbid: id }; });
  const r = await gPost(`/${pageId}/feed`, body, token);
  return r.id;
}

async function publishIG(igId: string, token: string, caption: string, images: string[]): Promise<string> {
  const full = caption + POST_SUFFIX;
  if (!images.length) throw new Error('Instagram requires an image');

  if (images.length === 1) {
    const container = await gPost(`/${igId}/media`, { image_url: images[0], caption: full }, token);
    if (!container.id) throw new Error('IG container creation failed');
    const pub = await gPost(`/${igId}/media_publish`, { creation_id: container.id }, token);
    return pub.id;
  }

  const children: string[] = [];
  for (const url of images) {
    const child = await gPost(`/${igId}/media`, { image_url: url, is_carousel_item: true }, token);
    if (!child.id) throw new Error('IG carousel item creation failed');
    children.push(child.id);
  }
  const parent = await gPost(`/${igId}/media`, {
    media_type: 'CAROUSEL', children: children.join(','), caption: full,
  }, token);
  if (!parent.id) throw new Error('IG carousel container creation failed');
  const pub = await gPost(`/${igId}/media_publish`, { creation_id: parent.id }, token);
  return pub.id;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  // Verify CRON_SECRET header — reject anything else
  const secret = Deno.env.get('CRON_SECRET');
  const provided = req.headers.get('x-cron-secret');
  if (!secret || provided !== secret) {
    return new Response('Unauthorized', { status: 401 });
  }

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // Claim all pending posts that are due (scheduled_at <= now)
  const { data: due, error: fetchErr } = await sb
    .from('scheduled_posts')
    .select('*')
    .eq('status', 'pending')
    .lte('scheduled_at', new Date().toISOString())
    .limit(20);

  if (fetchErr) {
    console.error('scheduler fetch error:', fetchErr.message);
    return Response.json({ error: fetchErr.message }, { status: 500 });
  }
  if (!due || due.length === 0) {
    return Response.json({ processed: 0 });
  }

  // Mark all as 'publishing' in one batch to avoid double-processing
  const ids = due.map((r: Record<string, string>) => r.id);
  await sb.from('scheduled_posts').update({ status: 'publishing' }).in('id', ids);

  // Load meta_accounts for all unique storeIds
  const storeIds = [...new Set(due.map((r: Record<string, string>) => r.store_id))] as string[];
  const { data: accounts } = await sb
    .from('meta_accounts')
    .select('store_id, fb_page_id, ig_account_id')
    .in('store_id', storeIds);

  const acctMap = Object.fromEntries(
    (accounts ?? []).map((a: Record<string, string>) => [a.store_id, a])
  );

  // Process each post
  for (const post of due) {
    const acct = acctMap[post.store_id];
    if (!acct) {
      await sb.from('scheduled_posts').update({
        status: 'failed',
        error_msg: 'Store not in meta_accounts',
      }).eq('id', post.id);
      continue;
    }

    let fbPostId: string | null = null;
    let igPostId: string | null = null;
    let errorMsg: string | null = null;

    // Each channel publishes independently — a failure on one must never stop
    // the other from being attempted, nor mask its success.
    const publishTo: string[] = post.publish_to ?? ['facebook'];
    const images = imagesOf(post);
    const errors: string[] = [];
    let pageToken: string | null = null;

    try {
      pageToken = await getPageToken(acct.fb_page_id);
    } catch (e) {
      errorMsg = e instanceof Error ? e.message : String(e);
    }

    if (pageToken) {
      if (publishTo.includes('facebook')) {
        try {
          fbPostId = await publishFB(acct.fb_page_id, pageToken, post.caption, images);
        } catch (e) {
          errors.push('Facebook: ' + (e instanceof Error ? e.message : String(e)));
        }
      }

      if (publishTo.includes('instagram')) {
        try {
          if (!images.length) throw new Error('Instagram requires an image');
          let igId = acct.ig_account_id;
          if (!igId) {
            // Not cached yet — look it up from the linked Facebook Page.
            const info = await gGet(
              `/${acct.fb_page_id}`,
              { fields: 'instagram_business_account' },
              pageToken,
            );
            igId = info.instagram_business_account?.id ?? null;
            if (igId) {
              await sb.from('meta_accounts')
                .update({ ig_account_id: igId })
                .eq('store_id', post.store_id);
            }
          }
          if (!igId) throw new Error('No Instagram Business account linked to this Page');
          igPostId = await publishIG(igId, pageToken, post.caption, images);
        } catch (e) {
          errors.push('Instagram: ' + (e instanceof Error ? e.message : String(e)));
        }
      }
    }

    if (errors.length) errorMsg = [errorMsg, ...errors].filter(Boolean).join(' | ');

    await sb.from('scheduled_posts').update({
      status: errorMsg && !fbPostId && !igPostId ? 'failed' : 'published',
      fb_post_id: fbPostId,
      ig_post_id: igPostId,
      error_msg: errorMsg,
    }).eq('id', post.id);
  }

  console.log(`scheduler: processed ${due.length} post(s)`);
  return Response.json({ processed: due.length });
});
