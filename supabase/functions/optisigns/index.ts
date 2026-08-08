// supabase/functions/optisigns/index.ts
// Digital signage via the OptiSigns GraphQL API.
//
// Actions:
//   listScreens   — every screen on the account, with what's playing
//   listPlaylists — every playlist
//   gql           — admin-only raw GraphQL passthrough. Exists so the
//                   integration can be built against the account's real
//                   schema instead of guessed from documentation; the Meta
//                   work showed what guessing costs.
//
// Required secrets: OPTISIGNS_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// The API key's scopes are Create+Edit only — no Delete. Nothing here can
// remove a screen, asset, playlist or schedule, by construction.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GQL = 'https://graphql-gateway.optisigns.com/graphql';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function apiKey(): string {
  const raw = Deno.env.get('OPTISIGNS_API_KEY');
  if (!raw) throw new Error('OPTISIGNS_API_KEY is not configured in the Edge Function secrets');
  // Keys arrive by clipboard, and clipboards smuggle newlines and zero-width
  // characters that are invisible in a terminal but illegal in an HTTP header
  // — the "not a valid ByteString" failure. Keep only printable ASCII.
  const k = raw.replace(/[^\x21-\x7E]/g, '');
  if (!k) throw new Error('OPTISIGNS_API_KEY is empty after removing invalid characters');
  return k;
}

async function gql(query: string, variables: Record<string, unknown> = {}) {
  const res = await fetch(GQL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey()}`,
    },
    body: JSON.stringify({ query, variables }),
  });
  const data = await res.json();
  if (data.errors?.length) {
    throw new Error('OptiSigns: ' + data.errors.map((e: { message: string }) => e.message).join(' | '));
  }
  return data.data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const auth = req.headers.get('Authorization');
    if (!auth) throw new Error('Missing Authorization header');
    const { data: { user }, error } = await sb.auth.getUser(auth.replace('Bearer ', ''));
    if (error || !user) throw new Error('Invalid or expired session');

    const { data: role } = await sb
      .from('user_roles').select('role, sections').eq('user_id', user.id).maybeSingle();
    const ADMIN_EMAILS = [
      'jasontexasranger@gmail.com', 'jason@vwdevelopments.com', 'tim@vwdevelopments.com',
    ];
    const isAdmin = role?.role === 'admin' || ADMIN_EMAILS.includes((user.email ?? '').toLowerCase());

    const body = await req.json() as { action: string; query?: string; variables?: Record<string, unknown> };

    // ── listScreens ─────────────────────────────────────────────────────────
    if (body.action === 'listScreens') {
      const data = await gql(`
        query {
          devices(query: {}) {
            page { edges { node {
              _id deviceName UUID status orientation
              currentType currentAssetId currentPlaylistId currentScheduleId
              tags
            } } }
          }
        }`);
      const screens = (data?.devices?.page?.edges ?? []).map((e: { node: unknown }) => e.node);
      return Response.json({ screens }, { headers: corsHeaders });
    }

    // ── listPlaylists ───────────────────────────────────────────────────────
    if (body.action === 'listPlaylists') {
      const data = await gql(`
        query {
          playlists(query: {}) {
            page { edges { node {
              _id name color
              assets { _id assetId duration }
            } } }
          }
        }`);
      const playlists = (data?.playlists?.page?.edges ?? []).map((e: { node: unknown }) => e.node);
      return Response.json({ playlists }, { headers: corsHeaders });
    }

    // ── gql (admin only) ────────────────────────────────────────────────────
    // Raw passthrough for building and debugging against the live schema.
    // Admin-gated because it can exercise anything the API key allows.
    if (body.action === 'gql') {
      if (!isAdmin) throw new Error('Admin only');
      if (!body.query?.trim()) throw new Error('query required');
      const data = await gql(body.query, body.variables ?? {});
      return Response.json({ data }, { headers: corsHeaders });
    }

    throw new Error(`Unknown action: ${body.action}`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return Response.json({ error: msg }, { status: 400, headers: corsHeaders });
  }
});
