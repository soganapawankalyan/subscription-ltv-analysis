-- ============================================================
-- 00_views.sql  |  Project 4D: Subscription revenue and LTV
-- Helper views reused by every later file. Safe to re-run.
-- Months are stored as text 'YYYY-MM-01'. "midx" turns a month into a
-- whole number (year*12 + month) so "previous month" is simply midx - 1.
-- ============================================================

DROP VIEW IF EXISTS v_sm;
CREATE VIEW v_sm AS            -- one row per customer per billed month, with customer attributes
SELECT
    s.customer_id,
    s.month,
    CAST(SUBSTR(s.month, 1, 4) AS INTEGER) * 12 + CAST(SUBSTR(s.month, 6, 2) AS INTEGER) AS midx,
    s.plan,
    s.status,                  -- 'active' or 'paused'
    s.mrr,
    s.tenure_month,            -- 1 in the signup month
    c.channel,
    c.country,
    c.device,
    c.signup_plan,
    c.promo_signup,
    c.signup_month
FROM subscription_months s
JOIN customers c ON c.customer_id = s.customer_id;

DROP VIEW IF EXISTS v_c;
CREATE VIEW v_c AS            -- customers with a numeric signup month
SELECT
    customer_id, channel, country, device, signup_plan, promo_signup, signup_month,
    CAST(SUBSTR(signup_month, 1, 4) AS INTEGER) * 12 + CAST(SUBSTR(signup_month, 6, 2) AS INTEGER) AS signup_midx
FROM customers;

DROP VIEW IF EXISTS v_spend;
CREATE VIEW v_spend AS
SELECT
    month, channel, spend_usd,
    CAST(SUBSTR(month, 1, 4) AS INTEGER) * 12 + CAST(SUBSTR(month, 6, 2) AS INTEGER) AS midx
FROM marketing_spend;

-- Smoke test: all three views return rows
SELECT 'v_sm' AS view_name, COUNT(*) AS row_count FROM v_sm
UNION ALL SELECT 'v_c', COUNT(*) FROM v_c
UNION ALL SELECT 'v_spend', COUNT(*) FROM v_spend;
