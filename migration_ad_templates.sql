-- ============================================================================
-- Template-driven price ads
-- ============================================================================
-- The price ad renderer currently draws its own navy panels and yellow badges
-- in code. That fights against artwork like the Hideaway template, where those
-- shapes are already baked into the image.
--
-- This makes ad templates work the same way shelf talkers already do: upload a
-- blank, place labelled boxes on it visually, and the renderer only fills those
-- boxes. Field geometry is stored in percentages so one layout survives being
-- rendered at 1080, 1242 or any other size.
-- ============================================================================

-- 1. Extend brand_templates --------------------------------------------------
ALTER TABLE public.brand_templates
  ADD COLUMN IF NOT EXISTS kind        TEXT NOT NULL DEFAULT 'plain',
  ADD COLUMN IF NOT EXISTS canvas_w    INT,
  ADD COLUMN IF NOT EXISTS canvas_h    INT,
  ADD COLUMN IF NOT EXISTS updated_at  TIMESTAMPTZ;

COMMENT ON COLUMN public.brand_templates.kind IS
  'plain = background only; price_ad = has positioned fields in ad_template_fields';

-- 2. Field layout ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ad_template_fields (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id   UUID NOT NULL REFERENCES public.brand_templates(id) ON DELETE CASCADE,
  field_order   INT  NOT NULL DEFAULT 0,

  -- what this box is for
  field_key     TEXT NOT NULL,          -- product_name | pack_size | price | save | product_image | custom
  field_type    TEXT NOT NULL DEFAULT 'text'
                CHECK (field_type IN ('text','product_image')),
  label         TEXT NOT NULL DEFAULT 'Field',

  -- geometry, percentage of canvas so it scales to any output size
  x_pct         NUMERIC NOT NULL,
  y_pct         NUMERIC NOT NULL,
  w_pct         NUMERIC NOT NULL,
  h_pct         NUMERIC NOT NULL,

  -- text rendering
  align         TEXT    DEFAULT 'left',
  valign        TEXT    DEFAULT 'top',
  color         TEXT    DEFAULT '#000000',
  bold          BOOLEAN DEFAULT false,
  uppercase     BOOLEAN DEFAULT false,
  wrap          BOOLEAN DEFAULT true,
  max_lines     INT     DEFAULT 2,
  min_font_size INT     DEFAULT 8,
  max_font_size INT     DEFAULT 200,
  line_spacing  NUMERIC DEFAULT 1.15,
  prefix        TEXT    DEFAULT '',
  suffix        TEXT    DEFAULT '',

  -- product_image rendering
  fit_mode      TEXT    DEFAULT 'contain' CHECK (fit_mode IN ('contain','cover')),
  remove_bg     BOOLEAN DEFAULT true,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ad_template_fields_tpl_idx
  ON public.ad_template_fields (template_id, field_order);

-- 3. RLS ---------------------------------------------------------------------
ALTER TABLE public.ad_template_fields ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ad_template_fields_read  ON public.ad_template_fields;
DROP POLICY IF EXISTS ad_template_fields_write ON public.ad_template_fields;

CREATE POLICY ad_template_fields_read ON public.ad_template_fields
  FOR SELECT TO authenticated USING (true);

CREATE POLICY ad_template_fields_write ON public.ad_template_fields
  FOR ALL TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- 4. Keep updated_at honest --------------------------------------------------
DROP TRIGGER IF EXISTS brand_templates_touch ON public.brand_templates;
CREATE TRIGGER brand_templates_touch
  BEFORE UPDATE ON public.brand_templates
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 5. Verify ------------------------------------------------------------------
-- SELECT t.id, t.label, t.kind, count(f.id) AS fields
--   FROM public.brand_templates t
--   LEFT JOIN public.ad_template_fields f ON f.template_id = t.id
--  GROUP BY t.id, t.label, t.kind
--  ORDER BY t.created_at DESC;
