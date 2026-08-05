// supabase/functions/meta-social/index.ts
// Social publishing edge function — Facebook + Instagram
// Actions: publish | schedule | listPosts | listScheduled | cancelScheduled
//          listComments | replyComment | deletePost | getIgAccountId
//
// Required edge function secrets (Dashboard → Edge Functions → Secrets):
//   PT_{PAGE_ID}            — Permanent page access token per store, e.g.:
//                             PT_470483222987070   (Hideaway Liquor Store)
//                             PT_1240518919373546  (Downtown Liquor Store)
//                             PT_195479573844075   (Cobblestone — when available)
//                             PT_58258641073       (Brothers — when available)
//   META_SYSTEM_USER_TOKEN  — Optional fallback: Meta system-user token
//   SUPABASE_URL            — auto-set by Supabase
//   SUPABASE_SERVICE_ROLE_KEY — auto-set by Supabase

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GRAPH = 'https://graph.facebook.com/v25.0';
const POST_SUFFIX = '\n\nPrices exclude tax & deposit - while supplies last';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// ─── Graph API helpers ────────────────────────────────────────────────────────

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

async function gDelete(path: string, token: string) {
  const res = await fetch(`${GRAPH}${path}?access_token=${token}`, { method: 'DELETE' });
  const data = await res.json();
  if (data.error) throw new Error(data.error.message ?? 'Graph API error');
  return data;
}

// ─── Token helpers ────────────────────────────────────────────────────────────

// Get the page access token for a given page ID.
// Checks PT_{pageId} secret first (preferred: permanent page tokens stored directly).
// Falls back to exchanging META_SYSTEM_USER_TOKEN if available.
async function getPageToken(pageId: string): Promise<string> {
  // 1. Direct per-page token secret (e.g. PT_470483222987070)
  const direct = Deno.env.get('PT_' + pageId);
  if (direct) return direct;

  // 2. Fallback: system-user token exchange
  const sut = Deno.env.get('META_SYSTEM_USER_TOKEN');
  if (!sut) {
    throw new Error(
      'No page token configured for page ' + pageId +
      '. Add secret PT_' + pageId + ' in Supabase Edge Function Secrets.'
    );
  }
  const data = await gGet('/' + pageId, { fields: 'access_token' }, sut);
  if (!data.access_token) throw new Error('Could not retrieve page token for page ' + pageId);
  return data.access_token;
}

// Get the Instagram Business Account ID linked to a Facebook page
async function getIgAccountId(pageId: string, pageToken: string): Promise<string | null> {
  try {
    const data = await gGet(`/${pageId}`, { fields: 'instagram_business_account' }, pageToken);
    return data.instagram_business_account?.id ?? null;
  } catch {
    return null;
  }
}

// ─── Auth helpers ─────────────────────────────────────────────────────────────

interface UserInfo {
  userId: string;
  isAdmin: boolean;
  storeIds: string[]; // empty = all stores (admin)
}

async function getUserInfo(authHeader: string | null, sb: ReturnType<typeof createClient>): Promise<UserInfo> {
  if (!authHeader) throw new Error('Missing Authorization header');
  const token = authHeader.replace('Bearer ', '');
  const { data: { user }, error } = await sb.auth.getUser(token);
  if (error || !user) throw new Error('Invalid or expired session');

  const { data: role } = await sb
    .from('user_roles')
    .select('role, store_ids')
    .eq('user_id', user.id)
    .single();

  const isAdmin = role?.role === 'admin';
  const storeIds: string[] = isAdmin ? [] : (role?.store_ids ?? []);
  return { userId: user.id, isAdmin, storeIds };
}

// ─── Publishing helpers ───────────────────────────────────────────────────────

async function publishToFacebook(
  pageId: string,
  pageToken: string,
  caption: string,
  imageUrl: string | null,
): Promise<string> {
  const fullCaption = caption + POST_SUFFIX;
  if (imageUrl) {
    const r = await gPost(`/${pageId}/photos`, { url: imageUrl, caption: fullCaption }, pageToken);
    return r.post_id ?? r.id;
  } else {
    const r = await gPost(`/${pageId}/feed`, { message: fullCaption }, pageToken);
    return r.id;
  }
}

