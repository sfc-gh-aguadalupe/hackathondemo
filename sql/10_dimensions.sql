-- =====================================================================
-- Lumora Value Loop demo — 10_data.sql   (dimensions)
--
-- DETERMINISM CONTRACT
--   No RANDOM(). Every pseudo-random value is derived from HASH() of the
--   business keys, which is a pure function — so the numbers are identical
--   on every rebuild and on every query during the demo, regardless of
--   warehouse size or query plan.
--
-- ALL DATA IS SYNTHETIC AND ILLUSTRATIVE.
-- =====================================================================

USE WAREHOUSE LUMORA_WH;
USE SCHEMA LUMORA_DEMO.CORE;

-- ---------------------------------------------------------------------
-- DIM_BRAND — 8 brands across 5 source systems.
-- source_system is preserved deliberately: the fragmentation must stay
-- visible in the data, because it is the problem the demo opens with.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE DIM_BRAND (
    brand_id        NUMBER,
    brand_name      VARCHAR,
    source_system   VARCHAR,
    home_region     VARCHAR,
    brand_scale     FLOAT,      -- relative revenue weight
    onboarded_year  NUMBER
) COMMENT = 'Synthetic brand dimension. 5 distinct source systems = 5 integration surfaces.';

INSERT INTO DIM_BRAND VALUES
    (1,'Aurelia',    'ERP_SAP_EU',        'DACH',          1.00, 2011),
    (2,'Nordwell',   'ERP_SAP_EU',        'DACH',          0.72, 2014),
    (3,'Solene',     'POS_LEGACY_NORDIC', 'NORDICS',       0.61, 2016),
    (4,'Cobalt & Co','ERP_ORACLE_UK',     'UK_IE',         0.85, 2009),
    (5,'Verdant',    'SHOPIFY_DTC',       'NORTH_AMERICA', 0.54, 2020),
    (6,'Halcyon',    'ERP_ORACLE_UK',     'UK_IE',         0.68, 2013),
    (7,'Mirabel',    'POS_LEGACY_NORDIC', 'NORDICS',       0.47, 2018),
    (8,'Kestrel',    'ERP_MS_DYNAMICS',   'NORTH_AMERICA', 0.59, 2017);

-- ---------------------------------------------------------------------
-- DIM_REGION — residency zone and sensitivity drive the governance story.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE DIM_REGION (
    region_code         VARCHAR,
    region_name         VARCHAR,
    data_residency_zone VARCHAR,
    is_eu               BOOLEAN,
    region_scale        FLOAT,
    currency            VARCHAR
) COMMENT = 'Synthetic region dimension with residency classification.';

INSERT INTO DIM_REGION VALUES
    ('DACH',         'Germany, Austria, Switzerland', 'EU_WEST',  TRUE,  1.00, 'EUR'),
    ('NORDICS',      'Nordics',                       'EU_NORTH', TRUE,  0.60, 'EUR'),
    ('UK_IE',        'United Kingdom & Ireland',      'UK',       FALSE, 0.80, 'GBP'),
    ('NORTH_AMERICA','North America',                 'US',       FALSE, 0.90, 'USD');

-- ---------------------------------------------------------------------
-- DIM_CATEGORY — unit economics live here so inventory value and markdown
-- exposure are computed from cost/price, never hard-coded.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE DIM_CATEGORY (
    category_code   VARCHAR,
    category_name   VARCHAR,
    base_units_day  NUMBER,
    unit_price      FLOAT,
    unit_cost       FLOAT,
    season_phase    FLOAT,      -- radians; shifts the seasonal peak
    season_amp      FLOAT
) COMMENT = 'Synthetic category dimension incl. illustrative unit economics.';

INSERT INTO DIM_CATEGORY VALUES
    -- SKINCARE amplitude kept low on purpose: it is the category carrying the
    -- planted break, and strong seasonality would mask the signal.
    ('SKINCARE',      'Skincare',            120, 42.00, 15.00, 0.4, 0.10),
    ('COSMETICS',     'Cosmetics',            90, 28.00,  9.00, 1.1, 0.22),
    ('HOME_TEXTILES', 'Home Textiles',        45, 65.00, 26.00, 3.4, 0.26),
    ('APPAREL_CORE',  'Apparel Core',         70, 55.00, 20.00, 2.6, 0.30),
    ('WELLNESS_SUPP', 'Wellness Supplements', 60, 34.00, 12.00, 0.2, 0.14),
    ('ACCESSORIES',   'Accessories',          55, 48.00, 18.00, 3.9, 0.20);

