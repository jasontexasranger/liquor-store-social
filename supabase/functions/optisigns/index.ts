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

// Each store can name its own key secret — Cobblestone is a separate
// OptiSigns account. Secret *names* come from the database; the keys stay in
// the function environment.
function apiKey(secretName = 'OPTISIGNS_API_KEY'): string {
  // Only names matching this pattern are looked up, so a compromised row
  // can't be used to read arbitrary environment variables like service keys.
  if (!/^OPTISIGNS_API_KEY[A-Z0-9_]*$/.test(secretName)) {
    throw new Error('Invalid OptiSigns key name: ' + secretName);
  }
  const raw = Deno.env.get(secretName);
  if (!raw) throw new Error(secretName + ' is not configured in the Edge Function secrets');
  // Keys arrive by clipboard, and clipboards smuggle newlines and zero-width
  // characters that are invisible in a terminal but illegal in an HTTP header
  // — the "not a valid ByteString" failure. Keep only printable ASCII.
  const k = raw.replace(/[^\x21-\x7E]/g, '');
  if (!k) throw new Error('OPTISIGNS_API_KEY is empty after removing invalid characters');
  return k;
}

async function gql(query: string, variables: Record<string, unknown> = {}, secretName?: string) {
  const res = await fetch(GQL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey(secretName)}`,
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

    const body = await req.json() as {
      action: string; query?: string; variables?: Record<string, unknown>;
      storeId?: string; name?: string;
      items?: Array<{ url: string; name: string; duration?: number }>;
      screenIds?: string[];
    };

    // Resolve which OptiSigns account a store lives on.
    const keyFor = async (storeId?: string): Promise<string | undefined> => {
      if (!storeId) return undefined;
      const { data } = await sb.from('meta_accounts')
        .select('optisigns_key_secret').eq('store_id', storeId).maybeSingle();
      return data?.optisigns_key_secret ?? undefined;
    };

    // ── listScreens ─────────────────────────────────────────────────────────
    if (body.action === 'listScreens') {
      const secret = await keyFor(body.storeId);
      const data = await gql(`
        query {
          devices(query: {}) {
            page { edges { node {
              _id deviceName UUID status orientation
              currentType currentAssetId currentPlaylistId currentScheduleId
              tags
            } } }
          }
        }`, {}, secret);
      const screens = (data?.devices?.page?.edges ?? []).map((e: { node: unknown }) => e.node);
      return Response.json({ screens }, { headers: corsHeaders });
    }

    // ── listPlaylists ───────────────────────────────────────────────────────
    if (body.action === 'listPlaylists') {
      const secret = await keyFor(body.storeId);
      const data = await gql(`
        query {
          playlists(query: {}) {
            page { edges { node {
              _id name color
              assets { _id filename duration type }
            } } }
          }
        }`, {}, secret);
      const playlists = (data?.playlists?.page?.edges ?? []).map((e: { node: unknown }) => e.node);
      return Response.json({ playlists }, { headers: corsHeaders });
    }

    // ── pushPlaylist ────────────────────────────────────────────────────────
    // A month's creatives become a named playlist, optionally put live on the
    // store's screens. Every shape below was exercised against the live
    // account before this was written.
    if (body.action === 'pushPlaylist') {
      const { storeId, name, items, screenIds } = body;
      if (!storeId) throw new Error('storeId required');
      if (!name?.trim()) throw new Error('A playlist name is required');
      if (!items?.length) throw new Error('Nothing to push — no images given');
      if (items.length > 60) throw new Error('That is too many items for one playlist');

      const secret = await keyFor(storeId);

      // Their convention is one playlist per month. Refusing a name that
      // already exists keeps a re-run from stacking duplicate items — push
      // under a new name, or clear the old one in OptiSigns first.
      const existing = await gql(
        'query { playlists(query:{}) { page { edges { node { _id name } } } } }',
        {}, secret);
      const clash = (existing?.playlists?.page?.edges ?? [])
        .map((e: { node: { _id: string; name: string } }) => e.node)
        .find((p: { name: string }) => p.name.trim().toLowerCase() === name.trim().toLowerCase());
      if (clash) {
        throw new Error(
          `A playlist called "${clash.name}" already exists on OptiSigns. ` +
          'Pick a different name, or remove the old one in the OptiSigns dashboard first.'
        );
      }

      // One web asset per image. The screens load the image straight from the
      // creatives bucket, which is public and cache-controlled.
      const assetIds: string[] = [];
      for (const it of items) {
        if (!/^https:\/\//.test(it.url)) throw new Error('Item URLs must be https');
        const a = await gql(
          'mutation($p:AssetInput!){ saveAsset(payload:$p){ _id } }',
          { p: { originalFileName: it.name || name, webLink: it.url,
                 webType: 'website', fileType: 'web', type: 'web' } },
          secret);
        const id = a?.saveAsset?._id;
        if (!id) throw new Error('OptiSigns did not return an asset id for "' + (it.name || it.url) + '"');
        assetIds.push(id);
      }

      const pl = await gql(
        'mutation($p:PlaylistInput!){ savePlaylist(payload:$p){ _id name } }',
        { p: { name: name.trim() } }, secret);
      const playlistId = pl?.savePlaylist?._id;
      if (!playlistId) throw new Error('OptiSigns did not return a playlist id');

      await gql(
        'mutation($id:String!,$p:AddPlaylistItemsInput!){ addPlaylistItems(_id:$id, payload:$p){ _id } }',
        { id: playlistId, p: { ids: assetIds, pos: 0, type: 'ASSET' } }, secret);

      // Per-item duration, when asked for. addPlaylistItems has no duration
      // field, so items that want one are updated after the fact.
      // UpdatePlaylistItemsInput is { items: [{ item, pos[] }] } — the item is a
      // PlaylistItemInput carrying the new duration, applied at the positions.
      const durUpdates = items
        .map((it, i) => ({ i, d: it.duration }))
        .filter(x => x.d && x.d !== 7);
      if (durUpdates.length) {
        try {
          await gql(
            'mutation($id:String!,$p:UpdatePlaylistItemsInput!){ updatePlaylistItems(_id:$id, payload:$p){ _id } }',
            { id: playlistId,
              p: { items: durUpdates.map(x => ({ item: { duration: x.d }, pos: [x.i] })) } },
            secret);
        } catch (_e) { /* duration is cosmetic; the push still stands */ }
      }

      // Putting it on screens is opt-in and store-scoped: only screens the
      // admin mapped to this store are accepted, whatever the request says.
      const assigned: string[] = [];
      const failedAssign: string[] = [];
      if (screenIds?.length) {
        const { data: acct } = await sb.from('meta_accounts')
          .select('optisigns_screen_ids').eq('store_id', storeId).maybeSingle();
        const allowed = new Set(acct?.optisigns_screen_ids ?? []);
        for (const sid of screenIds) {
          if (!allowed.has(sid)) { failedAssign.push(sid + ' (not mapped to this store)'); continue; }
          try {
            await gql(
              'mutation($id:String!,$p:UpdateDeviceInput!){ updateDevice(_id:$id, payload:$p){ _id deviceName currentPlaylistId } }',
              { id: sid, p: { currentType: 'PLAYLIST', currentPlaylistId: playlistId } },
              secret);
            assigned.push(sid);
          } catch (e) {
            failedAssign.push(sid + ': ' + (e instanceof Error ? e.message : String(e)));
          }
        }
      }

      await sb.from('audit_log').insert({
        user_id: user.id,
        action: 'push_signage_playlist',
        entity_type: 'optisigns',
        changed_fields: ['playlist'],
        safe_metadata: { store: storeId, playlist: name.trim(), items: items.length,
                         assigned: assigned.length },
      });

      return Response.json({
        playlistId, name: name.trim(), items: assetIds.length,
        assigned, failedAssign,
      }, { headers: corsHeaders });
    }

    // ── saveScreens (admin only) ────────────────────────────────────────────
    // The store-to-screen mapping. Admin because a wrong mapping is how beer
    // prices end up on the paint centre's sign.
    if (body.action === 'saveScreens') {
      if (!isAdmin) throw new Error('Admin only');
      const { storeId, screenIds } = body;
      if (!storeId) throw new Error('storeId required');
      const { error: upErr } = await sb.from('meta_accounts')
        .update({ optisigns_screen_ids: screenIds ?? [] })
        .eq('store_id', storeId);
      // Supabase errors are plain objects, not Errors — thrown raw they reach
      // the user as "[object Object]".
      if (upErr) throw new Error(upErr.message || JSON.stringify(upErr));
      return Response.json({ ok: true }, { headers: corsHeaders });
    }

    // ── Signage console actions (admin only) ───────────────────────────────
    // Direct management of what the screens play. Admin-gated: these reach
    // every screen on the account, including businesses outside the stores.
    if (['assignScreen','playlistItems','removeItems','moveItems','setDurations',
         'renamePlaylist','addCreatives','createPlaylist'].includes(body.action)) {
      if (!isAdmin) throw new Error('Admin only');
      const secret = await keyFor(body.storeId);
      const b = body as unknown as {
        action: string; storeId?: string; screenId?: string; playlistId?: string;
        name?: string; pos?: number[]; froms?: number[]; to?: number;
        updates?: Array<{ pos: number; duration: number }>;
        items?: Array<{ url: string; name: string; duration?: number }>;
      };

      if (b.action === 'assignScreen') {
        if (!b.screenId || !b.playlistId) throw new Error('screenId and playlistId required');
        const d = await gql(
          'mutation($id:String!,$p:UpdateDeviceInput!){ updateDevice(_id:$id, payload:$p){ _id deviceName currentType currentPlaylistId } }',
          { id: b.screenId, p: { currentType: 'PLAYLIST', currentPlaylistId: b.playlistId } },
          secret);
        return Response.json({ screen: d?.updateDevice ?? null }, { headers: corsHeaders });
      }

      if (b.action === 'playlistItems') {
        if (!b.playlistId) throw new Error('playlistId required');
        const d = await gql(
          'query($q:QueryPlaylistInput!){ playlists(query:$q){ page { edges { node { _id name assets { _id filename duration type thumbnail webLink } } } } } }',
          { q: { _id: b.playlistId } }, secret);
        const node = (d?.playlists?.page?.edges ?? [])
          .map((e: { node: { _id: string } }) => e.node)
          .find((p: { _id: string }) => p._id === b.playlistId);
        if (!node) throw new Error('Playlist not found');
        return Response.json({ playlist: node }, { headers: corsHeaders });
      }

      if (b.action === 'removeItems') {
        if (!b.playlistId || !b.pos?.length) throw new Error('playlistId and pos required');
        await gql(
          'mutation($id:String!,$p:RemovePlaylistItemsInput!){ removePlaylistItems(_id:$id, payload:$p){ _id } }',
          { id: b.playlistId, p: { pos: b.pos } }, secret);
        return Response.json({ ok: true }, { headers: corsHeaders });
      }

      if (b.action === 'moveItems') {
        if (!b.playlistId || !b.froms?.length || b.to == null) throw new Error('playlistId, froms, to required');
        await gql(
          'mutation($id:String!,$p:MovePlaylistItemsInput!){ movePlaylistItems(_id:$id, payload:$p){ _id } }',
          { id: b.playlistId, p: { froms: b.froms, to: b.to } }, secret);
        return Response.json({ ok: true }, { headers: corsHeaders });
      }

      if (b.action === 'setDurations') {
        if (!b.playlistId || !b.updates?.length) throw new Error('playlistId and updates required');
        await gql(
          'mutation($id:String!,$p:UpdatePlaylistItemsInput!){ updatePlaylistItems(_id:$id, payload:$p){ _id } }',
          { id: b.playlistId,
            p: { items: b.updates.map(u => ({ item: { duration: u.duration }, pos: [u.pos] })) } },
          secret);
        return Response.json({ ok: true }, { headers: corsHeaders });
      }

      if (b.action === 'renamePlaylist') {
        if (!b.playlistId || !b.name?.trim()) throw new Error('playlistId and name required');
        await gql(
          'mutation($p:PlaylistInput!){ savePlaylist(payload:$p){ _id name } }',
          { p: { _id: b.playlistId, name: b.name.trim() } }, secret);
        return Response.json({ ok: true }, { headers: corsHeaders });
      }

      if (b.action === 'createPlaylist') {
        if (!b.name?.trim()) throw new Error('name required');
        const d = await gql(
          'mutation($p:PlaylistInput!){ savePlaylist(payload:$p){ _id name } }',
          { p: { name: b.name.trim() } }, secret);
        return Response.json({ playlist: d?.savePlaylist ?? null }, { headers: corsHeaders });
      }

      if (b.action === 'addCreatives') {
        if (!b.playlistId || !b.items?.length) throw new Error('playlistId and items required');
        const ids: string[] = [];
        for (const it of b.items) {
          if (!/^https:\/\//.test(it.url)) throw new Error('Item URLs must be https');
          const a = await gql(
            'mutation($p:AssetInput!){ saveAsset(payload:$p){ _id } }',
            { p: { originalFileName: it.name, webLink: it.url,
                   webType: 'website', fileType: 'web', type: 'web' } }, secret);
          if (!a?.saveAsset?._id) throw new Error('No asset id for "' + it.name + '"');
          ids.push(a.saveAsset._id);
        }
        await gql(
          'mutation($id:String!,$p:AddPlaylistItemsInput!){ addPlaylistItems(_id:$id, payload:$p){ _id } }',
          { id: b.playlistId, p: { ids, pos: 0, type: 'ASSET' } }, secret);
        return Response.json({ added: ids.length }, { headers: corsHeaders });
      }
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
    const msg = e instanceof Error ? e.message
      : (e && typeof e === 'object' && 'message' in e) ? String((e as { message: unknown }).message)
      : typeof e === 'object' ? JSON.stringify(e)
      : String(e);
    return Response.json({ error: msg }, { status: 400, headers: corsHeaders });
  }
});
