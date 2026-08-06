-- ============================================================================
-- Historical features import — January to July 2026
-- ============================================================================
-- Extracted from "LRS FEATURES 2026 (1).xlsx", one tab per month.
--
-- Columns are located by HEADER, not position: the July tab is shifted one
-- column right from Reg Price onward, so fixed offsets would have read its
-- Qty Sold as Revenue. Validated by checking qty x sale price against revenue
-- across 116 rows in Feb, Apr and Jul — all consistent.
--
-- Every value is cast explicitly. VALUES infers a column's type from its first
-- row, so a block where no quantities were recorded reads as all-NULL and
-- Postgres assumes text, which then fails against an integer column.
--
-- Savings comes from the sheet as written, not recalculated.
-- Revenue of exactly 0 and blank quantities are treated as "not recorded".
-- Periods are created as 'closed' since these months are historical.
-- Re-runnable: periods upsert, and each month's rows are cleared first.
-- ============================================================================


-- ── Jan 2026 ─────────────────────────────────────────────

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('hideaway', DATE '2026-01-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='hideaway' AND period=DATE '2026-01-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'CANADIAN', '15CAN', 31.5, 26.99, 4.5, NULL, NULL, NULL),
    (1, 'COORS LIGHT', '15CAN', 31.5, 26.99, 4.5, NULL, NULL, NULL),
    (2, 'OLD STYLE PIL', '24CAN', 42, 32.99, 9, NULL, NULL, NULL),
    (3, 'COORS SELTZER ALL MIXERS', '12CAN', 32, 28.99, 3, NULL, NULL, NULL),
    (4, 'TWISTED TEA 12PACKS', '12CAN', 26.5, 22.79, 3.75, NULL, NULL, NULL),
    (5, 'FONTERA CAB SAUV AND SAUV BLANC', '750ML', 12.5, 9.99, 2.5, NULL, NULL, NULL),
    (6, 'SAINTLY RED/WHITE/ROSE/SPRK', '750ML', NULL, NULL, 0, NULL, NULL, NULL),
    (7, 'BAILEYS', '1.14L', 45.25, 36.99, 8.25, NULL, NULL, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='hideaway' AND p.period=DATE '2026-01-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('brothers', DATE '2026-01-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='brothers' AND period=DATE '2026-01-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Nutrl 7% Berry', '8 x 355ml', 22.99, 19.99, 3, 16, 319.84, NULL),
    (1, 'Sun Cruiser', '6 x 355ml', 16.49, 14.49, 2, 32, 463.68, NULL),
    (2, 'Nude Mixer', '12 x 355ml', 29.99, 27.99, 2, 37, 1035.63, NULL),
    (3, 'Lone Tree Apple Cider', '6 x 355ml', 15.49, 13.49, 2, 8, 107.92, NULL),
    (4, 'Canadian Club', '1.14L', 36.99, 34.99, 2, 6, 209.94, NULL),
    (5, 'Busch Lager', '8 x 355ml', 14.99, 12.49, 2.5, 46, 574.54, NULL),
    (6, 'Stanley Park Trailhopper IPA', '473ml', 4.19, 2.99, 1.25, 48, 143.52, NULL),
    (7, 'Alberta Pure', '1.14L', 36.99, 34.49, 2.5, 16, 551.84, NULL),
    (8, 'Peller Rose', '4L', 44.99, 40.99, 4, 10, 409.9, NULL),
    (9, 'Bask Pinot Grigio', '750ml', 13.99, 11.99, 2, 31, 371.69, NULL),
    (10, 'Sawmill Creek Merlot', '750ml', 10.49, 8.49, 2, 25, 212.25, NULL),
    (11, 'Corona Cero', '12 x 355ml', 22.99, 19.99, 3, 10, 199.9, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='brothers' AND p.period=DATE '2026-01-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('cobblestone', DATE '2026-01-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='cobblestone' AND period=DATE '2026-01-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'VIB Island Lager 15pk', '15AR', NULL, 23.5, 0, 7, 164.5, NULL),
    (1, 'Phillips Playlist', '8AR', NULL, 20.5, 0, NULL, NULL, NULL),
    (2, 'Chronic Cellers Syrah', '750ml', 20, 17, 3, 5, 85, NULL),
    (3, 'French Door French Blend', '750ml', 52.99, 44, 9, NULL, NULL, NULL),
    (4, 'Jack Daniels Tennesee Fire', '750ml', NULL, 38.75, 0, 1, 38.75, NULL),
    (5, 'Quinoa Vodka', '750ml', 56.25, 54, 2.25, NULL, NULL, NULL),
    (6, 'Somersby Mixer', '8AR', NULL, 24.25, 0, 0, NULL, NULL),
    (7, 'IOTA Non Alcoholic Peach Ale', '4AR', 8.55, 8.05, 0.5, 4, 32.2, NULL),
    (8, 'Dulce Vida Pineapple', '750ml', NULL, 58.25, 0, NULL, NULL, NULL),
    (9, 'OK Variety Pack', '12AR', 28.5, 26.5, 2, NULL, NULL, NULL),
    (10, 'Dulce Vida Pineapple', '750ml', NULL, 58.25, 0, NULL, NULL, NULL),
    (11, 'OK Variety Pack', '12AR', 28.5, 26.5, 2, NULL, NULL, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='cobblestone' AND p.period=DATE '2026-01-01';

-- ── Feb 2026 ─────────────────────────────────────────────

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('hideaway', DATE '2026-02-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='hideaway' AND period=DATE '2026-02-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Epicuro Pinot Grigio & Primitivo', '750ml', 15, 12.99, 2, 48, 623.52, NULL),
    (1, 'Frontera Sauv Blanc& Cab Sauv', '750ml', 12.5, 9.99, 2.5, 32, 319.68, 'case price under $120'),
    (2, 'Canadian', '15 Can', 31.5, 26.99, 4.5, 70, 1889.3, NULL),
    (3, 'Coors Light', '15 Can', 31.5, 26.99, 4.5, 103, 2779.97, 'enter to win a coors light snowsuit!'),
    (4, 'Lighthouse Craft Mixer', '12 Can', 28.5, 23.99, 4.5, 19, 455.81, NULL),
    (5, 'Georgian Bay Gin Mixer', '12 Can', 31, 26.99, 4, 8, 215.92, NULL),
    (6, 'Truly Brunch Mix', '12 Can', 32.25, 26.99, 5.25, 15, 404.85, NULL),
    (7, 'Esa Lime Margarita & Pear Margarita', '4 Can', 17.5, 12.49, 5, 13, 162.37, 'Need these gone - they are pennies over cost - advertise hard!!'),
    (8, 'Baileys Chocolate', '750ml', 33.75, 29.99, 3.75, 17, 509.83, NULL),
    (9, '1800 Coconut', '750ml', 45.75, 42.79, 3, 4, 171.16, NULL),
    (10, 'Smirnoff', '750ml', 26.25, 23.79, 2.5, 89, 2117.31, NULL),
    (11, '40 Creek Double Barrell', '750ml', 45, 36.99, 8, 24, 887.76, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='hideaway' AND p.period=DATE '2026-02-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('downtown', DATE '2026-02-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='downtown' AND period=DATE '2026-02-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'OLD MILWAUKEE', '8CAN', 15.25, 13.29, 2, 40, 531.06, NULL),
    (1, 'CARIBOO LAGER', '6CAN', 10.25, 9.19, 1, 28, 257.32, NULL),
    (2, 'CANADIAN', '15CAN', 31.5, 26.99, 4.5, 0, NULL, 'Never had the product was not on sale'),
    (3, 'JACK AND COKE', '4CAN', 14.75, 12.79, 2, 11, 140.69, NULL),
    (4, 'MOTTS CAESAR ORIGINAL', '12CAN', 34.25, 29.99, 4.25, 6, 179.94, NULL),
    (5, 'FIREBALL', '750ML', 26.25, 22.99, 3.25, 11, 252.89, NULL),
    (6, 'EMPRESS 1908 GIN', '750ML', 57.75, 50.99, 6.75, 8, 407.92, NULL),
    (7, 'CPT MORGAN SPICED', '750ML', 31.5, 28.99, 2.5, 13, 376.87, NULL),
    (8, 'ESPOLON BLANCO', '750ML', 49.25, 44.99, 4.25, 4, 179.96, NULL),
    (9, 'ABSOLUT', '750ML', 30.5, 26.99, 3.5, 11, 296.89, NULL),
    (10, 'BLACK SAGE CAB FRANC', '750ML', 34.25, 27.99, 6.25, 23, 643.77, NULL),
    (11, 'FINCA LOS MALBEC', '1L', 18.25, 14.79, 3.5, 5, 73.95, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='downtown' AND p.period=DATE '2026-02-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('brothers', DATE '2026-02-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='brothers' AND period=DATE '2026-02-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Bodacious Smooth White', '1.5L', 19.99, 16.99, 3, 31, 526.69, NULL),
    (1, 'Kim Crawford Chardonnay', '750ml', 24.99, 17.99, 7, 4, 71.96, NULL),
    (2, 'Cono Sur Pinot Noir', '750ml', 13.99, 10.99, 3, 14, 153.86, NULL),
    (3, 'Guinness Draught', '8 x 473ml', 26.99, 23.49, 3.5, 21, 493.29, NULL),
    (4, 'Sleeman Original', '8 x 355ml', 15.99, 13.99, 2, 14, 195.86, NULL),
    (5, 'Bacardi White Rum PET', '1.14L', 36.99, 33.99, 3, 16, 543.84, NULL),
    (6, 'Okanagan Peach Cider', '6 x 355ml', 15.49, 12.99, 2.5, 29, 376.71, NULL),
    (7, 'American Vintage Barely Sweet', '6 x 355ml', 14.99, 12.99, 2, 42, 545.58, NULL),
    (8, 'Michelob Ultra', '15 x 355ml', 34.49, 29.99, 4.5, 78, 2339.22, NULL),
    (9, 'Old Style Pilsner', '710ml', 4.49, 3, 1.5, 102, 306, NULL),
    (10, 'Crown Royal', '750ml', 30.99, 28.99, 2, 28, 811.72, NULL),
    (11, 'Cariboo Lager', '6 x 355ml', 9.99, 8.49, 1.5, 90, 764.1, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='brothers' AND p.period=DATE '2026-02-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('cobblestone', DATE '2026-02-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='cobblestone' AND period=DATE '2026-02-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Lucky Extra', '15 Can', 30.25, 28.25, 2, NULL, NULL, NULL),
    (1, 'Bud Light', '24 Bottles', 60.25, 46.99, 13.25, NULL, NULL, NULL),
    (2, 'Bumper Crop Apple', '6 Pack', 12, 11, 1, NULL, NULL, NULL),
    (3, 'Beefeater', '750ml', 26.95, 24.95, 2, NULL, NULL, NULL),
    (4, 'Glennfidich', '375ml', 43.5, 40, 3.5, NULL, NULL, NULL),
    (5, 'Pesquie Ventoux', '750ml', 22, 21, 1, NULL, NULL, NULL),
    (6, 'Tempo Strawberry', '6 Pack', 18, 17, 1, NULL, NULL, NULL),
    (7, 'Harpers Trail Sparkling', '750ml', 21.5, 20.5, 1, NULL, NULL, NULL),
    (8, '360 Double Chocolate Vodka', '750ml', 31.75, 29.75, 2, NULL, NULL, NULL),
    (9, 'Lambs Dark Rum', '1.14l', 36.75, 34.75, 2, NULL, NULL, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='cobblestone' AND p.period=DATE '2026-02-01';

-- ── Mar 2026 ─────────────────────────────────────────────

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('hideaway', DATE '2026-03-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='hideaway' AND period=DATE '2026-03-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'BUSCH', '15CAN', 28.25, 21.49, 6.75, 264, 5673.36, NULL),
    (1, 'OLD STYLE PILSNER', '15CAN', 27.75, 21.49, 6.25, 212, 4555.88, NULL),
    (2, 'SLEEMAN CLEAR', '24CAN', 53.25, 47.99, 5.25, 19, 911.81, NULL),
    (3, 'GUINNESS', '8CAN', 26.75, 22.99, 3.75, 47, 1080.53, NULL),
    (4, 'DRIFTWOOD FAT TUG', '6CAN', 17.5, 13.99, 3.5, 70, 979.3, NULL),
    (5, 'JAMESON', '750ML', 43, 37.99, 5, 24, 911.76, NULL),
    (6, 'KAHLUA', '750ML', 32.5, 27.99, 4.5, 15, 419.85, NULL),
    (7, 'GROWERS SPRITS ALL FLAVOURS', '6CAN', 15.25, 12.29, 3, 29, 356.41, 'WATERMELON, STRAWBERRY LEMONADE, PEACH'),
    (8, 'JACK AND COKE', '4CAN', 14.75, 12.79, 2, 27, 345.33, NULL),
    (9, 'COORS SLUSHIE 7% MIXER', '12CAN', 33.25, 27.99, 5.25, 57, 1595.43, 'NEW 2026 RELEASE'),
    (10, 'JACOBS CREEK DBL BRL SHIRAZ & CAB SAUV', '750ML', 21.5, 17.99, 3.5, 35, 629.65, NULL),
    (11, 'LAYLOW PINOT GRIGIO & ROSE', '750ML', 12, 9.99, 2, 24, 239.76, 'LIGHT ALCOHOL 6.5%'),
    (12, 'TASTINGS', NULL, NULL, NULL, NULL, NULL, NULL, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='hideaway' AND p.period=DATE '2026-03-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('downtown', DATE '2026-03-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='downtown' AND period=DATE '2026-03-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'VEUVE DEVIENNE BRUT', '750ML', 16.5, 14.49, 2, NULL, NULL, NULL),
    (1, 'LAW LOW PINOT GRIGIO & ROSE', '750ML', 12, 9.99, 2, NULL, NULL, NULL),
    (2, 'BLASTED CHURCH HATFEILD WHITE', '750ML', 21, 17.99, 3, NULL, NULL, NULL),
    (3, 'BLASTED CHURCH BIG BANG RED', '750ML', 25, 21.99, 3, NULL, NULL, NULL),
    (4, 'VIVO SAUV BLANC & CAB SAUV', '4L', 39, 34.49, 4.5, NULL, NULL, NULL),
    (5, 'VIVO SAUV BLANC, CAB SAUV, PINOT NOIR', '750ML', 13.5, 10.79, 2.75, NULL, NULL, NULL),
    (6, 'OLD STYLE PILSNER', '15CAN', 27.75, 21.49, 6.25, NULL, NULL, NULL),
    (7, 'BUSCH', '15CAN', 28.25, 21.49, 6.75, NULL, NULL, NULL),
    (8, 'GUINNESS', '8CAN', 26.75, 22.99, 3.75, NULL, NULL, NULL),
    (9, 'JAMESON', '750ML', 43, 37.99, 5, NULL, NULL, NULL),
    (10, 'IRISH MIST', '750ML', 41, 33.99, 7, NULL, NULL, NULL),
    (11, 'BAILEYS', '1.14L', 46.25, 41.29, 5, NULL, NULL, NULL),
    (12, 'TASTINGS', NULL, NULL, NULL, NULL, NULL, NULL, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='downtown' AND p.period=DATE '2026-03-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('brothers', DATE '2026-03-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='brothers' AND period=DATE '2026-03-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Dillon''s Vodka Cocktail Mixer', '12AR', 32.99, 29.99, 3, 15, 449.85, NULL),
    (1, 'Ole Tequila Sunrise', '4AR', 17.49, 14.49, 3, 21, 304.29, NULL),
    (2, 'Carolan''s Irish Cream', '1.14L', 42.99, 39.99, 3, 26, 1039.74, NULL),
    (3, 'Proper 12 Irish Whiskey', '750ml', 41.99, 39.99, 2, 2, 79.98, NULL),
    (4, 'Alamos Malbec', '750ml', 19.49, 16.49, 3, 36, 593.64, NULL),
    (5, 'Mission Hill Sauvignon Blanc New Zealand', '750ml', 27.99, 24.99, 3, 8, 199.92, NULL),
    (6, 'Flor de Cana 7 Year Rum', '750ml', 38.49, 35.49, 3, 4, 141.96, NULL),
    (7, 'Bearface Triple Oak Whisky', '750ml', 39.99, 36.99, 3, 13, 480.87, 'New Item'),
    (8, 'Jose Cuervo Especial Gold', '1.14L', 56.99, 53.99, 3, 17, 917.83, NULL),
    (9, 'Moosehead Lager', '8AR', 15.49, 13.49, 2, 9, 121.41, 'New Item'),
    (10, 'Palo Alto White Blend', '750ml', 9.99, 7.99, 2, 172, 1374.28, 'New Item'),
    (11, 'Alberta Pure Vodka', '200ml', 7.49, 6.49, 1, 111, 720.39, NULL),
    (12, 'TASTINGS', NULL, NULL, NULL, NULL, NULL, NULL, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='brothers' AND p.period=DATE '2026-03-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('cobblestone', DATE '2026-03-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='cobblestone' AND period=DATE '2026-03-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'VIB Hop Tour', '8 CAN', 20.5, 18.5, 2, NULL, NULL, 'New Item'),
    (1, 'Hey Y''All', '12 CAN', 27.5, 25.5, 2, NULL, NULL, NULL),
    (2, 'Pabst Blue Ribbon', '15 CAN', 28.25, 25.75, 2.5, NULL, NULL, NULL),
    (3, 'Farm Hand Chardonnay', '750ML', 18.5, 16.5, 2, NULL, NULL, NULL),
    (4, 'Gato Nero Cab Sauv', '1.5L', 18.25, 16.25, 2, NULL, NULL, NULL),
    (5, 'Gordons Dry Gin', '1.14L', 38.75, 36.25, 2.5, NULL, NULL, NULL),
    (6, 'Captain Morgan', '1.75L', 67.75, 64.75, 3, NULL, NULL, NULL),
    (7, 'Wisers Special Blend', '1.14L', 36.75, 34.75, 2, NULL, NULL, NULL),
    (8, 'Smirnoff Vodka', '750ml', 28.25, 26.25, 2, NULL, NULL, NULL),
    (9, 'Rock Creek', '6 CAN', 14.75, 12.75, 2, NULL, NULL, NULL),
    (10, 'Cheap Thrills Mixer', '8 CAN', 18.25, 15.25, 3, NULL, NULL, 'D-Listed, Rep Paying $2 for every unit sold'),
    (11, '1800 Silver Reserva', '750ML', 46.25, 43.25, 3, NULL, NULL, NULL),
    (12, 'TASTINGS', NULL, NULL, NULL, NULL, NULL, NULL, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='cobblestone' AND p.period=DATE '2026-03-01';

-- ── Apr 2026 ─────────────────────────────────────────────

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('hideaway', DATE '2026-04-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='hideaway' AND period=DATE '2026-04-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'BIG ROCK MIXER', '15CAN', 31.25, 27.49, 3.75, 3, 82.47, NULL),
    (1, 'COORS ORIGINAL', '24CAN', 54.5, 48.99, 5.5, 48, 2351.52, NULL),
    (2, 'BUDWEISER', '24CAN', 51.75, 45.99, 5.75, 112, 5150.88, NULL),
    (3, 'WHITE PEAKS MIXER', '12CAN', 32, 23.99, 8, 13, 311.87, NULL),
    (4, 'SMIRNOFF ICE LIGHT MIXER', '12CAN', 30, 26.99, 3, 60, 1619.4, NULL),
    (5, 'SLAPPYS RANCH WATER & SOUR LEMONADE MIX', '12CAN', 28.25, 25.29, 3, 40, 1011.6, NULL),
    (6, 'NARRATIVE CAB FRANC & RED BLEND', '750ML', 24.25, 16.99, 7.25, 22, 373.78, 'RED BLEND NAME - NON FICTION'),
    (7, 'VIVO SAUV BLANC, CAB SAUV, PINOT NOIR', '750ML', 13.5, 10.79, 2.75, 40, 431.6, NULL),
    (8, 'VILA REGIA', '750ML', 10.75, 7.99, 2.75, 29, 231.71, NULL),
    (9, 'CANADA FIRST VODKA', '750ML', 24.75, 20.99, 3.75, 51, 1070.49, NULL),
    (10, '1800 COCONUT & JALAPENO CUKE', '750ML', 45.75, 42.79, 3, 14, 599.06, NULL),
    (11, 'ABSOLUT', '750ML', 30.5, 27.49, 3, 35, 962.15, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='hideaway' AND p.period=DATE '2026-04-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('downtown', DATE '2026-04-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='downtown' AND period=DATE '2026-04-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'BUSCH', '8CAN', 15.25, 11.99, 3.25, 55, 659.45, NULL),
    (1, 'CANADIAN', '15CAN', 34, 26.99, 7, 25, 674.75, NULL),
    (2, 'COORS ORIGINAL', '12CAN', 26.25, 21.99, 4.25, 21, 461.79, NULL),
    (3, 'SNEAKY WEASEL', '15CAN', 23, 20.99, 2, 31, 650.69, NULL),
    (4, 'SMIRNOFF ICE LIGHT MIXER', '12CAN', 30, 26.99, 3, 11, 296.89, NULL),
    (5, 'CANADIAN CLUB MIXER', '12CAN', 32, 28.99, 3, 2, 57.98, NULL),
    (6, 'COORS SELTZER SPLASH PACK', '12CAN', 33.25, 29.99, 3.25, 8, 239.92, NULL),
    (7, 'LAMARCA PROSECCO', '750ML', 25.75, 21.79, 4, 25, 544.75, NULL),
    (8, 'SANTA CAROLINA CAB MERLOT & SAUV BLANC', '1.5L', 18.25, 13.99, 4.25, 55, 769.45, NULL),
    (9, 'EMPRESS 1908 GIN', '750ML', 57.75, 50.99, 6.75, 0, NULL, NULL),
    (10, 'SUENOS BLANCO', '750ML', 69, 59.99, 9, 7, 419.93, NULL),
    (11, 'WISERS DELUXE', '750ML', 29.5, 26.49, 3, 7, 185.43, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='downtown' AND p.period=DATE '2026-04-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('brothers', DATE '2026-04-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='brothers' AND period=DATE '2026-04-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Suncruiser Classic Iced Tea', '12AR', 26.99, 24.49, 2.5, 13, 318.37, 'New'),
    (1, 'Truly Punch', '12AR', 31.99, 27.99, 4, 28, 783.72, NULL),
    (2, 'Larmarca Prosecco', '750ml', 25.99, 22.99, 3, 33, 758.67, NULL),
    (3, 'Ole Variety Pack', '8AR', 30.99, 27.99, 3, 24, 671.76, NULL),
    (4, 'Coors Original', '24AR', 50.49, 45.49, 5, 22, 1000.78, NULL),
    (5, 'Appleton Estate Rum', '750ml', 30.99, 27.99, 3, 13, 363.87, NULL),
    (6, '40 Creek Barrel Select', '750ml', 29.99, 27.49, 2.5, 6, 164.94, NULL),
    (7, 'Honest Lot 0g Sugar Pinot Grigio & Cabernet Sauvignon', '4L', 44.99, 39.99, 5, 9, 359.91, NULL),
    (8, 'Bodacious Smooth Red', '1.5L', 20.99, 17.99, 3, 11, 197.89, NULL),
    (9, 'Hendrick''s Gin', '375ml', 31.99, 28.99, 3, 1, 28.99, NULL),
    (10, 'Smirnoff Vodka', '1.75L', 58.99, 54.99, 4, 21, 1154.79, NULL),
    (11, 'Sleeman Clear', '15AR', 31.49, 27.99, 3.5, 52, 1455.48, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='brothers' AND p.period=DATE '2026-04-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('cobblestone', DATE '2026-04-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='cobblestone' AND period=DATE '2026-04-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Sleeman Clear', '15AR', 33.5, 30.5, 3, 55, 1670.5, NULL),
    (1, 'Strongbow', '4ar', 16.75, 14.75, 2, 60, 885, 'Traffic Driver'),
    (2, 'Intrigue Social Red', '750mL', 24.5, 22.5, 2, 5, 112.5, NULL),
    (3, 'Intrigue Social White', '750ml', 22, 20, 2, 0, NULL, NULL),
    (4, 'Cazadores Blanco', '750ml', 44, 41, 3, 3, 123, NULL),
    (5, 'Bali Watermelon', '4AR', 14.05, 12.05, 2, 36, 433.8, NULL),
    (6, 'Baileys', '1.14L', 43, 40.5, 2.5, 8, 324, NULL),
    (7, 'Alberta Pure Pet', '750mL', 25.5, 23.5, 2, 22, 517, NULL),
    (8, 'Phillips Jurassic Mix Pack', '8AR', 25, 23, 2, 12, 276, NULL),
    (9, 'Bearface Triple Oak', '750mL', 40, 36.75, 3.25, 4, 147, NULL),
    (10, 'Bumbu', '750ml', 59.75, 57.75, 2, 4, 231, NULL),
    (11, 'Empress 1908 Gin', '750mL', 57.75, 55, 2.75, 2, 110, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='cobblestone' AND p.period=DATE '2026-04-01';

-- ── May 2026 ─────────────────────────────────────────────

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('hideaway', DATE '2026-05-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='hideaway' AND period=DATE '2026-05-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'CARLSBERG', '12CAN', 26, 18.99, 7, 6, 113.94, NULL),
    (1, 'MOOSEHEAD & CRACKED CANOE', '15CAN', 32, 25.99, 6, 55, 1429.45, 'BONUS GLASSWARE'),
    (2, 'MILLER GENUINE DRAFT', '12BTL', 33.5, 24.99, 8.5, 69, 1724.31, 'ENTER TO WIN BBQ'),
    (3, 'VIB OUTPOST MIXER', '12CAN', 27, 22.99, 4, 23, 528.77, 'OUT THE DOOR UNDER $20'),
    (4, 'DUDE BEER', '6CAN', 9.75, 8.79, 1, 128, 1125.12, 'CHEAPEST 6 PACK IN STORE - $35.16 FOR A 24. DUDE RETURNS!'),
    (5, 'SPICEBOX CHOCOLATE WHISKY', '750ML', 30, 26.99, 3, 17, 458.83, 'WNTER TO WIN PATAGONIA SPRING JACKET'),
    (6, 'RYANS IRISH CREAM', '750ML', 25.5, 21.99, 3.5, 26, 571.74, NULL),
    (7, 'FIREBALL', '750ML', 26.25, 23.29, 3, 22, 512.38, NULL),
    (8, 'CLAUDE VAL ROSE', '750ML', 16.75, 12.79, 4, 16, 204.64, 'GREAT MOTHERS DAY ROSE FRENCH'),
    (9, 'KIM CRAWFORD SAUV BLANC', '750ML', 24, 18.99, 5, 72, 1367.28, NULL),
    (10, 'WYATT ROSE MIXER', '12CAN', 32.5, 29.49, 3, 45, 1327.05, NULL),
    (11, 'TWISTED TEA ALL 12 PACKS', '12CAN', 27.5, 22.49, 5, 259, 5824.91, 'BONUS HOCKEY SHOTGUN STICK (TWISTED TWIG)')
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='hideaway' AND p.period=DATE '2026-05-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('downtown', DATE '2026-05-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='downtown' AND period=DATE '2026-05-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'OLD MIL', '15CAN', 27.75, 25.79, 2, 25, 644.75, NULL),
    (1, 'CANADIAN', '24CAN', 51.75, 43.99, 7.75, 4, 175.96, NULL),
    (2, 'CORONA', '12PB', 33, 29.99, 3, 22, 659.78, NULL),
    (3, 'BALI WATER PARTY PACK', '8CAN', 27.75, 22.99, 4.75, 3, 68.97, NULL),
    (4, 'BLACK FLY GREEN MIXER', '12CAN', 32.5, 28.99, 3.5, NULL, NULL, NULL),
    (5, 'FINCA FLICHMAN ROSE', '750ML', 18, 13.99, 4, 3, 41.97, NULL),
    (6, 'VIVO CAB SAUV/SAUV BLANC', '750ML', 13.5, 10.79, 2.75, 7, 75.53, NULL),
    (7, 'VILA REGIA DUORO', '750ML', 9.75, 7.99, 1.75, 21, 167.79, NULL),
    (8, 'MONTE CREEK BLUEBERRY SPARKLING', '750ML', 25.75, 19.99, 5.75, 7, 139.93, NULL),
    (9, 'WHITE LIGHTNING', '750ML', 26, 23.99, 2, 6, 143.94, NULL),
    (10, 'CAPTAIN MORGAN SPICED', '750ML', 31.5, 28.99, 2.5, 4, 115.96, NULL),
    (11, 'TANQUERAY', '1.14L', 44, 40.99, 3, 2, 81.98, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='downtown' AND p.period=DATE '2026-05-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('brothers', DATE '2026-05-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='brothers' AND period=DATE '2026-05-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Ryan''s Irish Cream', '1.75L', 44.99, 39.99, 5, 20, 799.8, NULL),
    (1, '2 Hoots Iced Tea', '12AR', 30.99, 26.99, 4, 21, 566.79, NULL),
    (2, 'Cariboo Blonde', '6AR', 9.99, 8.49, 1.5, 130, 1103.7, NULL),
    (3, 'Select Peller Wines', '4L', 44.99, 40.99, 4, 13, 532.87, 'Rose, Chardonnay, Pinot Grigio, Cabernet Sauvignon'),
    (4, 'Whiteclaw Clawtails', '12AR', 35.99, 32.99, 3, 18, 593.82, 'New'),
    (5, 'Sheepdog Peanut Butter Whiskey', '750ml', 31.99, 28.99, 3, 0, NULL, 'Delayed delivery from LDB - never arrived'),
    (6, 'Matua Hawkes Bay Sauvignon Blanc', '750ml', 20.99, 17.99, 3, 13, 233.87, NULL),
    (7, 'Old Milwaukee', '24AR', 39.99, 36.99, 3, 143, 5289.57, NULL),
    (8, '1800 Coconut', '750ml', 46.49, 43.49, 3, 14, 608.86, NULL),
    (9, 'Stanley Park Concession Stand', '12AR', 26.99, 23.99, 3, 19, 455.81, NULL),
    (10, 'Grower''s Peach Cider', '6AR', 14.99, 12.99, 2, 26, 337.74, NULL),
    (11, 'Deer Island Long Island Iced Tea', '2L', 12.49, 9.49, 3, 0, NULL, 'Recalled product from LDB - never arrived')
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='brothers' AND p.period=DATE '2026-05-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('cobblestone', DATE '2026-05-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='cobblestone' AND period=DATE '2026-05-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Old Milwaukee', '24AR', 42, 39, 3, 10, 390, 'Enter to Win Truck Pad'),
    (1, 'Old Style Pilsner', '15AR', 27.75, 20.75, 7, 63, 1307.25, NULL),
    (2, 'Nutrl 7''s Berry Mix', '8AR', 23.25, 21.25, 2, 16, 340, NULL),
    (3, 'Okanagan Cider Variety Pk', '12AR', 28.5, 26.5, 2, 5, 132.5, NULL),
    (4, 'Uki', '8AR', 29.5, 26.5, 3, 6, 159, 'New giving away glasses'),
    (5, 'Cono Sur Organic Cabernet Sauv', '750ml', 19.5, 17.5, 2, 13, 227.5, NULL),
    (6, 'Kim Crawford Sauv Blanc', '750ml', 23.5, 21.5, 2, 16, 344, NULL),
    (7, '40 Creek Whisky', '750ml', 29.5, 27.5, 2, 6, 165, NULL),
    (8, 'Bombay', '1.14L', 45.25, 42.75, 2.5, 3, 128.25, NULL),
    (9, 'Canada First Vodka', '750ml', 24.25, 22, 2.25, 16, 352, NULL),
    (10, 'Strait and Narrow Cherry Lime', '4AR', 14.25, 12.25, 2, 15, 183.75, NULL),
    (11, 'Phillips Tropicoalda', '4AR', 17, 15, 2, 22, 330, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='cobblestone' AND p.period=DATE '2026-05-01';

-- ── Jun 2026 ─────────────────────────────────────────────

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('hideaway', DATE '2026-06-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='hideaway' AND period=DATE '2026-06-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'MOOSEHEAD RADLER', '12CAN', 30.5, 25.49, 5, 72, 1835.28, 'BONUS BELT BAG GWP'),
    (1, 'BUD LIGHT', '15CAN', 34, 28.99, 5, 125, 3623.75, NULL),
    (2, 'COORS ORIGINAL', '24CAN', 54.5, 43.99, 10.5, 79, 3475.21, NULL),
    (3, 'OLD MILWAUKEE', '15CAN', 27.752, 24.79, 3, 194, 4809.26, 'BONUS HAT!'),
    (4, 'SMIRNOFF ICE', '12CAN', 32.5, 26.99, 5.5, 87, 2348.13, NULL),
    (5, 'TRULY MIXERS ASSORTED', '12CAN', 32, 26.99, 5, 84, 2267.16, 'ALL 12 PACK OPTIONS ENTER TO WIN PADDLEBOARD'),
    (6, 'COORS SELTZER SLUSHIE', '24CAN', 55.75, 49.99, 5.75, 38, 1899.62, NULL),
    (7, 'BODACIOUS SMOOTH RED& WHITE', '4L', 46.75, 41.79, 5, 37, 1546.23, NULL),
    (8, 'VINTAGE INK RED&WHITE', '750ML', 18.75, 15.29, 3.5, 54, 825.66, NULL),
    (9, 'BAILEYS', '1.14L', 45.25, 41.29, 4, 44, 1816.76, NULL),
    (10, 'CAPTAIN SPICED', '1.14L', 46.25, 43.29, 3, 45, 1948.05, NULL),
    (11, 'BOMBAY SAPPHIRE', '1.14L', 45.25, 41.29, 4, 30, 1238.7, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='hideaway' AND p.period=DATE '2026-06-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('downtown', DATE '2026-06-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='downtown' AND period=DATE '2026-06-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'MOOSEHEAD RADLER', '12CAN', 30.5, 25.49, 5, 28, 713.72, 'BONUS BELT BAG GWP'),
    (1, 'MILLER LITE', '24CAN', 56, 43.99, 12, 6, 263.94, NULL),
    (2, 'OLD MILWAUKEE', '15CAN', 27.75, 24.79, 3, 52, 1289.08, NULL),
    (3, 'TRULY MIXERS ASSORTED', '12CAN', 32, 26.99, 5, 21, 566.79, 'ALL 12 PACK OPTIONS ENTER TO WIN PADDLEBOARD'),
    (4, 'TWISTED TEA ORIGINAL & HALF&HALF', '6CAN', 15.25, 12.49, 2.75, 50, 624.5, NULL),
    (5, 'STRONGBOW', '8CAN', 24.75, 21.79, 3, 18, 392.22, NULL),
    (6, 'BARTIER BROS PRISTINE SERIES', '750ML', 18.75, 13.79, 5, 21, 289.59, 'WHITE BLEND, ROSE, SAUV BLANC, PINOT GRIS,'),
    (7, 'SAINTLY RED & SAUV BLANC', '750ML', 20.75, 17.29, 3.5, 37, 639.73, 'SAINTLY BUCKET HAT GWP'),
    (8, 'BODACIOUS SMOOTH RED& WHITE', '4L', 46.75, 41.79, 5, 14, 585.06, NULL),
    (9, 'JOSE CUERVO SILVER', '1.14L', 58.75, 54.79, 4, 6, 328.74, NULL),
    (10, 'CROWN ROYAL', '750ML', 31.5, 28.49, 3, 12, 341.88, NULL),
    (11, 'TANQUERAY', '750ML', 44, 40.99, 3, 7, 286.93, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='downtown' AND p.period=DATE '2026-06-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('brothers', DATE '2026-06-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='brothers' AND period=DATE '2026-06-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Bailey''s Irish Cream', '1.14L', 44.99, 39.99, 5, 65, 2599.35, NULL),
    (1, 'Smirnoff Ice', '12AR', 31.49, 27.49, 4, 62, 1704.38, NULL),
    (2, 'Coors Light', '24AR', 49.99, 43.99, 6, 123, 5410.77, NULL),
    (3, 'Busch Light', '15AR', 27.49, 22.49, 5, 143, 3216.07, NULL),
    (4, '1800 Blanco Tequila', '750ML', 46.99, 41.99, 5, 22, 923.78, NULL),
    (5, 'Twisted Tea Original', '12AR', 27.49, 23.49, 4, 141, 3312.09, 'Cowboy hat with purchase'),
    (6, 'Kim Crawford Chardonnay', '750ML', 24.99, 17.99, 7, 21, 377.79, NULL),
    (7, 'Larch Hills Tamarack Rose', '750ML', 22.49, 19.49, 3, 20, 389.8, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='brothers' AND p.period=DATE '2026-06-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('cobblestone', DATE '2026-06-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='cobblestone' AND period=DATE '2026-06-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Phillips Boxset', '12AR', 26.5, 23.5, 3, 17, 399.5, 'Chance to win Backyard Weekender Package'),
    (1, 'VIB Westcoat IPA', '8AR', 17.25, 15.25, 2, 12, 183, 'Giving away a sleeping bag'),
    (2, 'Wyatt Rose Ranch Water', '12AR', 33.5, 31.5, 2, 20, 630, NULL),
    (3, 'Happy Dad', '12AR', 33.5, 31.5, 2, 13, 409.5, NULL),
    (4, 'White Claw Clawtails', '12AR', 35, 32, 3, 7, 224, NULL),
    (5, 'Stanley Park Sunsetter', '6AR', 15.5, 13.5, 2, 24, 324, NULL),
    (6, 'Hush White Blend', '750mL', 21, 19, 2, 0, NULL, NULL),
    (7, 'Carolans', '750mL', 31.5, 28.5, 3, 12, 342, NULL),
    (8, 'Norton Sauv Blanc', '750mL', 16, 13.5, 2.5, 21, 283.5, NULL),
    (9, 'Captain Morgan Spiced', '1.75L', 67.25, 64.25, 3, 2, 128.5, NULL),
    (10, 'Ravens Red', '750ml', 15, 13, 2, 7, 91, NULL),
    (11, 'Budweiser', '15AR', 32, 25, 7, 112, 2800, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='cobblestone' AND p.period=DATE '2026-06-01';

-- ── Jul 2026 ─────────────────────────────────────────────

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('hideaway', DATE '2026-07-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='hideaway' AND period=DATE '2026-07-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'HOOP ICED TEA', '6CAN', 12.75, 10.79, 2, 101, 1089.79, NULL),
    (1, 'DILLONS VODKA & GIN MIXERS', '12CAN', 33.5, 29.49, 4, 225, 6635.25, 'GWP DOGGY BANDANA'),
    (2, 'SMIRNOFF ICE LIGHT MIXER', '12CAN', 32.5, 27.49, 5, 138, 3793.62, NULL),
    (3, 'CORONA', '12BTL', 33.5, 27.99, 5.5, 238, 6661.62, NULL),
    (4, 'MT BEGBIE REVY LAGER', '12CAN', 26.5, 22.49, 4, 30, 674.7, NULL),
    (5, 'OLD STYLE PILSNER', '15CAN', 28.25, 19.99, 8.25, 329, 6576.71, NULL),
    (6, 'MEZZACORONA PINOT GRIGIO', '750ML', 21, 16.99, 4, 15, 254.85, NULL),
    (7, 'LOLEA FLORAL SPRITZ & LOLEA WHITE', '750ML', 19.5, 16.99, 2.5, 27, 458.73, 'ENTER TO WIN A LOLEA COOLER'),
    (8, 'CONO SUR ORGANICS', '750ML', 19.25, 15.29, 4, 57, 871.53, 'PINOT NOIR, CAB SAUV, SAUV BLANC, ROSE'),
    (9, 'WISER DELUXE', '1.14L', 42, 38.99, 3, 43, 1676.57, NULL),
    (10, 'MALIBU', '1.14L', 40, 34.99, 5, 48, 1679.52, NULL),
    (11, 'CUERVO EPECIAL GOLD & SILVER', '750ML', 40.5, 36.49, 4, 41, 1496.09, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='hideaway' AND p.period=DATE '2026-07-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('downtown', DATE '2026-07-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='downtown' AND period=DATE '2026-07-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'CANADA FIRST VODKA', '750ML', 24.75, 20.99, 3.75, NULL, NULL, 'CANADIAN MADE!'),
    (1, 'WISERS DELUXE', '1.14L', 42, 38.99, 3, NULL, NULL, NULL),
    (2, 'CPT MORGAN SPICED', '750ML', 31.5, 28.49, 3, NULL, NULL, NULL),
    (3, 'LAY LOW PINOT GRIGIO & ROSE', '750ML', 11.5, 8.99, 2.5, NULL, NULL, 'ENTER TO WIN $100 LULULEMON GIFT CARD'),
    (4, 'TOM GORE CAB SAUV', '750ML', 22.75, 19.79, 3, NULL, NULL, NULL),
    (5, 'COPPERMOON 0G GRAM SUGAR', '750ML', 13, 9.99, 3, NULL, NULL, 'PINOT GRIGIO & MALBEC - ENTER TO WIN BEATS EARBUDS'),
    (6, 'OLE DOUBLE SHOT LIME & PALOMA', '4CAN', 20.5, 17.49, 3, NULL, NULL, NULL),
    (7, 'WYATT ROSE LIME', '6CAN', 17.5, 14.99, 2.5, NULL, NULL, NULL),
    (8, 'COORS SELTZER MIXERS', '12CAN', 33.25, 29.99, 3.25, NULL, NULL, NULL),
    (9, 'CORONA', '12BTL', 33.5, 27.99, 5.5, NULL, NULL, NULL),
    (10, 'CANADIAN', '24CAN', 51.75, 39.99, 11.75, NULL, NULL, 'NEED TO MOVE HAD SINCE OCTOBER 2025'),
    (11, 'COORS LIGHT', '12CAN', 22.5, 16.49, 6, NULL, NULL, 'GIFT WITH PURCHASE - 3PK TAYLOR MADE GOLF BALLS')
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='downtown' AND p.period=DATE '2026-07-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('brothers', DATE '2026-07-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='brothers' AND period=DATE '2026-07-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Coors Light', '15AR', 32.99, 27.99, 5, 219, 6129.81, NULL),
    (1, 'Hell Yeah 7%', '12AR', 29.99, 26.99, 3, 25, 674.75, NULL),
    (2, 'Phillips Dino Sour', '8AR', 26.99, 23.99, 3, 78, 1871.22, NULL),
    (3, 'Lolea White Sangria', '750ml', 19.49, 17.49, 2, 17, 297.33, NULL),
    (4, 'El Jimador Margarita', '4AR', 14.99, 12.99, 2, 80, 1039.2, NULL),
    (5, 'Peller Sparkling Pinot Grigio', '750ml', 12.99, 10.99, 2, 35, 384.65, NULL),
    (6, 'Tom Gore Cabernet Sauvignon', '750ml', 23.99, 20.99, 3, 99, 2078.01, NULL),
    (7, 'Bombay Sapphire', '750ml', 31.49, 27.49, 4, 34, 934.66, 'Free San Pelligrino with purchase'),
    (8, 'Bacardi Superior White Rum', '1.14L', 36.99, 34.99, 2, 19, 664.81, NULL),
    (9, 'Strongbow Cider', '8AR', 25.99, 22.99, 3, 53, 1218.47, NULL),
    (10, 'Sawmill Creek Rose', '4L', 44.99, 39.99, 5, 4, 159.96, NULL),
    (11, 'Lucky Lager', '15AR', 27.99, 25.99, 2, 50, 1299.5, NULL)
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='brothers' AND p.period=DATE '2026-07-01';

INSERT INTO public.feature_periods (store_id, period, status)
VALUES ('cobblestone', DATE '2026-07-01', 'closed')
ON CONFLICT (store_id, period) DO NOTHING;

DELETE FROM public.features
 WHERE period_id = (SELECT id FROM public.feature_periods
                     WHERE store_id='cobblestone' AND period=DATE '2026-07-01');

INSERT INTO public.features
  (period_id, position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
SELECT p.id,
       v.position::int,        v.name::text,        v.size::text,
       v.reg_price::numeric,   v.sale_price::numeric, v.savings::numeric,
       v.qty_sold::int,        v.revenue::numeric,  v.notes::text
  FROM public.feature_periods p
  JOIN (VALUES
    (0, 'Molson Canadian', '15AR', 34, 28, 6, 6, 168, NULL),
    (1, 'Miller Lite', '15AR', 33, 28, 5, 42, 1176, NULL),
    (2, 'Corona', '12PB', 33.5, 29.5, 4, 83, 2448.5, NULL),
    (3, 'VIB Islander', '8AR', 18.25, 15.25, 3, 23, 350.75, NULL),
    (4, 'Simply Spiked  Lemonade', '12AR', 29.5, 27.5, 2, 6, 165, NULL),
    (5, 'Founders Gin Cocktail', '8AR', 28.25, 25.25, 3, 8, 202, NULL),
    (6, 'Strait and Narrow Adventure Pack', '12AR', 34.5, 32, 2.5, 4, 128, NULL),
    (7, 'Foothills Vodka', '750ml', 27.25, 25.25, 2, 12, 303, NULL),
    (8, 'Wisers Delux', '750ml', 29.5, 27.5, 2, 14, 385, NULL),
    (9, 'Sawmill Cab Sauv', '4L', 45, 41, 4, 0, NULL, NULL),
    (10, 'Sawmill Sauv Blanc', '4L', 43.75, 39.75, 4, 1, 39.75, NULL),
    (11, 'White Claw Mixer', '12AR', 33.5, 30.5, 3, 21, 640.5, NULL),
    (12, 'Product', NULL, NULL, NULL, NULL, NULL, NULL, 'NOTES'),
    (13, 'Kim Crawford Wine', '2026-07-03 00:00:00', 20000, 50000, NULL, NULL, NULL, 'Rep'),
    (14, 'Squish and Muddlers', '2026-07-10 00:00:00', 20000, 50000, NULL, NULL, NULL, 'Rep'),
    (15, 'Founders Espresso and Gin Cocktail', '2026-07-17 00:00:00', 20000, 50000, NULL, NULL, NULL, 'Rep'),
    (16, 'Pleaser Cocktail Mix', '2026-07-30 00:00:00', 40000, 70000, NULL, NULL, NULL, 'Rep/ Music in park, heavy traffic in store'),
    (17, 'Mikes Blue Raspberry', '2026-07-31 00:00:00', 20000, 60000, NULL, NULL, NULL, 'Third Party')
  ) AS v(position, name, size, reg_price, sale_price, savings, qty_sold, revenue, notes)
    ON p.store_id='cobblestone' AND p.period=DATE '2026-07-01';


-- Verify -----------------------------------------------------------------
-- SELECT p.period, p.store_id, count(f.id) AS rows,
--        count(f.qty_sold) AS with_qty, count(f.revenue) AS with_revenue
--   FROM public.feature_periods p
--   LEFT JOIN public.features f ON f.period_id = p.id
--  WHERE p.period < DATE '2026-08-01'
--  GROUP BY p.period, p.store_id ORDER BY p.period, p.store_id;

NOTIFY pgrst, 'reload schema';
