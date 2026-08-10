// supabase/functions/bcliquor/index.ts
// BC Liquor Stores product lookup + image import.
//
// Two actions:
//   search    — query the public BCLIQUOR catalogue, return normalized products
//   importUrl — copy an arbitrary image URL into Storage (guarded)
//   import  — revalidate a SKU server-side, copy its image into our Storage
//
// Deliberate constraints, carried over from the Brothers implementation:
//   • BCLIQUOR images are never hotlinked — we always keep our own copy.
//   • Individual product pages are never scraped; only the catalogue endpoint.
//   • The browser's image URL is never trusted; the SKU is re-verified and the
//     canonical URL rebuilt server-side before anything is downloaded.
//
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (both auto-set).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const BROWSE   = 'https://www.bcliquorstores.com/ajax/browse';
const IMG_BASE = 'https://www.bcliquorstores.com/sites/default/files/imagecache/height400px';
const PROD_URL = 'https://www.bcliquorstores.com/product';
const BUCKET   = 'product-media';

const UA_SEARCH = 'Sueno Company product image lookup/1.0';
const UA_IMPORT = 'Sueno Company product image import/1.0';

const MAX_BYTES = 6 * 1024 * 1024;
const OK_TYPES: Record<string,string> = {
  'image/jpeg':'jpg', 'image/jpg':'jpg', 'image/png':'png', 'image/webp':'webp',
};

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface Product {
  sku: string; name: string; package_size: string;
  current_price: number | null; regular_price: number | null;
  category: string; country: string;
  image_url: string; product_url: string;
}

function timeout(ms: number) {
  const c = new AbortController();
  setTimeout(() => c.abort(), ms);
  return c.signal;
}

function normalize(hit: Record<string, unknown>): Product | null {
  const src = (hit?._source ?? {}) as Record<string, unknown>;
  const sku = String(src.sku ?? '').trim();
  if (!sku) return null;

  const unit = String(src.unitSize ?? '').trim();
  const vol  = String(src.volume   ?? '').trim();
  const size = [unit, vol].filter(Boolean).join(' · ');

  const num = (v: unknown) => {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  };

  return {
    sku,
    name: String(src.name ?? '').trim(),
    package_size: size,
    current_price: num(src.currentPrice),
    regular_price: num(src.regularPrice),
    category: String((src.category as Record<string,unknown>)?.description ?? '').trim(),
    country: String(src.countryName ?? '').trim(),
    // Built from the verified SKU, never taken from the response body.
    image_url: `${IMG_BASE}/${encodeURIComponent(sku)}.jpg`,
    product_url: `${PROD_URL}/${encodeURIComponent(sku)}`,
  };
}