async function publishToInstagram(
  igAccountId: string,
  pageToken: string,
  caption: string,
  imageUrl: string | null,
): Promise<string> {
  const fullCaption = caption + POST_SUFFIX;
  if (!imageUrl) throw new Error('Instagram requires an image URL');
  // Step 1: create media container
  const container = await gPost(`/${igAccountId}/media`, {
    image_url: imageUrl,
    caption: fullCaption,
  }, pageToken);
  if (!container.id) throw new Error('IG media container creation failed');
  // Step 2: publish
  const pub = await gPost(`/${igAccountId}/media_publish`, {
    creation_id: container.id,
  }, pageToken);
  return pub.id;
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
    const userInfo = await getUserInfo(req.headers.get('Authorization'), sb);

    // ── publish ──────────────────────────────────────────────────────────────
    if (action === 'publish') {
      const { storeIds, caption, imageUrl, publishTo } = params as {
        storeIds: string[];
        caption: string;
        imageUrl: string | null;
        publishTo: string[]; // ['facebook'], ['instagram'], ['facebook','instagram']
      };

      if (!storeIds?.length) throw new Error('storeIds required');
      if (!caption?.trim()) throw new Error('caption required');

      // Verify user has access to requested stores
      if (!userInfo.isAdmin && userInfo.storeIds.length > 0) {
        const unauthorized = storeIds.filter(id => !userInfo.storeIds.includes(id));
        if (unauthorized.length > 0) throw new Error(`Not authorized for stores: ${unauthorized.join(', ')}`);
      }

      // Load meta_accounts for page IDs and IG account IDs
      const { data: accounts } = await sb
        .from('meta_accounts')
        .select('store_id, fb_page_id, ig_account_id')
        .in('store_id', storeIds);

      const results = [];
      for (const storeId of storeIds) {
        const acct = accounts?.find((a: Record<string, string>) => a.store_id === storeId);
        if (!acct) {
          results.push({ storeId, success: false, error: 'Store not found in meta_accounts' });
          continue;
        }

        try {
          const pageToken = await getPageToken(acct.fb_page_id);
          const postTo = publishTo ?? ['facebook'];
          let fbPostId: string | null = null;
          let igPostId: string | null = null;

          if (postTo.includes('facebook')) {
            fbPostId = await publishToFacebook(acct.fb_page_id, pageToken, caption, imageUrl ?? null);
          }

          if (postTo.includes('instagram')) {
            let igId = acct.ig_account_id;
            if (!igId) {
              igId = await getIgAccountId(acct.fb_page_id, pageToken);
              // Cache it for next time
              if (igId) {
                await sb.from('meta_accounts')
                  .update({ ig_account_id: igId })
                  .eq('store_id', storeId);
              }
            }
            if (!igId) {
              results.push({ storeId, fbPostId, success: true, igError: 'No Instagram account linked to this page' });
              continue;
            }
            igPostId = await publishToInstagram(igId, pageToken, caption, imageUrl ?? null);
          }

          results.push({ storeId, success: true, fbPostId, igPostId });
        } catch (e) {
          results.push({ storeId, success: false, error: (e as Error).message });
        }
      }

      return Response.json({ results }, { headers: corsHeaders });
    }

    // ── schedule ─────────────────────────────────────────────────────────────
    if (action === 'schedule') {
      const { storeIds, caption, imageUrl, publishTo, scheduledAt } = params as {
        storeIds: string[];
        caption: string;
        imageUrl: string | null;
        publishTo: string[];
        scheduledAt: string; // ISO timestamp
      };

      if (!storeIds?.length) throw new Error('storeIds required');
      if (!caption?.trim()) throw new Error('caption required');
      if (!scheduledAt) throw new Error('scheduledAt required');
      const ts = new Date(scheduledAt);
      if (ts.getTime() < Date.now() + 10 * 60 * 1000) {
        throw new Error('Scheduled time must be at least 10 minutes in the future');
      }

      if (!userInfo.isAdmin && userInfo.storeIds.length > 0) {
        const unauthorized = storeIds.filter(id => !userInfo.storeIds.includes(id));
        if (unauthorized.length > 0) throw new Error(`Not authorized for stores: ${unauthorized.join(', ')}`);
      }

      const rows = storeIds.map(storeId => ({
        store_id: storeId,
        caption,
        image_url: imageUrl ?? null,
        publish_to: publishTo ?? ['facebook'],
        scheduled_at: scheduledAt,
        status: 'pending',
        created_by: userInfo.userId,
      }));

      const { data, error } = await sb.from('scheduled_posts').insert(rows).select();
      if (error) throw error;
      return Response.json({ scheduled: data }, { headers: corsHeaders });
    }

    // ── listScheduled ────────────────────────────────────────────────────────
    if (action === 'listScheduled') {
      const query = sb
        .from('scheduled_posts')
        .select('*')
        .order('scheduled_at', { ascending: true });

      if (!userInfo.isAdmin) {
        query.eq('created_by', userInfo.userId);
      }

      const { data, error } = await query;
      if (error) throw error;
      return Response.json({ posts: data }, { headers: corsHeaders });
    }

    // ── cancelScheduled ──────────────────────────────────────────────────────
    if (action === 'cancelScheduled') {
      const { id } = params as { id: string };
      if (!id) throw new Error('id required');

      const query = sb.from('scheduled_posts').delete().eq('id', id).eq('status', 'pending');
      if (!userInfo.isAdmin) query.eq('created_by', userInfo.userId);

      const { error } = await query;
      if (error) throw error;
      return Response.json({ ok: true }, { headers: corsHeaders });
    }

    // ── listPosts ────────────────────────────────────────────────────────────
    if (action === 'listPosts') {
      const { storeId } = params as { storeId: string };
      if (!storeId) throw new Error('storeId required');

      if (!userInfo.isAdmin && userInfo.storeIds.length > 0 && !userInfo.storeIds.includes(storeId)) {
        throw new Error('Not authorized for this store');
      }

      const { data: acct } = await sb
        .from('meta_accounts')
        .select('fb_page_id')
        .eq('store_id', storeId)
        .single();
      if (!acct) throw new Error('Store not found in meta_accounts');

      const pageToken = await getPageToken(acct.fb_page_id);
      const data = await gGet(
        `/${acct.fb_page_id}/feed`,
        {
          fields: 'id,message,story,created_time,full_picture,permalink_url,likes.summary(true),comments.summary(true),shares',
          limit: '20',
        },
        pageToken,
      );
      return Response.json({ posts: data.data ?? [] }, { headers: corsHeaders });
    }

    // ── listComments ─────────────────────────────────────────────────────────
    if (action === 'listComments') {
      const { postId, storeId } = params as { postId: string; storeId: string };
      if (!postId || !storeId) throw new Error('postId and storeId required');

      const { data: acct } = await sb
        .from('meta_accounts')
        .select('fb_page_id')
        .eq('store_id', storeId)
        .single();
      if (!acct) throw new Error('Store not found in meta_accounts');

      const pageToken = await getPageToken(acct.fb_page_id);
      const data = await gGet(`/${postId}/comments`, {
        fields: 'id,message,from,created_time,like_count',
        order: 'chronological',
        limit: '50',
      }, pageToken);
      return Response.json({ comments: data.data ?? [] }, { headers: corsHeaders });
    }

    // ── replyComment ─────────────────────────────────────────────────────────
    if (action === 'replyComment') {
      const { commentId, message, storeId } = params as { commentId: string; message: string; storeId: string };
      if (!commentId || !message || !storeId) throw new Error('commentId, message, storeId required');
      if (!userInfo.isAdmin) throw new Error('Admin only');

      const { data: acct } = await sb
        .from('meta_accounts')
        .select('fb_page_id')
        .eq('store_id', storeId)
        .single();
      if (!acct) throw new Error('Store not found in meta_accounts');

      const pageToken = await getPageToken(acct.fb_page_id);
      const result = await gPost(`/${commentId}/comments`, { message }, pageToken);
      return Response.json({ id: result.id }, { headers: corsHeaders });
    }

    // ── deletePost ───────────────────────────────────────────────────────────
    if (action === 'deletePost') {
      const { postId, storeId } = params as { postId: string; storeId: string };
      if (!postId || !storeId) throw new Error('postId and storeId required');
      if (!userInfo.isAdmin) throw new Error('Admin only');

      const { data: acct } = await sb
        .from('meta_accounts')
        .select('fb_page_id')
        .eq('store_id', storeId)
        .single();
      if (!acct) throw new Error('Store not found in meta_accounts');

      const pageToken = await getPageToken(acct.fb_page_id);
      await gDelete(`/${postId}`, pageToken);
      return Response.json({ ok: true }, { headers: corsHeaders });
    }

    // ── getIgAccountId ───────────────────────────────────────────────────────
    if (action === 'getIgAccountId') {
      if (!userInfo.isAdmin) throw new Error('Admin only');
      const { storeId } = params as { storeId: string };

      const { data: acct } = await sb
        .from('meta_accounts')
        .select('fb_page_id, ig_account_id')
        .eq('store_id', storeId)
        .single();
      if (!acct) throw new Error('Store not found in meta_accounts');

      const pageToken = await getPageToken(acct.fb_page_id);
      const igId = await getIgAccountId(acct.fb_page_id, pageToken);

      if (igId && igId !== acct.ig_account_id) {
        await sb.from('meta_accounts').update({ ig_account_id: igId }).eq('store_id', storeId);
      }

      return Response.json({ igAccountId: igId }, { headers: corsHeaders });
    }

    throw new Error(`Unknown action: ${action}`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return Response.json({ error: msg }, { status: 400, headers: corsHeaders });
  }
});
