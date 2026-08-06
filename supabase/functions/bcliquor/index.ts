// supabase/functions/bcliquor/index.ts
// BC Liquor Stores product lookup + image import.
//
// Two actions:
//   search  — query the public BCLIQUOR catalogue, return normalized products
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

    const body = await req.json() as { action: string; query?: string; sku?: string };
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

    throw new Error(`Unknown action: ${action}`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const status = /Too many requests/.test(msg) ? 429
                 : /Not permitted|session|Authorization/.test(msg) ? 403
                 : 400;
    return Response.json({ error: msg }, { status, headers: corsHeaders });
  }
});
