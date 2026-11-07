-- ============================================================
-- 04_ltv_cac.sql  |  Project 4D
-- Questions: What does a customer cost to acquire (CAC) and earn (LTV) by
--            channel, and how long until each channel pays back?
-- Skills: joins across spend and billing, cohort eligibility, cumulative
--         window sums, payback. Requires 00_views.sql.
--
-- CHANGE THE MARGIN BELOW to your own assumption (0.70 = 70% gross margin).
-- CAUTION about "organic": almost no tracked spend, so its CAC looks tiny.
--   That is a tracking gap, not proof that organic customers are free.
-- LTV here is gross-profit LTV over a fixed window (12 or 24 months), using
--   only signups that could be observed for the whole window (no censoring).
-- ============================================================

-- 4.1 CAC by channel: total spend / customers acquired (all months)
WITH spend AS (SELECT channel, SUM(spend_usd) AS total_spend FROM marketing_spend GROUP BY channel),
     acquired AS (SELECT channel, COUNT(*) AS customers_acquired FROM customers GROUP BY channel)
SELECT
    s.channel,
    ROUND(s.total_spend, 0)                       AS total_spend,
    a.customers_acquired,
    ROUND(s.total_spend / a.customers_acquired, 2) AS cac
FROM spend s JOIN acquired a ON a.channel = s.channel
ORDER BY cac DESC;

-- 4.2 CAC trend by year (is acquisition getting more expensive?)
WITH s AS (
    SELECT SUBSTR(month, 1, 4) AS yr, channel, SUM(spend_usd) AS spend FROM marketing_spend GROUP BY 1, 2
),
n AS (
    SELECT SUBSTR(signup_month, 1, 4) AS yr, channel, COUNT(*) AS new_customers FROM customers GROUP BY 1, 2
)
SELECT s.channel, s.yr, n.new_customers, ROUND(s.spend / n.new_customers, 2) AS cac
FROM s JOIN n ON n.yr = s.yr AND n.channel = s.channel
ORDER BY s.channel, s.yr;

-- 4.3 LTV and LTV:CAC by channel, 12-month and 24-month windows.
WITH params AS (SELECT 0.70 AS gm, (SELECT MAX(midx) FROM v_sm) AS maxm),
rev AS (
    SELECT customer_id,
           SUM(CASE WHEN tenure_month <= 12 THEN mrr ELSE 0 END) AS rev12,
           SUM(CASE WHEN tenure_month <= 24 THEN mrr ELSE 0 END) AS rev24
    FROM v_sm GROUP BY customer_id
),
cust_h AS (
    SELECT 12 AS h, c.channel, COUNT(*) AS n, SUM(r.rev12) AS rev
    FROM v_c c JOIN rev r ON r.customer_id = c.customer_id, params
    WHERE c.signup_midx <= maxm - 11 GROUP BY c.channel
    UNION ALL
    SELECT 24, c.channel, COUNT(*), SUM(r.rev24)
    FROM v_c c JOIN rev r ON r.customer_id = c.customer_id, params
    WHERE c.signup_midx <= maxm - 23 GROUP BY c.channel
),
spend_h AS (
    SELECT 12 AS h, channel, SUM(spend_usd) AS spend FROM v_spend, params WHERE midx <= maxm - 11 GROUP BY channel
    UNION ALL
    SELECT 24, channel, SUM(spend_usd) FROM v_spend, params WHERE midx <= maxm - 23 GROUP BY channel
)
SELECT
    ch.h                                         AS window_months,
    ch.channel,
    ch.n                                         AS signups_in_window,
    ROUND(sp.spend / ch.n, 2)                    AS cac,
    ROUND(ch.rev / ch.n, 2)                      AS revenue_per_signup,
    ROUND(ch.rev / ch.n * gm, 2)                 AS gross_profit_ltv,
    ROUND((ch.rev / ch.n * gm) / (sp.spend / ch.n), 2) AS ltv_to_cac
FROM cust_h ch
JOIN spend_h sp ON sp.h = ch.h AND sp.channel = ch.channel, params
ORDER BY ch.h, ltv_to_cac DESC;

-- 4.4 CAC payback: first month in which cumulative gross profit per signup
--     covers CAC (cohorts observed for 24 months). NULL = not within 24 months.
WITH params AS (SELECT 0.70 AS gm, (SELECT MAX(midx) FROM v_sm) AS maxm),
elig AS (SELECT customer_id, channel FROM v_c, params WHERE signup_midx <= maxm - 23),
n AS (SELECT channel, COUNT(*) AS n FROM elig GROUP BY channel),
per_k AS (
    SELECT e.channel, s.tenure_month AS k, SUM(s.mrr) AS rev
    FROM v_sm s JOIN elig e ON e.customer_id = s.customer_id
    WHERE s.tenure_month <= 24 GROUP BY e.channel, s.tenure_month
),
cum AS (
    SELECT p.channel, p.k,
           SUM(p.rev) OVER (PARTITION BY p.channel ORDER BY p.k) * gm / n.n AS cum_gp
    FROM per_k p JOIN n ON n.channel = p.channel, params
),
cac AS (
    SELECT sp.channel, SUM(sp.spend_usd) / n.n AS cac
    FROM v_spend sp JOIN n ON n.channel = sp.channel, params
    WHERE sp.midx <= maxm - 23 GROUP BY sp.channel
)
SELECT
    cac.channel,
    ROUND(cac.cac, 2)                                             AS cac,
    MIN(CASE WHEN cum.cum_gp >= cac.cac THEN cum.k END)           AS payback_month,
    ROUND(MAX(CASE WHEN cum.k = 12 THEN cum.cum_gp END), 2)       AS gp_per_signup_12m,
    ROUND(MAX(CASE WHEN cum.k = 24 THEN cum.cum_gp END), 2)       AS gp_per_signup_24m
FROM cac JOIN cum ON cum.channel = cac.channel
GROUP BY cac.channel
ORDER BY gp_per_signup_24m / cac.cac DESC;

-- 4.5 Cumulative gross profit per signup by tenure month (feeds the payback chart)
WITH params AS (SELECT 0.70 AS gm, (SELECT MAX(midx) FROM v_sm) AS maxm),
elig AS (SELECT customer_id, channel FROM v_c, params WHERE signup_midx <= maxm - 23),
n AS (SELECT channel, COUNT(*) AS n FROM elig GROUP BY channel),
per_k AS (
    SELECT e.channel, s.tenure_month AS k, SUM(s.mrr) AS rev
    FROM v_sm s JOIN elig e ON e.customer_id = s.customer_id
    WHERE s.tenure_month <= 24 GROUP BY e.channel, s.tenure_month
)
SELECT p.channel, p.k AS tenure_month,
       ROUND(SUM(p.rev) OVER (PARTITION BY p.channel ORDER BY p.k) * gm / n.n, 2) AS cum_gross_profit_per_signup
FROM per_k p JOIN n ON n.channel = p.channel, params
WHERE p.k IN (1, 3, 6, 9, 12, 18, 24)
ORDER BY p.channel, p.k;
