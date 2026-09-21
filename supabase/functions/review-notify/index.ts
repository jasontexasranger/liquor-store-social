// ============================================================================
// review-notify — emails when a store sends a creative approval back
// ============================================================================
// Called by creative-review.html straight after review_submit succeeds. The
// review page has no login, so this is reached with the project's anon key,
// which is enough to pass the gateway and nothing more: the only thing the
// caller supplies is the review token, and everything in the email is read
// server-side with the service role from the row that token identifies.
//
// That matters. The caller cannot choose a recipient, cannot inject content
// into the message, and cannot learn anything it didn't already have — a
// wrong token gets the same empty answer as a missing one.
//
// Following sendSpendAlertEmail's precedent: with no RESEND_API_KEY set this
// returns { sent: false } rather than failing. The submission itself is
// already recorded by then, and the Approvals card shows it regardless — the
// email is the convenience, not the record.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const STORE_NAMES: Record<string, string> = {
  hideaway: 'Hideaway',
  downtown: 'Downtown',
  cobblestone: 'Cobblestone',
  brothers: 'Brothers',
};

const esc = (s: unknown) =>
  String(s ?? '').replace(/[&<>"]/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c] as string));

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const { token } = await req.json() as { token?: string };
    if (!token) throw new Error('token required');

    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: review } = await sb.from('creative_reviews')
      .select('id, store_id, title, status, reviewer, note, submitted_at')
      .eq('token', token).maybeSingle();

    // Same answer for a bad token as for one that isn't submitted yet: this
    // endpoint is not a way to probe which tokens exist.
    if (!review || review.status !== 'submitted') {
      return Response.json({ sent: false }, { headers: corsHeaders });
    }

    const { data: items } = await sb.from('creative_review_items')
      .select('name, aspect, decision, note')
      .eq('review_id', review.id).order('sort');

    const rows = items ?? [];
    const flagged  = rows.filter(i => i.decision === 'rejected');
    const approved = rows.filter(i => i.decision === 'approved');

    const key = Deno.env.get('RESEND_API_KEY');
    if (!key) return Response.json({ sent: false, reason: 'no_key' }, { headers: corsHeaders });
    const to = Deno.env.get('ALERT_EMAIL') || 'jasontexasranger@gmail.com';

    const store = STORE_NAMES[review.store_id] ?? review.store_id;
    const subject = flagged.length
      ? `${store} flagged ${flagged.length} creative${flagged.length === 1 ? '' : 's'} — ${esc(review.title)}`
      : `${store} approved all ${approved.length} creatives — ${esc(review.title)}`;

    // The flagged items and their notes lead, because they are the only part
    // that needs anyone to do something.
    const flaggedHtml = flagged.length
      ? `<p><strong>Needs changing:</strong></p><ul>${flagged.map(i =>
          `<li><strong>${esc(i.name)}</strong>${i.aspect ? ` (${esc(i.aspect)})` : ''}` +
          `${i.note ? ` — ${esc(i.note)}` : ' — no reason given'}</li>`).join('')}</ul>`
      : '<p>Nothing was flagged.</p>';

    const html = `
      <p><strong>${esc(review.reviewer || store)}</strong> has sent back
         “${esc(review.title)}”.</p>
      <p>${approved.length} approved · ${flagged.length} flagged
         · ${rows.length} in the round.</p>
      ${flaggedHtml}
      ${review.note ? `<p><strong>Their note:</strong> ${esc(review.note)}</p>` : ''}
      <p style="color:#777;font-size:12px">Open Features → the store's month →
         Approvals to see the whole round.</p>
    `.trim();

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: 'LRS Approvals <onboarding@resend.dev>',
        to: [to],
        subject,
        html,
      }),
    });

    return Response.json({ sent: res.ok }, { headers: corsHeaders });
  } catch (e) {
    // Never fail loudly: the store has already submitted by the time this
    // runs, and a bounced email must not make them think it didn't save.
    return Response.json({ sent: false, error: (e as Error).message }, { headers: corsHeaders });
  }
});