async function browse(params: Record<string,string>): Promise<Record<string,unknown>[]> {
  const qs = new URLSearchParams({ sort: '_score:desc', page: '1', ...params });
  const res = await fetch(`${BROWSE}?${qs}`, {
    headers: { 'Accept': 'application/json', 'User-Agent': UA_SEARCH },
    cache: 'no-store',
    signal: timeout(10_000),
  });
  if (!res.ok) throw new Error(`BCLIQUOR search failed (${res.status})`);
  const json = await res.json();
  return (json?.hits?.hits ?? []) as Record<string,unknown>[];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // ── Auth ────────────────────────────────────────────────────────────────
    const auth = req.headers.get('Authorization');
    if (!auth) throw new Error('Missing Authorization header');
    const { data: { user }, error: authErr } =
      await sb.auth.getUser(auth.replace('Bearer ', ''));
    if (authErr || !user) throw new Error('Invalid or expired session');

    const { data: roleRow } = await sb
      .from('user_roles').select('role').eq('user_id', user.id).maybeSingle();
    const role = roleRow?.role ?? null;
    const ADMIN_EMAILS = [
      'jasontexasranger@gmail.com','jason@vwdevelopments.com','tim@vwdevelopments.com',
    ];
    const allowed =
      role === 'admin' || role === 'manager' || role === 'editor' ||
      ADMIN_EMAILS.includes((user.email ?? '').toLowerCase());
    if (!allowed) throw new Error('Not permitted');

    const body = await req.json() as {
      action: string; query?: string; sku?: string;
      storeId?: string; batch?: number;
    };
    const action = body.action;

    const limit = async (name: string, max: number) => {
      const { data: ok } = await sb.rpc('check_rate_limit', {
        p_user: user.id, p_action: name, p_limit: max, p_window_seconds: 300,
      });
      if (ok === false) throw new Error('Too many requests — wait a few minutes and try again');
    };

    // ── search ──────────────────────────────────────────────────────────────
    if (action === 'search') {
      const q = (body.query ?? '').trim();
      if (q.length < 2 || q.length > 80) throw new Error('Search must be 2–80 characters');
      await limit('bcliquor_search', 40);

      const hits = await browse({ search: q, size: '10' });
      const products = hits.map(normalize).filter(Boolean).slice(0, 10);
      return Response.json({ products }, { headers: corsHeaders });
    }

    // ── import ──────────────────────────────────────────────────────────────
    if (action === 'import') {
      const sku = String(body.sku ?? '').trim();
      if (!sku) throw new Error('sku required');
      await limit('bcliquor_import', 20);

      // Revalidate: never trust an image URL supplied by the browser.
      const hits = await browse({ sku, size: '1' });
      const product = hits.map(normalize).find(p => p && p.sku === sku);
      if (!product) throw new Error(`SKU ${sku} not found in the BCLIQUOR catalogue`);

      const imgRes = await fetch(product.image_url, {
        headers: {
          'Accept': 'image/jpeg,image/png,image/webp',
          'User-Agent': UA_IMPORT,
        },
        cache: 'no-store',
        signal: timeout(10_000),
      });
      if (!imgRes.ok) throw new Error(`Could not fetch product image (${imgRes.status})`);

      const contentType = (imgRes.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
      const ext = OK_TYPES[contentType];
      if (!ext) throw new Error(`Unsupported image type: ${contentType || 'unknown'}`);

      const bytes = new Uint8Array(await imgRes.arrayBuffer());
      if (bytes.byteLength > MAX_BYTES) throw new Error('Image exceeds the 6 MB limit');
      if (bytes.byteLength === 0)      throw new Error('Image was empty');

      const storagePath = `products/bcliquor-${sku}-${Date.now()}.${ext}`;
      const up = await sb.storage.from(BUCKET).upload(storagePath, bytes, {
        contentType, cacheControl: '31536000', upsert: false,
      });
      if (up.error) throw new Error(`Upload failed: ${up.error.message}`);

      const publicUrl = sb.storage.from(BUCKET).getPublicUrl(storagePath).data.publicUrl;

      await sb.from('audit_log').insert({
        user_id: user.id,
        action: 'import_bcliquor_product_image',
        entity_type: 'brand_images',
        changed_fields: ['image_url', 'image_alt'],
        safe_metadata: {
          sku: product.sku,
          product_name: product.name,
          package_size: product.package_size,
        },
      });

      return Response.json({
        image_url: publicUrl,
        image_alt: `${product.name}${product.package_size ? `, ${product.package_size}` : ''}`,
        product,
      }, { headers: corsHeaders });
    }

    // ── importUrl ───────────────────────────────────────────────────────────
    // Copy an arbitrary image URL into our Storage. Pasting a URL can't be done
    // in the browser because the source site won't send CORS headers, so the
    // fetch has to happen here.
    //
    // That makes this a fetch-on-behalf-of endpoint, so it is deliberately
    // constrained: signed-in staff only, http(s) only, obvious internal hosts
    // refused, image content types only, size capped, and rate limited. It
    // reduces the SSRF surface rather than eliminating it — a URL that resolves
    // to a private address through DNS would still be attempted.
    if (action === 'importUrl') {
      const raw = String((body as Record<string, unknown>).url ?? '').trim();
      if (!raw) throw new Error('url required');
      await limit('bcliquor_import', 20);

      let target: URL;
      try { target = new URL(raw); } catch { throw new Error('That is not a valid URL'); }
      if (target.protocol !== 'http:' && target.protocol !== 'https:') {
        throw new Error('Only http and https URLs are allowed');
      }

      const host = target.hostname.toLowerCase();
      const blocked =
        host === 'localhost' || host.endsWith('.local') || host.endsWith('.internal') ||
        host === '::1' || host === '0.0.0.0' ||
        /^127\./.test(host) || /^10\./.test(host) ||
        /^192\.168\./.test(host) || /^169\.254\./.test(host) ||
        /^172\.(1[6-9]|2\d|3[01])\./.test(host);
      if (blocked) throw new Error('That address is not allowed');

      const res = await fetch(target.toString(), {
        headers: { 'Accept': 'image/*', 'User-Agent': UA_IMPORT },
        redirect: 'follow',
        cache: 'no-store',
        signal: timeout(10_000),
      });
      if (!res.ok) throw new Error(`Could not fetch that image (${res.status})`);

      // Re-check after redirects — the first URL being safe doesn't mean the
      // final one is.
      const finalHost = new URL(res.url).hostname.toLowerCase();
      if (/^(localhost|127\.|10\.|192\.168\.|169\.254\.)/.test(finalHost)) {
        throw new Error('That address is not allowed');
      }

      const contentType = (res.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
      const ext = OK_TYPES[contentType];
      if (!ext) throw new Error(`That URL is not an image (${contentType || 'unknown type'})`);

      const bytes = new Uint8Array(await res.arrayBuffer());
      if (!bytes.byteLength)          throw new Error('That image was empty');
      if (bytes.byteLength > MAX_BYTES) throw new Error('Image exceeds the 6 MB limit');

      const path = `pasted/${user.id}-${Date.now()}.${ext}`;
      const up = await sb.storage.from(BUCKET).upload(path, bytes, {
        contentType, cacheControl: '31536000', upsert: false,
      });
      if (up.error) throw new Error(`Upload failed: ${up.error.message}`);

      const publicUrl = sb.storage.from(BUCKET).getPublicUrl(path).data.publicUrl;

      await sb.from('audit_log').insert({
        user_id: user.id,
        action: 'import_image_from_url',
        entity_type: 'brand_images',
        changed_fields: ['image_url'],
        safe_metadata: { source_host: finalHost, bytes: bytes.byteLength, content_type: contentType },
      });

      return Response.json({ image_url: publicUrl, bytes: bytes.byteLength }, { headers: corsHeaders });
    }

    // ── syncPrices ──────────────────────────────────────────────────────────
    // Pull the LDB's published price list into bcl_products. The catalogue API
    // is asked where the latest file lives rather than hardcoding a URL that
    // changes every publication.
    if (action === 'syncPrices') {
      await limit('bcl_sync', 3);

      const pkg = await fetch(
        'https://catalogue.data.gov.bc.ca/api/3/action/package_show?id=bc-liquor-store-product-price-list-historical-prices',
        { headers: { 'Accept': 'application/json', 'User-Agent': UA_SEARCH }, signal: timeout(15_000) },
      ).then(r => r.json());

      const res = pkg?.result?.resources?.[0];
      if (!res?.url) throw new Error('Could not find the price list in the BC Data Catalogue');

      // "BC_Liquor_Store_Product_Price_List_April_2026" → "April 2026"
      const m = /price_list_([a-z]+)_(\d{4})/i.exec(res.url) || /_([A-Za-z]+)_(\d{4})$/.exec(res.name ?? '');
      const label = m ? (m[1][0].toUpperCase() + m[1].slice(1).toLowerCase() + ' ' + m[2]) : (res.name ?? 'unknown');

      const csv = await fetch(res.url, {
        headers: { 'User-Agent': UA_SEARCH }, signal: timeout(60_000),
      }).then(r => { if (!r.ok) throw new Error('Price list download failed (' + r.status + ')'); return r.text(); });

      // A real CSV parse, not split(','): product names can contain commas
      // inside quotes, and one bad row would shift every column after it.
      const parseCsv = (text: string): string[][] => {
        const rows: string[][] = [];
        let row: string[] = [], field = '', inQ = false;
        for (let i = 0; i < text.length; i++) {
          const ch = text[i];
          if (inQ) {
            if (ch === '"') { if (text[i+1] === '"') { field += '"'; i++; } else inQ = false; }
            else field += ch;
          } else if (ch === '"') inQ = true;
          else if (ch === ',') { row.push(field); field = ''; }
          else if (ch === '\n' || ch === '\r') {
            if (field !== '' || row.length) { row.push(field); rows.push(row); row = []; field = ''; }
            if (ch === '\r' && text[i+1] === '\n') i++;
          } else field += ch;
        }
        if (field !== '' || row.length) { row.push(field); rows.push(row); }
        return rows;
      };

      const all = parseCsv(csv);
      const header = all[0].map(h => h.trim());
      const col = (name: string) => header.indexOf(name);
      const iSku = col('PRODUCT_SKU_NO'), iName = col('PRODUCT_LONG_NAME');
      if (iSku === -1 || iName === -1) {
        throw new Error('The price list layout has changed — header: ' + header.join(','));
      }
      const num = (v: string) => { const n = Number(v); return Number.isFinite(n) ? n : null; };

      const rows = all.slice(1)
        .filter(r => r[iSku]?.trim() && r[iName]?.trim())
        .map(r => ({
          sku: r[iSku].trim(),
          name: r[iName].trim(),
          category: r[col('ITEM_CATEGORY_NAME')]?.trim() || null,
          subcategory: r[col('ITEM_SUBCATEGORY_NAME')]?.trim() || null,
          class: r[col('ITEM_CLASS_NAME')]?.trim() || null,
          country: r[col('PRODUCT_COUNTRY_ORIGIN_NAME')]?.trim() || null,
          upc: r[col('PRODUCT_BASE_UPC_NO')]?.trim() || null,
          litres: num(r[col('PRODUCT_LITRES_PER_CONTAINER')]),
          containers: num(r[col('PRD_CONTAINER_PER_SELL_UNIT')]),
          alcohol_pct: num(r[col('PRODUCT_ALCOHOL_PERCENT')]),
          price: num(r[col('PRODUCT_PRICE')]),
          list_label: label,
          updated_at: new Date().toISOString(),
        }));

      // The same SKU can appear more than once; last one wins, and upserting
      // a batch containing a duplicate key is an error rather than a merge.
      const bySku = new Map<string, (typeof rows)[number]>();
      for (const row of rows) bySku.set(row.sku, row);
      const unique = [...bySku.values()];

      for (let i = 0; i < unique.length; i += 1000) {
        const { error } = await sb.from('bcl_products')
          .upsert(unique.slice(i, i + 1000), { onConflict: 'sku' });
        if (error) throw new Error('Import failed at row ' + i + ': ' + error.message);
      }

      await sb.from('audit_log').insert({
        user_id: user.id,
        action: 'sync_bcl_prices',
        entity_type: 'bcl_products',
        changed_fields: ['price'],
        safe_metadata: { list: label, products: unique.length },
      });

      return Response.json({ imported: unique.length, list: label }, { headers: corsHeaders });
    }

    // ── buildLibrary ────────────────────────────────────────────────────────
    // Turn a store's imported inventory into Product Library entries, with
    // images linked only when we are sure: the SKU must exist in the BCL
    // price table (exact match — POS Item IDs are BCL SKUs), and BCL's image
    // for that exact SKU must actually exist. No fuzzy matching, no guessed
    // photos. Items that fail either test are skipped and counted, not faked.
    //
    // Works in batches — the frontend calls repeatedly until remaining is 0 —
    // so one invocation never runs long and BCL is fetched politely.
    if (action === 'buildLibrary') {
      const storeId = String(body.storeId ?? '').trim();
      if (!storeId) throw new Error('storeId required');
      const batch = Math.min(Math.max(Number(body.batch) || 15, 1), 25);
      await limit('bcliquor_build', 400);

      // Everything the store carries…
      const { data: inv } = await sb.from('store_inventory')
        .select('sku, description').eq('store_id', storeId).order('sku').range(0, 9999);
      if (!inv?.length) throw new Error('No inventory imported for this store yet');

      // …minus what the library already has, by SKU or by exact name — a
      // hand-made product without a SKU should not come back as a duplicate.
      const { data: lib } = await sb.from('brand_images')
        .select('bcliquor_sku, product_name').range(0, 9999);
      const haveSku  = new Set((lib ?? []).map(r => String(r.bcliquor_sku ?? '')).filter(Boolean));
      const haveName = new Set((lib ?? []).map(r => String(r.product_name ?? '').trim().toUpperCase()).filter(Boolean));

      // The cursor is the last SKU already walked past (in any earlier call),
      // so skipped items are never retried and the loop always terminates.
      const cursor = String((body as Record<string, unknown>).cursor ?? '');
      const todo = inv
        .filter(r => !haveSku.has(String(r.sku)))
        .filter(r => String(r.sku) > cursor);

      let created = 0, noBcl = 0, noImage = 0, dupName = 0;
      let lastSku = cursor;

      for (const item of todo) {
        if (created >= batch) break;
        const sku = String(item.sku);
        lastSku = sku;

        // Sure means: this exact SKU is in the government list.
        const { data: bcl } = await sb.from('bcl_products')
          .select('name, category, subcategory, litres, containers').eq('sku', sku).maybeSingle();
        if (!bcl) { noBcl++; continue; }
        if (haveName.has(bcl.name.trim().toUpperCase())) {
          // Already in the library by name — link the SKU rather than duplicate.
          await sb.from('brand_images').update({ bcliquor_sku: sku })
            .eq('product_name', bcl.name).is('bcliquor_sku', null);
          dupName++; continue;
        }

        // BCL's image URL is deterministic per SKU; existence is the test.
        const imgRes = await fetch(`${IMG_BASE}/${encodeURIComponent(sku)}.jpg`, {
          headers: { 'Accept': 'image/jpeg,image/png,image/webp', 'User-Agent': UA_IMPORT },
          cache: 'no-store', signal: timeout(10_000),
        }).catch(() => null);
        if (!imgRes || !imgRes.ok) { noImage++; continue; }
        const contentType = (imgRes.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
        const ext = OK_TYPES[contentType];
        const bytes = ext ? new Uint8Array(await imgRes.arrayBuffer()) : null;
        if (!bytes || !bytes.byteLength || bytes.byteLength > MAX_BYTES) { noImage++; continue; }

        const storagePath = `products/bcliquor-${sku}-${Date.now()}.${ext}`;
        const up = await sb.storage.from(BUCKET).upload(storagePath, bytes, {
          contentType, cacheControl: '31536000', upsert: false,
        });
        if (up.error) { noImage++; continue; }
        const publicUrl = sb.storage.from(BUCKET).getPublicUrl(storagePath).data.publicUrl;

        const size = bcl.litres
          ? ((bcl.containers && bcl.containers > 1 ? bcl.containers + ' × ' : '') +
             (bcl.litres < 1 ? Math.round(bcl.litres * 1000) + ' mL' : bcl.litres + ' L'))
          : '';
        const cat = (function(c: string) {
          const s = c.toLowerCase();
          if (/beer|cider|cooler|refresh/.test(s)) return 'beer-cider';
          if (/red/.test(s) && /wine/.test(s)) return 'red-wine';
          if (/white/.test(s) && /wine/.test(s)) return 'white-wine';
          if (/ros|sparkling|champagne/.test(s)) return 'rose-sparkling';
          if (/whisky|whiskey|bourbon|scotch|rye/.test(s)) return 'whisky';
          if (/vodka/.test(s)) return 'vodka';
          if (/gin/.test(s)) return 'gin';
          if (/rum/.test(s)) return 'rum';
          if (/tequila|agave|mezcal/.test(s)) return 'tequila';
          if (/liqueur|aperitif|brandy|cognac/.test(s)) return 'liqueur';
          if (/wine/.test(s)) return 'red-wine';
          return '';
        })((bcl.subcategory || bcl.category || ''));

        const { error: insErr } = await sb.from('brand_images').insert({
          store_id: null,
          product_name: bcl.name,
          size, category: cat, notes: '',
          image_url: publicUrl, data: null,
          bcliquor_sku: sku,
        });
        if (insErr) { noImage++; continue; }
        haveName.add(bcl.name.trim().toUpperCase());
        created++;
      }

      const walked = created + noBcl + noImage + dupName;

      await sb.from('audit_log').insert({
        user_id: user.id,
        action: 'build_product_library',
        entity_type: 'brand_images',
        changed_fields: ['bulk_import'],
        safe_metadata: { storeId, created, noBcl, noImage, dupName },
      });

      return Response.json({
        created, linked: dupName, skippedNoBcl: noBcl, skippedNoImage: noImage,
        cursor: lastSku,
        remaining: Math.max(0, todo.length - walked),
      }, { headers: corsHeaders });
    }

    throw new Error(`Unknown action: ${action}`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const status = /Too many requests/.test(msg) ? 429
                 : /Not permitted|session|Authorization/.test(msg) ? 403
                 : 400;
    return Response.json({ error: msg }, { status, headers: corsHeaders });
  }
});
