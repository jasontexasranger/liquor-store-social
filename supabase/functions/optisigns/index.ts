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
// The API key needs Create+Edit; Playlists additionally needs Delete for the
// admin cleanup of old monthly playlists. Screens, assets and schedules
// remain undeletable from here regardless of key scopes.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GQL = 'https://graphql-gateway.optisigns.com/graphql';

// OptiSigns players render a bare image URL at natural size — a 1080-wide ad
// on a 1080p screen shows zoomed and cropped to its top-left corner. Every
// image is wrapped in this tiny hosted page, which letterboxes it to the
// viewport. The page only accepts images from our own storage.
// Hosted on the app's own Netlify site: storage served the first attempt as
// text/plain and the screens displayed the page's source code. Netlify always
// serves .html as HTML, and the file lives in the repo where it's versioned.
const VIEWER = 'https://lrs.thesuenocompany.com/signage-viewer.html';
const wrapForScreen = (url: string) => VIEWER + '?img=' + encodeURIComponent(url);

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

    const body = await req.json() as {
      action: string; query?: string; variables?: Record<string, unknown>;
      storeId?: string; name?: string;
      items?: Array<{ url: string; name: string; duration?: number }>;
      screenIds?: string[];
      // When present, the push is dated: the playlist goes into the store's
      // schedule and plays only between these days (inclusive, YYYY-MM-DD).
      schedule?: { name: string; startDate: string; endDate: string };
      // Brand tag ('brothers', 'global', …) stamped onto the pushed playlist
      // so it can be filtered here and in the OptiSigns dashboard alike.
      tag?: string;
    };

    // Tags are lowercase slugs; anything else is someone probing.
    const TAG_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;

    // ── Schedule helpers ────────────────────────────────────────────────────
    // OptiSigns stores schedule times as floating local wall-clock with a Z
    // suffix — their own UI writes 09:00Z for a 9am open. Verified against
    // items the account's owners created by hand. A month-long run is one
    // all-day item repeating daily until the end date.
    const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
    const compact = (d: string) => d.replace(/-/g, '');
    const dailyRule = (start: string, end: string) =>
      `DTSTART:${compact(start)}T000000Z\nRRULE:FREQ=DAILY;INTERVAL=1;UNTIL=${compact(end)}T235900Z`;
    // The UNTIL date back out of a stored rrule, as YYYY-MM-DD.
    const ruleUntil = (rrule?: string | null): string | null => {
      const m = /UNTIL=(\d{4})(\d{2})(\d{2})/.exec(rrule ?? '');
      return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
    };
    const todayISO = () => new Date().toISOString().slice(0, 10);

    type SchedItem = {
      _id: string; name?: string; type?: string; playlistId?: string;
      range?: { startDate?: string; endDate?: string };
      repeatObject?: { rrule?: string };
    };

    const findOrCreateSchedule = async (schedName: string, secret?: string): Promise<string> => {
      const d = await gql(
        'query { schedules(query:{}) { page { edges { node { _id name } } } } }', {}, secret);
      const hit = (d?.schedules?.page?.edges ?? [])
        .map((e: { node: { _id: string; name: string } }) => e.node)
        .find((s: { name: string }) => s.name.trim().toLowerCase() === schedName.trim().toLowerCase());
      if (hit) return hit._id;
      // The API key cannot delete schedules (API_SCOPE_OFF, deliberately), so
      // each store gets exactly one, found by name and reused forever.
      const made = await gql(
        'mutation($p:ScheduleInput!){ saveSchedule(payload:$p){ _id } }',
        { p: { name: schedName.trim() } }, secret);
      const id = made?.saveSchedule?._id;
      if (!id) throw new Error('OptiSigns did not return a schedule id');
      return id;
    };

    const scheduleItemsOf = async (scheduleId: string, secret?: string): Promise<SchedItem[]> => {
      const d = await gql(
        'query($q:QueryScheduleItemsInput!){ scheduleItems(query:$q){ page { edges { node { _id name type playlistId range { startDate endDate } repeatObject { rrule } } } } } }',
        { q: { scheduleId } }, secret);
      return (d?.scheduleItems?.page?.edges ?? []).map((e: { node: SchedItem }) => e.node);
    };

    // Resolve which OptiSigns account a store lives on.
    const keyFor = async (storeId?: string): Promise<string | undefined> => {
      if (!storeId) return undefined;
      const { data } = await sb.from('meta_accounts')
        .select('optisigns_key_secret').eq('store_id', storeId).maybeSingle();
      return data?.optisigns_key_secret ?? undefined;
    };

    // ── Per-item run-date sweep ─────────────────────────────────────────────
    // OptiSigns playlist items can't carry dates, so signage_item_dates does,
    // and this enforces them: remove items whose window has closed, re-add
    // items whose window has opened. Runs on Signage page load, right after
    // any date edit, and daily by cron.
    type ItemDateRow = {
      id: string; store_id: string | null; playlist_id: string; asset_id: string;
      filename: string | null; starts_on: string | null; ends_on: string | null; state: string;
    };

    const sweepPlaylist = async (storeId: string | null, playlistId: string, rows: ItemDateRow[]) => {
      const secret = await keyFor(storeId ?? undefined);
      const today = todayISO();
      const d = await gql(
        'query($q:QueryPlaylistInput!){ playlists(query:$q){ page { edges { node { _id assets { _id } } } } } }',
        { q: { _id: playlistId } }, secret);
      const node = (d?.playlists?.page?.edges ?? [])
        .map((e: { node: { _id: string; assets?: Array<{ _id: string }> } }) => e.node)
        .find((p: { _id: string }) => p._id === playlistId);
      if (!node) {
        // Playlist is gone; its date rows go with it.
        await sb.from('signage_item_dates').delete().eq('playlist_id', playlistId);
        return { removed: 0, added: 0 };
      }
      const assets = node.assets ?? [];
      const removePos: number[] = [];
      let added = 0;
      for (const r of rows) {
        const within = (!r.starts_on || r.starts_on <= today) && (!r.ends_on || today <= r.ends_on);
        const idx = assets.findIndex((a: { _id: string }) => a._id === r.asset_id);
        if (within) {
          if (idx >= 0) {
            if (r.state !== 'active') {
              await sb.from('signage_item_dates')
                .update({ state: 'active', updated_at: new Date().toISOString() }).eq('id', r.id);
            }
          } else if (r.state === 'pending') {
            // Its window opened — back into the playlist, at the end.
            await gql(
              'mutation($id:String!,$p:AddPlaylistItemsInput!){ addPlaylistItems(_id:$id, payload:$p){ _id } }',
              { id: playlistId, p: { ids: [r.asset_id], pos: assets.length, type: 'ASSET' } }, secret);
            await sb.from('signage_item_dates')
              .update({ state: 'active', updated_at: new Date().toISOString() }).eq('id', r.id);
            added++;
          } else {
            // Someone took it out by hand — a hand edit wins over the dates.
            await sb.from('signage_item_dates').delete().eq('id', r.id);
          }
        } else {
          if (idx >= 0) removePos.push(idx);
          if (r.ends_on && r.ends_on < today) {
            // Fully over — the row has done its job.
            await sb.from('signage_item_dates').delete().eq('id', r.id);
          } else if (r.state !== 'pending') {
            await sb.from('signage_item_dates')
              .update({ state: 'pending', updated_at: new Date().toISOString() }).eq('id', r.id);
          }
        }
      }
      if (removePos.length) {
        await gql(
          'mutation($id:String!,$p:RemovePlaylistItemsInput!){ removePlaylistItems(_id:$id, payload:$p){ _id } }',
          { id: playlistId, p: { pos: removePos } }, secret);
      }
      return { removed: removePos.length, added };
    };

    const sweepAll = async () => {
      const { data: rows } = await sb.from('signage_item_dates').select('*');
      const groups = new Map<string, ItemDateRow[]>();
      for (const r of (rows ?? []) as ItemDateRow[]) {
        const k = (r.store_id ?? '') + '|' + r.playlist_id;
        if (!groups.has(k)) groups.set(k, []);
        groups.get(k)!.push(r);
      }
      let removed = 0, added = 0;
      for (const [, rs] of groups) {
        try {
          const res = await sweepPlaylist(rs[0].store_id, rs[0].playlist_id, rs);
          removed += res.removed; added += res.added;
        } catch (_e) { /* one broken playlist must not stop the rest */ }
      }
      return { swept: groups.size, removed, added };
    };

    // The daily cron calls with a dedicated low-stakes secret instead of a
    // user session — it can sweep and nothing else. Set CRON_SECRET in the
    // function secrets and use the same value in the cron job's header.
    if (body.action === 'sweepSignage') {
      const cronSecret = Deno.env.get('CRON_SECRET');
      if (cronSecret && req.headers.get('x-cron-secret') === cronSecret) {
        return Response.json(await sweepAll(), { headers: corsHeaders });
      }
      // No valid cron secret — falls through to the signed-in admin path.
    }

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
              _id name color tags
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
          { p: { originalFileName: it.name || name, webLink: wrapForScreen(it.url),
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

      // Brand tag, best-effort: a key without the Tags scope must not sink
      // the push — the playlist matters more than its label.
      let tagged = false;
      if (body.tag && TAG_RE.test(body.tag)) {
        try {
          await gql(
            'mutation($p:UpdateObjectTagsInput!){ updateObjectTags(payload:$p) }',
            { p: { ids: [playlistId], type: 'PLAYLIST', mutation: 'ADD', tags: [body.tag] } },
            secret);
          tagged = true;
        } catch (_e) { /* likely API_SCOPE_OFF — Tags not enabled on this key */ }
      }

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

      // Dated run: the playlist joins the store's schedule instead of going
      // straight to the screens. The schedule is found or created by name,
      // expired entries are swept out, and the new month is added as an
      // all-day daily item between the run dates.
      let scheduleId: string | null = null;
      let bridged: string | null = null;
      const sched = body.schedule;
      if (sched) {
        if (!DATE_RE.test(sched.startDate) || !DATE_RE.test(sched.endDate)) {
          throw new Error('Schedule dates must be YYYY-MM-DD');
        }
        if (sched.endDate < sched.startDate) throw new Error('The end date is before the start date');
        if (!sched.name?.trim()) throw new Error('A schedule name is required');

        scheduleId = await findOrCreateSchedule(sched.name, secret);

        // Sweep entries whose run has fully ended — the schedule stays a
        // short, readable list of what is coming instead of years of history.
        const existing = await scheduleItemsOf(scheduleId, secret);
        const today = todayISO();
        for (const it of existing) {
          const until = ruleUntil(it.repeatObject?.rrule);
          if (until && until < today) {
            try {
              await gql(
                'mutation($p:RemoveScheduleItemInput!){ removeScheduleItem(payload:$p, scope:ALL) }',
                { p: { _id: it._id } }, secret);
            } catch (_e) { /* housekeeping only */ }
          }
        }

        try {
          await gql(
            'mutation($p:AddScheduleItemInput!){ addScheduleItem(force:false, payload:$p){ _id } }',
            { p: { scheduleId, type: 'PLAYLIST', playlistId,
                   range: { startDate: sched.startDate + 'T00:00:00.000Z',
                            endDate: sched.startDate + 'T23:59:00.000Z' },
                   repeatObject: { rrule: dailyRule(sched.startDate, sched.endDate), repeat: 'daily' } } },
            secret);
        } catch (e) {
          const m = e instanceof Error ? e.message : String(e);
          if (/overlap/i.test(m)) {
            throw new Error(
              'Those dates overlap something already on the "' + sched.name + '" schedule. ' +
              'Adjust the run dates, or remove the clashing entry in the OptiSigns dashboard.'
            );
          }
          throw e;
        }
      }

      // Putting it on screens is opt-in and store-scoped: only screens the
      // admin mapped to this store are accepted, whatever the request says.
      // Dated pushes point the screen at the schedule; immediate pushes point
      // it at the playlist, exactly as before.
      const assigned: string[] = [];
      const failedAssign: string[] = [];
      if (screenIds?.length) {
        const { data: acct } = await sb.from('meta_accounts')
          .select('optisigns_screen_ids').eq('store_id', storeId).maybeSingle();
        const allowed = new Set(acct?.optisigns_screen_ids ?? []);

        // A screen moved onto the schedule before the run starts would sit
        // black until the start date. If nothing on the schedule covers today,
        // whatever the first screen is currently playing is added as a bridge
        // that runs until the day before the new dates begin.
        if (sched && scheduleId && sched.startDate > todayISO()) {
          const items = await scheduleItemsOf(scheduleId, secret);
          const today = todayISO();
          const coversToday = items.some(it => {
            const s = (it.range?.startDate ?? '').slice(0, 10);
            const u = ruleUntil(it.repeatObject?.rrule);
            return s && u && s <= today && u >= today;
          });
          if (!coversToday) {
            const firstMapped = screenIds.find(sid => allowed.has(sid));
            if (firstMapped) {
              try {
                const dv = await gql(
                  'query($q:QueryDeviceInput!){ devices(query:$q){ page { edges { node { _id currentType currentPlaylistId } } } } }',
                  { q: { _id: firstMapped } }, secret);
                const node = (dv?.devices?.page?.edges ?? [])
                  .map((e: { node: { _id: string; currentType?: string; currentPlaylistId?: string } }) => e.node)
                  .find((n: { _id: string }) => n._id === firstMapped);
                const curPl = node?.currentType === 'PLAYLIST' ? node?.currentPlaylistId : null;
                if (curPl) {
                  const dayBefore = new Date(sched.startDate + 'T12:00:00Z');
                  dayBefore.setUTCDate(dayBefore.getUTCDate() - 1);
                  const bridgeEnd = dayBefore.toISOString().slice(0, 10);
                  await gql(
                    'mutation($p:AddScheduleItemInput!){ addScheduleItem(force:false, payload:$p){ _id } }',
                    { p: { scheduleId, type: 'PLAYLIST', playlistId: curPl,
                           range: { startDate: today + 'T00:00:00.000Z',
                                    endDate: today + 'T23:59:00.000Z' },
                           repeatObject: { rrule: dailyRule(today, bridgeEnd), repeat: 'daily' } } },
                    secret);
                  bridged = curPl;
                }
              } catch (_e) { /* bridging is best-effort; worst case the screen waits */ }
            }
          }
        }

        for (const sid of screenIds) {
          if (!allowed.has(sid)) { failedAssign.push(sid + ' (not mapped to this store)'); continue; }
          try {
            const p = sched && scheduleId
              ? { currentType: 'SCHEDULE', currentScheduleId: scheduleId }
              : { currentType: 'PLAYLIST', currentPlaylistId: playlistId };
            await gql(
              'mutation($id:String!,$p:UpdateDeviceInput!){ updateDevice(_id:$id, payload:$p){ _id deviceName } }',
              { id: sid, p }, secret);
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
        scheduleId, scheduled: sched ? { name: sched.name, startDate: sched.startDate, endDate: sched.endDate } : null,
        bridged: !!bridged, tagged,
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
         'renamePlaylist','addCreatives','createPlaylist','deletePlaylist',
         'listSchedules','removeScheduleEntry','assignScreenSchedule',
         'setScheduleEntryDates','itemDates','setItemDates','clearItemDates',
         'sweepSignage','setPlaylistTags'].includes(body.action)) {
      if (!isAdmin) throw new Error('Admin only');
      const secret = await keyFor(body.storeId);
      const b = body as unknown as {
        action: string; storeId?: string; screenId?: string; playlistId?: string;
        name?: string; pos?: number[]; froms?: number[]; to?: number;
        updates?: Array<{ pos: number; duration: number }>;
        items?: Array<{ url: string; name: string; duration?: number }>;
        scheduleId?: string; itemId?: string;
        startDate?: string; endDate?: string;
        assetId?: string; filename?: string;
        startsOn?: string | null; endsOn?: string | null;
        tags?: string[];
      };

      // ── setPlaylistTags: replace a playlist's tags ('brothers', 'global',
      // …). Empty array clears them. SET/CLEAR verified live; requires the
      // Tags scope on the account's API key.
      if (b.action === 'setPlaylistTags') {
        if (!b.playlistId) throw new Error('playlistId required');
        const tags = (b.tags ?? []).filter(t => TAG_RE.test(t));
        try {
          await gql(
            'mutation($p:UpdateObjectTagsInput!){ updateObjectTags(payload:$p) }',
            { p: tags.length
                ? { ids: [b.playlistId], type: 'PLAYLIST', mutation: 'SET', tags }
                : { ids: [b.playlistId], type: 'PLAYLIST', mutation: 'CLEAR', tags: [] } },
            secret);
        } catch (e) {
          const m = e instanceof Error ? e.message : String(e);
          throw new Error(/API_SCOPE_OFF/.test(m)
            ? 'This account\'s API key does not have the Tags permission yet — enable Tags on the key in OptiSigns (Settings → API Keys), then try again.'
            : m);
        }
        return Response.json({ ok: true, tags }, { headers: corsHeaders });
      }

      // ── itemDates: the run-date rows for one playlist.
      if (b.action === 'itemDates') {
        if (!b.playlistId) throw new Error('playlistId required');
        const { data } = await sb.from('signage_item_dates')
          .select('*').eq('playlist_id', b.playlistId);
        return Response.json({ dates: data ?? [] }, { headers: corsHeaders });
      }

      // ── setItemDates: give one playlist item a run window, then apply it
      // immediately — outside its window it comes off the live playlist on
      // the spot, not at the next daily sweep.
      if (b.action === 'setItemDates') {
        if (!b.playlistId || !b.assetId) throw new Error('playlistId and assetId required');
        const so = b.startsOn || null, eo = b.endsOn || null;
        if (!so && !eo) throw new Error('Set a start date, an end date, or both');
        if ((so && !DATE_RE.test(so)) || (eo && !DATE_RE.test(eo))) {
          throw new Error('Dates must be YYYY-MM-DD');
        }
        if (so && eo && eo < so) throw new Error('The end date is before the start date');

        const { data: prev } = await sb.from('signage_item_dates')
          .select('state').eq('playlist_id', b.playlistId).eq('asset_id', b.assetId).maybeSingle();
        const { error: upErr } = await sb.from('signage_item_dates').upsert({
          store_id: b.storeId ?? null,
          playlist_id: b.playlistId,
          asset_id: b.assetId,
          filename: b.filename ?? null,
          starts_on: so, ends_on: eo,
          state: prev?.state ?? 'active',
          updated_at: new Date().toISOString(),
        }, { onConflict: 'playlist_id,asset_id' });
        if (upErr) throw new Error(upErr.message || JSON.stringify(upErr));

        const { data: rows } = await sb.from('signage_item_dates')
          .select('*').eq('playlist_id', b.playlistId);
        const res = await sweepPlaylist(b.storeId ?? null, b.playlistId, (rows ?? []) as ItemDateRow[]);

        await sb.from('audit_log').insert({
          user_id: user.id,
          action: 'set_signage_item_dates',
          entity_type: 'optisigns',
          changed_fields: ['item_dates'],
          safe_metadata: { playlistId: b.playlistId, assetId: b.assetId, startsOn: so, endsOn: eo },
        });
        return Response.json({ ok: true, ...res }, { headers: corsHeaders });
      }

      // ── clearItemDates: back to "always plays". If the sweep had taken the
      // item off the playlist, clearing the dates puts it straight back.
      if (b.action === 'clearItemDates') {
        if (!b.playlistId || !b.assetId) throw new Error('playlistId and assetId required');
        const { data: row } = await sb.from('signage_item_dates')
          .select('*').eq('playlist_id', b.playlistId).eq('asset_id', b.assetId).maybeSingle();
        if (row) {
          if (row.state === 'pending') {
            const secret = await keyFor(b.storeId);
            const d = await gql(
              'query($q:QueryPlaylistInput!){ playlists(query:$q){ page { edges { node { _id assets { _id } } } } } }',
              { q: { _id: b.playlistId } }, secret);
            const node = (d?.playlists?.page?.edges ?? [])
              .map((e: { node: { _id: string; assets?: Array<{ _id: string }> } }) => e.node)
              .find((p: { _id: string }) => p._id === b.playlistId);
            const assets = node?.assets ?? [];
            if (!assets.some((a: { _id: string }) => a._id === b.assetId)) {
              await gql(
                'mutation($id:String!,$p:AddPlaylistItemsInput!){ addPlaylistItems(_id:$id, payload:$p){ _id } }',
                { id: b.playlistId, p: { ids: [b.assetId], pos: assets.length, type: 'ASSET' } }, secret);
            }
          }
          await sb.from('signage_item_dates').delete().eq('id', row.id);
        }
        return Response.json({ ok: true }, { headers: corsHeaders });
      }

      // ── sweepSignage: the same sweep the cron runs, from the console.
      if (b.action === 'sweepSignage') {
        return Response.json(await sweepAll(), { headers: corsHeaders });
      }

      // ── setScheduleEntryDates: change when a playlist runs. updateScheduleItem
      // returned stale data when probed, so the reliable path is remove + add.
      // With no itemId it adds the playlist to the schedule fresh — how an
      // unscheduled playlist gets dates from the console.
      if (b.action === 'setScheduleEntryDates') {
        if (!b.scheduleId || !b.playlistId) throw new Error('scheduleId and playlistId required');
        if (!b.startDate || !DATE_RE.test(b.startDate) || !b.endDate || !DATE_RE.test(b.endDate)) {
          throw new Error('Dates must be YYYY-MM-DD');
        }
        if (b.endDate < b.startDate) throw new Error('The end date is before the start date');

        if (b.itemId) {
          await gql(
            'mutation($p:RemoveScheduleItemInput!){ removeScheduleItem(payload:$p, scope:ALL) }',
            { p: { _id: b.itemId } }, secret);
        }
        try {
          await gql(
            'mutation($p:AddScheduleItemInput!){ addScheduleItem(force:false, payload:$p){ _id } }',
            { p: { scheduleId: b.scheduleId, type: 'PLAYLIST', playlistId: b.playlistId,
                   range: { startDate: b.startDate + 'T00:00:00.000Z',
                            endDate: b.startDate + 'T23:59:00.000Z' },
                   repeatObject: { rrule: dailyRule(b.startDate, b.endDate), repeat: 'daily' } } },
            secret);
        } catch (e) {
          const m = e instanceof Error ? e.message : String(e);
          throw new Error(/overlap/i.test(m)
            ? 'Those dates overlap another run on this schedule — adjust the other entry first.'
              + (b.itemId ? ' The old entry was already removed, so set fresh dates to put it back.' : '')
            : m);
        }
        await sb.from('audit_log').insert({
          user_id: user.id,
          action: 'set_schedule_entry_dates',
          entity_type: 'optisigns',
          changed_fields: ['schedule'],
          safe_metadata: { scheduleId: b.scheduleId, playlistId: b.playlistId,
                           startDate: b.startDate, endDate: b.endDate },
        });
        return Response.json({ ok: true }, { headers: corsHeaders });
      }

      // ── listSchedules: every schedule with its upcoming entries, playlist
      // names resolved so the console can show "SEP 26 · 1 Sep – 30 Sep".
      if (b.action === 'listSchedules') {
        const d = await gql(
          'query { schedules(query:{}) { page { edges { node { _id name } } } } }', {}, secret);
        const scheds = (d?.schedules?.page?.edges ?? [])
          .map((e: { node: { _id: string; name: string } }) => e.node);
        const pls = await gql(
          'query { playlists(query:{}) { page { edges { node { _id name } } } } }', {}, secret);
        const plName = new Map(
          (pls?.playlists?.page?.edges ?? [])
            .map((e: { node: { _id: string; name: string } }) => [e.node._id, e.node.name] as [string, string]));
        const out = [];
        for (const s of scheds) {
          const items = await scheduleItemsOf(s._id, secret);
          out.push({
            _id: s._id, name: s.name,
            items: items.map(it => ({
              _id: it._id,
              playlistId: it.playlistId ?? null,
              playlistName: (it.playlistId && plName.get(it.playlistId)) || it.name || '(unnamed)',
              type: it.type,
              startDate: (it.range?.startDate ?? '').slice(0, 10),
              endDate: ruleUntil(it.repeatObject?.rrule) ?? (it.range?.endDate ?? '').slice(0, 10),
            })),
          });
        }
        return Response.json({ schedules: out }, { headers: corsHeaders });
      }

      // ── removeScheduleEntry: take one dated entry off a schedule.
      if (b.action === 'removeScheduleEntry') {
        if (!b.itemId) throw new Error('itemId required');
        await gql(
          'mutation($p:RemoveScheduleItemInput!){ removeScheduleItem(payload:$p, scope:ALL) }',
          { p: { _id: b.itemId } }, secret);
        await sb.from('audit_log').insert({
          user_id: user.id,
          action: 'remove_schedule_entry',
          entity_type: 'optisigns',
          changed_fields: ['schedule'],
          safe_metadata: { itemId: b.itemId },
        });
        return Response.json({ ok: true }, { headers: corsHeaders });
      }

      // ── assignScreenSchedule: point a screen at a schedule.
      if (b.action === 'assignScreenSchedule') {
        if (!b.screenId || !b.scheduleId) throw new Error('screenId and scheduleId required');
        const d = await gql(
          'mutation($id:String!,$p:UpdateDeviceInput!){ updateDevice(_id:$id, payload:$p){ _id deviceName currentType currentScheduleId } }',
          { id: b.screenId, p: { currentType: 'SCHEDULE', currentScheduleId: b.scheduleId } },
          secret);
        return Response.json({ screen: d?.updateDevice ?? null }, { headers: corsHeaders });
      }

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

      if (b.action === 'deletePlaylist') {
        if (!b.playlistId) throw new Error('playlistId required');

        // Deleting the playlist a screen is playing blanks that screen, so it
        // is refused outright rather than confirmed through — reassign the
        // screen first and then delete.
        const dv = await gql(
          'query { devices(query:{}) { page { edges { node { deviceName currentPlaylistId } } } } }',
          {}, secret);
        const playing = (dv?.devices?.page?.edges ?? [])
          .map((e: { node: { deviceName: string; currentPlaylistId: string | null } }) => e.node)
          .filter((d: { currentPlaylistId: string | null }) => d.currentPlaylistId === b.playlistId)
          .map((d: { deviceName: string }) => d.deviceName);
        if (playing.length) {
          throw new Error(
            'That playlist is live on ' + playing.join(', ') +
            ' — put something else on those screens first, then delete it.'
          );
        }

        await gql(
          'mutation($p:DeleteObjectInput!){ deleteObjects(payload:$p) }',
          { p: { ids: [b.playlistId], type: 'PLAYLIST' } }, secret);

        await sb.from('audit_log').insert({
          user_id: user.id,
          action: 'delete_signage_playlist',
          entity_type: 'optisigns',
          changed_fields: ['playlist'],
          safe_metadata: { playlistId: b.playlistId },
        });
        return Response.json({ ok: true }, { headers: corsHeaders });
      }

      if (b.action === 'addCreatives') {
        if (!b.playlistId || !b.items?.length) throw new Error('playlistId and items required');
        const ids: string[] = [];
        for (const it of b.items) {
          if (!/^https:\/\//.test(it.url)) throw new Error('Item URLs must be https');
          const a = await gql(
            'mutation($p:AssetInput!){ saveAsset(payload:$p){ _id } }',
            { p: { originalFileName: it.name, webLink: wrapForScreen(it.url),
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
