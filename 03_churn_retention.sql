-- ============================================================
-- 03_churn_retention.sql  |  Project 4D
-- Questions: How fast do customers leave, when, and how do cohorts hold up?
-- Skills: churn rates, hazard by tenure, cohort tables, handling censoring.
-- Requires 00_views.sql.
--
-- CENSORING WARNING: the data stops at the last month, so recent signups have
-- not had time to churn. Never average lifetimes of everyone. Compare only
-- customers who could have been observed for the full period (the "eligible"
-- columns below do exactly that).
-- ============================================================

-- 3.1 Monthly logo churn: customers cancelling / customers subscribed the month before
WITH base AS (
    SELECT midx, month, COUNT(*) AS subscribed FROM v_sm GROUP BY midx, month
),
canc AS (
    SELECT event_month AS month, COUNT(*) AS cancels FROM events WHERE event_type = 'cancel' GROUP BY 1
)
SELECT
    b.month,
    p.subscribed                              AS start_of_month,
    COALESCE(c.cancels, 0)                    AS cancels,
    ROUND(100.0 * COALESCE(c.cancels, 0) / p.subscribed, 2) AS logo_churn_pct
FROM base b
JOIN base p ON p.midx = b.midx - 1
LEFT JOIN canc c ON c.month = b.month
ORDER BY b.month;

-- 3.2 Blended churn by calendar year (note this mixes channels, plans and tenures)
WITH base AS (SELECT midx, month, COUNT(*) AS subscribed FROM v_sm GROUP BY midx, month),
canc AS (SELECT event_month AS month, COUNT(*) AS cancels FROM events WHERE event_type = 'cancel' GROUP BY 1)
SELECT
    SUBSTR(b.month, 1, 4)                     AS yr,
    SUM(COALESCE(c.cancels, 0))               AS cancels,
    SUM(p.subscribed)                         AS customer_months_at_risk,
    ROUND(100.0 * SUM(COALESCE(c.cancels, 0)) / SUM(p.subscribed), 2) AS monthly_churn_pct
FROM base b
JOIN base p ON p.midx = b.midx - 1
LEFT JOIN canc c ON c.month = b.month
GROUP BY yr
ORDER BY yr;

-- 3.3 Churn by tenure: probability of cancelling in tenure month k, given present at k-1
--     (shows when customers are most likely to leave)
WITH at_risk AS (
    SELECT tenure_month + 1 AS k, COUNT(*) AS n
    FROM v_sm
    WHERE midx < (SELECT MAX(midx) FROM v_sm)      -- last month's rows have no "next month" yet
    GROUP BY tenure_month
),
canc AS (
    SELECT tenure_month AS k, COUNT(*) AS cancels FROM events WHERE event_type = 'cancel' GROUP BY 1
)
SELECT a.k AS tenure_month, a.n AS at_risk, COALESCE(c.cancels, 0) AS cancels,
       ROUND(100.0 * COALESCE(c.cancels, 0) / a.n, 2) AS churn_pct
FROM at_risk a
LEFT JOIN canc c ON c.k = a.k
WHERE a.k BETWEEN 2 AND 24
ORDER BY a.k;

-- 3.4 Cohort retention by signup quarter.
--     retained_k = share still subscribed k months after signup (present at tenure k+1).
--     A customer counts only for a column if they could have been observed that long.
WITH cust AS (
    SELECT c.customer_id,
           SUBSTR(c.signup_month, 1, 4) || '-Q' || ((CAST(SUBSTR(c.signup_month, 6, 2) AS INTEGER) + 2) / 3) AS cohort,
           c.signup_midx,
           MAX(s.tenure_month) AS max_ten
    FROM v_c c JOIN v_sm s ON s.customer_id = c.customer_id
    GROUP BY c.customer_id
),
mx AS (SELECT MAX(midx) AS m FROM v_sm)
SELECT
    cohort,
    COUNT(*) AS customers,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 3  <= m AND max_ten >= 4  THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 3  <= m THEN 1 END), 0), 1) AS retained_3m,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 6  <= m AND max_ten >= 7  THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 6  <= m THEN 1 END), 0), 1) AS retained_6m,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 12 <= m AND max_ten >= 13 THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 12 <= m THEN 1 END), 0), 1) AS retained_12m,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 24 <= m AND max_ten >= 25 THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 24 <= m THEN 1 END), 0), 1) AS retained_24m
FROM cust, mx
GROUP BY cohort
ORDER BY cohort;

-- 3.5 Retention (survival) by acquisition channel, same eligibility rule
WITH cust AS (
    SELECT c.customer_id, c.channel, c.signup_midx, MAX(s.tenure_month) AS max_ten
    FROM v_c c JOIN v_sm s ON s.customer_id = c.customer_id
    GROUP BY c.customer_id
),
mx AS (SELECT MAX(midx) AS m FROM v_sm)
SELECT
    channel,
    COUNT(*) AS customers,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 3  <= m AND max_ten >= 4  THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 3  <= m THEN 1 END), 0), 1) AS retained_3m,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 6  <= m AND max_ten >= 7  THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 6  <= m THEN 1 END), 0), 1) AS retained_6m,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 12 <= m AND max_ten >= 13 THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 12 <= m THEN 1 END), 0), 1) AS retained_12m,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 24 <= m AND max_ten >= 25 THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 24 <= m THEN 1 END), 0), 1) AS retained_24m
FROM cust, mx
GROUP BY channel
ORDER BY retained_12m DESC;

-- 3.6 Retention by signup plan (the plan the customer started on)
WITH cust AS (
    SELECT c.customer_id, c.signup_plan, c.signup_midx, MAX(s.tenure_month) AS max_ten
    FROM v_c c JOIN v_sm s ON s.customer_id = c.customer_id
    GROUP BY c.customer_id
),
mx AS (SELECT MAX(midx) AS m FROM v_sm)
SELECT
    signup_plan,
    COUNT(*) AS customers,
    ROUND(100.0 * SUM(CASE WHEN signup_midx + 12 <= m AND max_ten >= 13 THEN 1 END) / NULLIF(SUM(CASE WHEN signup_midx + 12 <= m THEN 1 END), 0), 1) AS retained_12m
FROM cust, mx
GROUP BY signup_plan
ORDER BY retained_12m DESC;
