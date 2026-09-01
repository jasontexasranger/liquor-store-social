// supabase/functions/feature-publish/index.ts
// Called by pg_cron once a day. Republishes each store's *current-month*
// monthly-features snapshot to public storage (website/{store}.json) — the
// same file the manual "Push to website" button in the Features page writes.
//
// Why this exists: that button only fires when someone opens the dialog and
// clicks Publish. The snapshot has no month in its path, so it just sits
// there unchanged until republished — which is why a site can still show
// August's features well into September. This job makes the republish
// automatic: any store with a feature_periods row for the current calendar
// month, and at least one eligible (on_website) row with a usable card, gets
// its website JSON refreshed every morning. A store that hasn't built next
// month's features yet is simply skipped that day — nothing to publish, so
// nothing changes — and the manual button in the app still works exactly as
// before for anyone who wants to push mid-day edits immediately rather than
// waiting for the next morning's run.
//
// Required edge function secrets:
//   CRON_SECRET                — shared with pg_cron, same pattern as the
//                                 other scheduled functions in this project
//   SUPABASE_URL                — auto-set
//   SUPABASE_SERVICE_ROLE_KEY   — auto-set

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const STORES: Record<string, string> = {
  hideaway:    'Hideaway Liquor Store',
  downtown:    'Downtown Liquor Store',
  cobblestone: 'Cobblestone Liquor Store',
  brothers:    'Brothers Liquor Store - Sicamous',
};

function monthKey(d: Date): string {
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-01';
}

function periodRange(period: string, periodRow: { starts_on?: string | null; ends_on?: string | null }) {
  const [y, m] = period.split('-').map(Number);
  const start = periodRow.starts_on ? new Date(periodRow.starts_on + 'T00:00:00') : new Date(y, m - 1, 1);
  const end   = periodRow.ends_on   ? new Date(periodRow.ends_on   + 'T23:59:59') : new Date(y, m, 0, 23, 59, 59);
  return { start, end };
}
const rangeLabel = (r: { start: Date; end: Date }) =>
  r.start.toLocaleDateString('en-US', { day: 'numeric', month: 'short' }) + ' – ' +
  r.end.toLocaleDateString('en-US', { day: 'numeric', month: 'short', year: 'numeric' });

// "data:image/png;base64,AAAA..." -> raw bytes, for uploading a database-only
// photo the same way the client's hostPhoto() does.
function dataUrlToBytes(dataUrl: string): { bytes: Uint8Array; contentType: string } {
  const m = /^data:([^;]+);base64,(.*)$/.exec(dataUrl);
  const contentType = m ? m[1] : 'image/png';
  const b64 = m ? m[2] : dataUrl;
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return { bytes, contentType };
}

Deno.serve(async (req) => {
  const secret = Deno.env.get('CRON_SECRET');
  const provided = req.headers.get('x-cron-secret');
  if (!secret || provided !== secret) {
    return new Response('Unauthorized', { status: 401 });
  }

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const period = monthKey(new Date());
  const results: Array<Record<string, unknown>> = [];

  for (const [storeId, storeName] of Object.entries(STORES)) {
    try {
      const { data: periodRow } = await sb.from('feature_periods')
        .select('*').eq('store_id', storeId).eq('period', period).maybeSingle();
      if (!periodRow) { results.push({ storeId, skipped: 'no feature period for this month yet' }); continue; }

      const { data: rows, error: rowsErr } = await sb.from('features')
        .select('*').eq('period_id', periodRow.id).order('position');
      if (rowsErr) throw rowsErr;

      const eligible = (rows ?? []).filter((r: Record<string, unknown>) => r.name && r.on_website !== false);
      if (!eligible.length) { results.push({ storeId, skipped: 'nothing eligible for the website' }); continue; }

      const productIds = eligible.map((r: Record<string, unknown>) => r.product_id).filter(Boolean);
      const { data: products } = productIds.length
        ? await sb.from('brand_images').select('*').in('id', productIds)
        : { data: [] as Record<string, unknown>[] };
      const prodOf = (id: unknown) => (products ?? []).find((p: Record<string, unknown>) => p.id === id) || null;

      const featureIds = eligible.map((r: Record<string, unknown>) => r.id);
      const { data: recipes } = await sb.from('recipes').select('*').in('feature_id', featureIds);
      const recipeFor = (featureId: unknown) => (recipes ?? []).find((x: Record<string, unknown>) => x.feature_id === featureId) || null;

      const { data: brand } = await sb.from('brand_profiles')
        .select('primary_color, secondary_color').eq('store_id', storeId).maybeSingle();

      // Host any database-only photos first, same as the manual push, so the
      // snapshot only ever carries real storage URLs.
      const items = [];
      for (const r of eligible as Record<string, unknown>[]) {
        const prod = prodOf(r.product_id);
        let image: string | null = null;
        let placeholder = true;
        if (prod) {
          if (prod.image_url) {
            image = prod.image_url as string;
            placeholder = false;
          } else if (prod.data) {
            try {
              const { bytes, contentType } = dataUrlToBytes(prod.data as string);
              const path = 'website/products/' + prod.id + '.png';
              const { error: upErr } = await sb.storage.from('creatives')
                .upload(path, bytes, { upsert: true, contentType, cacheControl: '31536000' });
              if (!upErr) {
                image = sb.storage.from('creatives').getPublicUrl(path).data.publicUrl;
                await sb.from('brand_images').update({ image_url: image }).eq('id', prod.id);
                placeholder = false;
              }
            } catch { /* falls back to placeholder card below */ }
          }
        }

        const rec = recipeFor(r.id);
        const withRec = rec && rec.name;

        items.push({
          name: r.name, size: r.size || '',
          reg: r.reg_price != null ? Number(r.reg_price) : null,
          sale: r.sale_price != null ? Number(r.sale_price) : null,
          savings: r.savings != null ? Number(r.savings) : null,
          category: (prod && prod.category) || null,
          image, placeholder: placeholder || undefined,
          recipe: withRec ? {
            name: rec!.name, blurb: rec!.notes || '', glass: rec!.glass || '',
            garnish: rec!.garnish || '',
            ingredients: (rec!.ingredients || []).filter((i: Record<string, unknown>) => i.item),
            method: (rec!.method || []).filter(Boolean),
          } : undefined,
        });
      }

      const runR = periodRange(period, periodRow);
      const snapshot = {
        store: storeId,
        title: storeName.replace(/ Liquor Store.*$/i, '') + ' Monthly Features',
        period, dates: 'Prices run ' + rangeLabel(runR),
        updated_at: new Date().toISOString(),
        footnote: 'Prices exclude tax & deposit — while supplies last.',
        brand: {
          primary: brand?.primary_color || '#1e3a5f',
          secondary: brand?.secondary_color || '#c4a35a',
        },
        items,
      };

      const blob = new Blob([JSON.stringify(snapshot, null, 1)], { type: 'application/json' });
      const { error: pubErr } = await sb.storage.from('creatives')
        .upload('website/' + storeId + '.json', blob, { upsert: true, contentType: 'application/json', cacheControl: '300' });
      if (pubErr) throw pubErr;

      results.push({ storeId, published: items.length });
    } catch (e) {
      results.push({ storeId, error: e instanceof Error ? e.message : String(e) });
    }
  }

  console.log('feature-publish:', JSON.stringify(results));
  return Response.json({ period, results });
});