-- ---------------------------------------------------------------------
-- BRAND_CATEGORY — which brand sells which category.
-- SKINCARE is deliberately shared by Aurelia, Solene and Verdant: that
-- overlap is what lets Act 4 reveal a group-level pattern rather than a
-- single-brand problem.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE BRAND_CATEGORY (brand_id NUMBER, category_code VARCHAR);
INSERT INTO BRAND_CATEGORY VALUES
    (1,'SKINCARE'),(1,'COSMETICS'),(1,'WELLNESS_SUPP'),
    (2,'HOME_TEXTILES'),(2,'ACCESSORIES'),
    (3,'SKINCARE'),(3,'COSMETICS'),
    (4,'APPAREL_CORE'),(4,'ACCESSORIES'),
    (5,'WELLNESS_SUPP'),(5,'SKINCARE'),
    (6,'APPAREL_CORE'),(6,'HOME_TEXTILES'),
    (7,'ACCESSORIES'),(7,'COSMETICS'),
    (8,'APPAREL_CORE'),(8,'ACCESSORIES');

-- ---------------------------------------------------------------------
-- DIM_PRODUCT — ~120 SKUs derived from the brand/category map.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE DIM_PRODUCT AS
WITH n AS (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 7)))
SELECT
    ROW_NUMBER() OVER (ORDER BY bc.brand_id, bc.category_code, n.i) AS product_id,
    bc.brand_id,
    b.brand_name,
    bc.category_code,
    c.category_name || ' ' ||
        DECODE(n.i, 1,'Essential', 2,'Daily', 3,'Advanced', 4,'Limited',
                    5,'Refill', 6,'Gift Set', 7,'Travel')            AS product_name,
    -- price dispersion around the category anchor, deterministic per SKU
    ROUND(c.unit_price * (0.80 + 0.40 * (ABS(HASH(bc.brand_id, bc.category_code, n.i)) % 1000) / 1000.0), 2) AS unit_price,
    ROUND(c.unit_cost  * (0.85 + 0.30 * (ABS(HASH(bc.category_code, n.i, bc.brand_id)) % 1000) / 1000.0), 2) AS unit_cost,
    n.i AS variant_no
FROM BRAND_CATEGORY bc
JOIN DIM_BRAND    b ON b.brand_id = bc.brand_id
JOIN DIM_CATEGORY c ON c.category_code = bc.category_code
CROSS JOIN n;

-- ---------------------------------------------------------------------
-- DIM_CUSTOMER_IDENTITY — the cross-brand identity resolution story.
-- A customer_group_id is the governed identity; brand-local customer_id
-- is what each source system knows. ~22% of groups appear under more than
-- one brand, which is invisible in the source systems by construction.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE DIM_CUSTOMER_IDENTITY AS
WITH groups AS (
    SELECT SEQ4() + 1 AS customer_group_id
    FROM TABLE(GENERATOR(ROWCOUNT => 3000))
),
-- occurrence 1 for everyone; occurrence 2 for every 5th group; 3 for every 37th.
occurrences AS (
    SELECT customer_group_id, 1 AS occ FROM groups
    UNION ALL
    SELECT customer_group_id, 2 FROM groups WHERE MOD(customer_group_id, 5) = 0
    UNION ALL
    SELECT customer_group_id, 3 FROM groups WHERE MOD(customer_group_id, 37) = 0
)
SELECT
    ROW_NUMBER() OVER (ORDER BY o.customer_group_id, o.occ)                    AS identity_id,
    o.customer_group_id,
    -- each occurrence lands on a different brand, so the group spans brands
    1 + MOD(ABS(HASH(o.customer_group_id)) + (o.occ - 1) * 3, 8)               AS brand_id,
    'C' || LPAD(TO_VARCHAR(o.customer_group_id), 6, '0') || '-' || o.occ       AS source_customer_id,
    r.region_code,
    r.data_residency_zone,
    CASE WHEN r.is_eu THEN 'RESTRICTED_PII' ELSE 'STANDARD_PII' END            AS sensitivity_class,
    o.occ                                                                       AS occurrence_no
FROM occurrences o
JOIN DIM_REGION r
  ON r.region_code = DECODE(MOD(ABS(HASH(o.customer_group_id, 'reg')), 4),
                            0,'DACH', 1,'NORDICS', 2,'UK_IE', 3,'NORTH_AMERICA');

-- ---------------------------------------------------------------------
-- Sanity output
-- ---------------------------------------------------------------------
SELECT 'DIM_BRAND' AS table_name, COUNT(*) AS row_count FROM DIM_BRAND
UNION ALL SELECT 'DIM_REGION',   COUNT(*) FROM DIM_REGION
UNION ALL SELECT 'DIM_CATEGORY', COUNT(*) FROM DIM_CATEGORY
UNION ALL SELECT 'DIM_PRODUCT',  COUNT(*) FROM DIM_PRODUCT
UNION ALL SELECT 'DIM_CUSTOMER_IDENTITY', COUNT(*) FROM DIM_CUSTOMER_IDENTITY
UNION ALL SELECT 'cross-brand groups', COUNT(*) FROM (
    SELECT customer_group_id FROM DIM_CUSTOMER_IDENTITY
    GROUP BY 1 HAVING COUNT(DISTINCT brand_id) > 1);
