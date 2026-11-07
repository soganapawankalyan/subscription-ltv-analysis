-- ============================================================
-- 01_profile_validate.sql  |  Project 4D
-- Goal: understand the data, then prove it can be trusted BEFORE
-- analysing it. Validation checks should return 0 rows or 0.
--
-- WRITE DOWN YOUR DEFINITIONS (put them in your README):
--   * Subscribed = has a billed row that month (active OR paused).
--   * Churn      = a 'cancel' event. A paused customer is NOT churned.
--   * MRR        = the 'mrr' column (what was billed that month; $0 when paused).
--   * Gross margin is not in the data. Pick one (this project uses 70%) and state it.
-- ============================================================

-- 1.1 Table sizes
SELECT 'customers' AS tbl, COUNT(*) AS n FROM customers
UNION ALL SELECT 'subscription_months', COUNT(*) FROM subscription_months
UNION ALL SELECT 'events', COUNT(*) FROM events
UNION ALL SELECT 'marketing_spend', COUNT(*) FROM marketing_spend;

-- 1.2 Date coverage
SELECT MIN(month) AS first_month, MAX(month) AS last_month, COUNT(DISTINCT month) AS months
FROM subscription_months;

-- 1.3 Customers by acquisition channel and signup plan
SELECT channel, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM customers), 1) AS pct,
       SUM(CASE WHEN signup_plan = 'Basic'    THEN 1 ELSE 0 END) AS basic,
       SUM(CASE WHEN signup_plan = 'Standard' THEN 1 ELSE 0 END) AS standard,
       SUM(CASE WHEN signup_plan = 'Premium'  THEN 1 ELSE 0 END) AS premium,
       ROUND(100.0 * SUM(promo_signup) / COUNT(*), 1) AS promo_pct
FROM customers
GROUP BY channel
ORDER BY customers DESC;

-- 1.4 Channel mix by signup year (does the mix change over time?)
SELECT SUBSTR(signup_month, 1, 4) AS signup_year, channel, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY SUBSTR(signup_month, 1, 4)), 1) AS pct_of_year
FROM customers
GROUP BY signup_year, channel
ORDER BY signup_year, customers DESC;

-- 1.5 Event types
SELECT event_type, COUNT(*) AS events FROM events GROUP BY event_type ORDER BY events DESC;

-- 1.6 Row status and price points
SELECT status, plan, COUNT(*) AS rows_, ROUND(MIN(mrr), 2) AS min_mrr, ROUND(MAX(mrr), 2) AS max_mrr
FROM subscription_months
GROUP BY status, plan
ORDER BY status, plan;

-- ---------- VALIDATION (each should return 0) ----------

-- 1.7 Duplicate customer-months
SELECT COUNT(*) AS duplicate_customer_months FROM (
    SELECT customer_id, month FROM subscription_months GROUP BY 1, 2 HAVING COUNT(*) > 1);

-- 1.8 Customers without exactly one signup event
SELECT COUNT(*) AS customers_without_one_signup FROM (
    SELECT c.customer_id FROM customers c
    LEFT JOIN events e ON e.customer_id = c.customer_id AND e.event_type = 'signup'
    GROUP BY c.customer_id HAVING COUNT(e.event_id) <> 1);

-- 1.9 Customers with more than one cancel
SELECT COUNT(*) AS customers_with_multiple_cancels FROM (
    SELECT customer_id FROM events WHERE event_type = 'cancel' GROUP BY 1 HAVING COUNT(*) > 1);

-- 1.10 Billed on or after the cancel month
SELECT COUNT(*) AS billed_after_cancel
FROM subscription_months s
JOIN events e ON e.customer_id = s.customer_id AND e.event_type = 'cancel'
WHERE s.month >= e.event_month;

-- 1.11 First billed month differs from signup month
SELECT COUNT(*) AS first_bill_not_signup_month FROM (
    SELECT s.customer_id, MIN(s.month) AS first_m FROM subscription_months s GROUP BY 1) x
JOIN customers c ON c.customer_id = x.customer_id
WHERE x.first_m <> c.signup_month;

-- 1.12 Gaps in a customer's billing history (rows should equal max tenure)
SELECT COUNT(*) AS customers_with_gaps FROM (
    SELECT customer_id, COUNT(*) AS n, MAX(tenure_month) AS mt FROM subscription_months GROUP BY 1)
WHERE n <> mt;

-- 1.13 Revenue logic: paused rows should bill $0, active rows should bill more than $0
SELECT
    SUM(CASE WHEN status = 'paused' AND mrr <> 0 THEN 1 ELSE 0 END) AS paused_but_billed,
    SUM(CASE WHEN status = 'active' AND mrr <= 0 THEN 1 ELSE 0 END) AS active_but_not_billed
FROM subscription_months;

-- 1.14 Marketing spend covers every channel-month (should be 36 months x 5 channels = 180)
SELECT COUNT(*) AS channel_months, COUNT(DISTINCT month) AS months, COUNT(DISTINCT channel) AS channels
FROM marketing_spend;

-- 1.15 Customers per channel-month that have no spend row (should be 0)
SELECT COUNT(*) AS signup_channel_months_without_spend FROM (
    SELECT DISTINCT signup_month AS m, channel FROM customers) x
LEFT JOIN marketing_spend s ON s.month = x.m AND s.channel = x.channel
WHERE s.month IS NULL;
