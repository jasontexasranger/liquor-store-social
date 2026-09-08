// supabase/functions/weather-provider/index.ts
// Normalized weather data source for the trigger engine. Two actions:
//
//   invoke('weather-provider', { action:'geocode', city, province })
//     -> [{ name, admin1, lat, lng }]
//
//   invoke('weather-provider', { action:'weather', latitude, longitude })
//     -> { current, daily[], airQuality, alerts[], capabilities, missing[] }
//
// The engine only ever sees that normalized shape — it has no idea this is
// Open-Meteo underneath. Swapping providers later means rewriting this one
// file; nothing downstream changes.
//
// Open-Meteo needs no API key, which is why it's the default here. It also
// has no official severe-weather alerts, so `alerts` is always `[]` and
// `capabilities.alerts` is always false — that's reported honestly rather
// than silently pretending alerts were checked and found clear.
//
// Auth: same shared-secret pattern as the other cron-driven functions in
// this project — an admin session, or the x-cron-secret header (used when
// the engine calls this function server-to-server).
//
// Required edge function secrets:
//   CRON_SECRET                — shared with pg_cron and the engine/executor/report functions
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-set

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

async function requireAdminOrCron(req: Request, sb: ReturnType<typeof createClient>): Promise<void> {
  const cronSecret = Deno.env.get('CRON_SECRET');
  const provided = req.headers.get('x-cron-secret');
  if (cronSecret && provided === cronSecret) return;

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) throw new Error('Missing Authorization header');
  const token = authHeader.replace('Bearer ', '');
  const { data: { user }, error } = await sb.auth.getUser(token);
  if (error || !user) throw new Error('Invalid session');
  const { data: role } = await sb.from('user_roles').select('role').eq('user_id', user.id).single();
  const ADMIN_EMAILS = ['jasontexasranger@gmail.com', 'jason@vwdevelopments.com', 'tim@vwdevelopments.com'];
  if (role?.role !== 'admin' && !ADMIN_EMAILS.includes(user.email ?? '')) {
    throw new Error('Admin access required');
  }
}

// ─── Geocode ──────────────────────────────────────────────────────────────
// Search by city name alone and use province to *prefer* a match, not to
// filter the query string — "Cobble Hill BC" as a single search string
// returns nothing from Open-Meteo's geocoder, but "Cobble Hill" plus
// preferring admin1="British Columbia" resolves correctly.
async function geocode(city: string, province?: string) {
  const url = `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(city)}&count=10&language=en&format=json`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Geocoding lookup failed (${res.status})`);
  const data = await res.json();
  const results = (data.results ?? []) as Array<{
    name: string; admin1?: string; latitude: number; longitude: number;
  }>;
  const norm = (s?: string) => (s || '').toLowerCase();
  const preferred = province
    ? results.filter(r => norm(r.admin1).includes(norm(province)) || norm(province).includes(norm(r.admin1)))
    : [];
  const ordered = preferred.length ? [...preferred, ...results.filter(r => !preferred.includes(r))] : results;
  return ordered.map(r => ({ name: r.name, admin1: r.admin1 ?? null, lat: r.latitude, lng: r.longitude }));
}

// ─── Weather ──────────────────────────────────────────────────────────────
async function weather(latitude: number, longitude: number) {
  const capabilities = { current: true, daily: true, airQuality: true, alerts: false };
  const missing: string[] = [];

  const forecastUrl = 'https://api.open-meteo.com/v1/forecast'
    + `?latitude=${latitude}&longitude=${longitude}`
    + '&current=temperature_2m,precipitation,weather_code,wind_speed_10m'
    + '&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,snowfall_sum,weather_code'
    + '&timezone=auto&forecast_days=7';

  const airUrl = 'https://air-quality-api.open-meteo.com/v1/air-quality'
    + `?latitude=${latitude}&longitude=${longitude}&current=us_aqi,pm2_5&timezone=auto`;

  const [forecastRes, airRes] = await Promise.all([
    fetch(forecastUrl),
    fetch(airUrl).catch(() => null),
  ]);

  if (!forecastRes.ok) throw new Error(`Weather lookup failed (${forecastRes.status})`);
  const f = await forecastRes.json();

  let airQuality: { usAqi: number | null; pm25: number | null } | null = null;
  if (airRes && airRes.ok) {
    try {
      const a = await airRes.json();
      airQuality = { usAqi: a.current?.us_aqi ?? null, pm25: a.current?.pm2_5 ?? null };
    } catch { airQuality = null; }
  }
  if (!airQuality) { missing.push('airQuality'); capabilities.airQuality = false; }
  missing.push('alerts'); // never available from this provider — see file header

  const current = {
    tempC: f.current?.temperature_2m ?? null,
    precipitationMm: f.current?.precipitation ?? null,
    windSpeedKmh: f.current?.wind_speed_10m ?? null,
    weatherCode: f.current?.weather_code ?? null,
  };

  const dailyTimes: string[] = f.daily?.time ?? [];
  const daily = dailyTimes.map((date: string, i: number) => ({
    date,
    tempMaxC: f.daily?.temperature_2m_max?.[i] ?? null,
    tempMinC: f.daily?.temperature_2m_min?.[i] ?? null,
    precipProbMaxPct: f.daily?.precipitation_probability_max?.[i] ?? null,
    snowfallCm: f.daily?.snowfall_sum?.[i] ?? null,
    weatherCode: f.daily?.weather_code?.[i] ?? null,
  }));

  return { current, daily, airQuality, alerts: [] as unknown[], capabilities, missing };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    await requireAdminOrCron(req, sb);

    const { action, ...params } = await req.json() as Record<string, unknown> & { action: string };

    if (action === 'geocode') {
      const { city, province } = params as { city?: string; province?: string };
      if (!city) throw new Error('city required');
      const results = await geocode(city, province);
      return Response.json({ results }, { headers: corsHeaders });
    }

    if (action === 'weather') {
      const { latitude, longitude } = params as { latitude?: number; longitude?: number };
      if (latitude == null || longitude == null) throw new Error('latitude and longitude required');
      const snapshot = await weather(latitude, longitude);
      return Response.json(snapshot, { headers: corsHeaders });
    }

    throw new Error(`Unknown action: ${action}`);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return Response.json({ error: message }, { status: 400, headers: corsHeaders });
  }
});
