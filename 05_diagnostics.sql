-- ============================================================
-- 05_diagnostics.sql  |  Project 4D
-- Questions: Is blended churn really improving? What happens when a promo ends?
--            Did the 2025 Standard price rise pay off? Do early upgraders stay?
-- Skills: mix-adjusted (standardized) rates, hazard comparison, before/after
--         analysis, avoiding immortal-time bias. Requires 00_views.sql.
-- ============================================================

-- 5.1 Churn by year and channel: customers at risk and cancels per channel
--     (the building block for 5.2)
WITH at_risk AS (
    SELECT SUBSTR(DATE(month, '+1 month'), 1, 4) AS yr, channel, COUNT(*) AS n
    FROM v_sm
    WHERE midx < (SELECT MAX(midx) FROM v_sm)
    GROUP BY 1, 2
),
canc AS (
    SELECT SUBSTR(e.event_month, 1, 4) AS yr, c.channel, COUNT(*) AS cancels
    FROM events e JOIN customers c ON c.customer_id = e.customer_id
    WHERE e.event_type = 'cancel' AND e.event_month > (SELECT MIN(month) FROM subscription_months)
    GROUP BY 1, 2
)
SELECT a.yr, a.channel, a.n AS customer_months, COALESCE(c.cancels, 0) AS cancels,
       ROUND(100.0 * COALESCE(c.cancels, 0) / a.n, 2) AS churn_pct,
       ROUND(100.0 * a.n / SUM(a.n) OVER (PARTITION BY a.yr), 1) AS share_of_customer_months
FROM at_risk a LEFT JOIN canc c ON c.yr = a.yr AND c.channel = a.channel
ORDER BY a.yr, a.channel;

-- 5.2 Blended vs mix-adjusted churn.
--     "Mix-adjusted" applies EVERY year's channel churn rates to the 2023 channel mix,
--     so any improvement left is real behaviour, not the customer mix shifting.
WITH at_risk AS (
    SELECT SUBSTR(DATE(month, '+1 month'), 1, 4) AS yr, channel, COUNT(*) AS n
    FROM v_sm WHERE midx < (SELECT MAX(midx) FROM v_sm) GROUP BY 1, 2
),
canc AS (
    SELECT SUBSTR(e.event_month, 1, 4) AS yr, c.channel, COUNT(*) AS cancels
    FROM events e JOIN customers c ON c.customer_id = e.customer_id
    WHERE e.event_type = 'cancel' AND e.event_month > (SELECT MIN(month) FROM subscription_months)
    GROUP BY 1, 2
),
rates AS (
    SELECT a.yr, a.channel, a.n, 1.0 * COALESCE(c.cancels, 0) / a.n AS rate
    FROM at_risk a LEFT JOIN canc c ON c.yr = a.yr AND c.channel = a.channel
),
w2023 AS (SELECT channel, 1.0 * n / SUM(n) OVER () AS w FROM rates WHERE yr = '2023')
SELECT
    r.yr,
    ROUND(100.0 * SUM(r.rate * r.n) / SUM(r.n), 2)  AS blended_churn_pct,
    ROUND(100.0 * SUM(r.rate * w.w), 2)             AS churn_pct_at_2023_mix
FROM rates r JOIN w2023 w ON w.channel = r.channel
GROUP BY r.yr
ORDER BY r.yr;

-- 5.3 The promo cliff: churn by tenure for promo vs non-promo signups
WITH at_risk AS (
    SELECT promo_signup, tenure_month + 1 AS k, COUNT(*) AS n
    FROM v_sm WHERE midx < (SELECT MAX(midx) FROM v_sm) GROUP BY 1, 2
),
canc AS (
    SELECT c.promo_signup, e.tenure_month AS k, COUNT(*) AS cancels
    FROM events e JOIN customers c ON c.customer_id = e.customer_id
    WHERE e.event_type = 'cancel' GROUP BY 1, 2
)
SELECT a.k AS tenure_month,
       ROUND(100.0 * SUM(CASE WHEN a.promo_signup = 1 THEN COALESCE(c.cancels, 0) END) / SUM(CASE WHEN a.promo_signup = 1 THEN a.n END), 2) AS promo_churn_pct,
       ROUND(100.0 * SUM(CASE WHEN a.promo_signup = 0 THEN COALESCE(c.cancels, 0) END) / SUM(CASE WHEN a.promo_signup = 0 THEN a.n END), 2) AS non_promo_churn_pct
FROM at_risk a LEFT JOIN canc c ON c.promo_signup = a.promo_signup AND c.k = a.k
WHERE a.k BETWEEN 2 AND 9
GROUP BY a.k
ORDER BY a.k;

-- 5.4 12-month retention of promo vs non-promo signups (eligible cohorts only)
WITH cust AS (
    SELECT c.customer_id, c.promo_signup, c.signup_midx, MAX(s.tenure_month) AS max_ten
    FROM v_c c JOIN v_sm s ON s.customer_id = c.customer_id GROUP BY c.customer_id
), mx AS (SELECT MAX(midx) AS m FROM v_sm)
SELECT promo_signup,
       COUNT(*) AS customers,
       ROUND(100.0 * SUM(CASE WHEN signup_midx + 12 <= m AND max_ten >= 13 THEN 1 END) / SUM(CASE WHEN signup_midx + 12 <= m THEN 1 END), 1) AS retained_12m
FROM cust, mx GROUP BY promo_signup;

-- 5.5 The Standard price rise (Mar 2025): monthly Standard churn, downgrades and revenue
WITH std_at_risk AS (
    SELECT DATE(month, '+1 month') AS month, COUNT(*) AS std_customers_prev
    FROM v_sm WHERE plan = 'Standard' AND midx < (SELECT MAX(midx) FROM v_sm) GROUP BY 1
),
std_events AS (
    SELECT event_month AS month,
           SUM(CASE WHEN event_type = 'cancel'    AND from_plan = 'Standard' THEN 1 ELSE 0 END) AS cancels,
           SUM(CASE WHEN event_type = 'downgrade' AND from_plan = 'Standard' THEN 1 ELSE 0 END) AS downgrades
    FROM events GROUP BY event_month
),
std_mrr AS (
    SELECT month, SUM(mrr) AS std_mrr, COUNT(*) AS std_subscribed FROM v_sm WHERE plan = 'Standard' GROUP BY month
)
SELECT r.month,
       r.std_customers_prev,
       e.cancels,
       ROUND(100.0 * e.cancels / r.std_customers_prev, 2)    AS std_churn_pct,
       ROUND(100.0 * e.downgrades / r.std_customers_prev, 2) AS std_downgrade_pct,
       ROUND(m.std_mrr, 0)                                   AS std_mrr
FROM std_at_risk r
JOIN std_events e ON e.month = r.month
JOIN std_mrr m ON m.month = r.month
WHERE r.month BETWEEN '2024-09-01' AND '2025-08-01'
ORDER BY r.month;

-- 5.6 Did the price rise pay off? Two halves, shown side by side.
--     GAIN: Standard MRR in the 3 months after the rise, minus the same subscribers at the
--           old $13.99 (promo months at half price). This ignores who left.
--     COST: Standard cancels above the pre-rise baseline rate (Sep 2024 - Feb 2025), valued
--           at the new price per month. Those customers are gone from every later month too.
--     A rough, transparent estimate: state its limits (no control group; some leavers would
--     have left anyway; promo discounts simplified).
WITH std_at_risk AS (
    SELECT DATE(month, '+1 month') AS month, COUNT(*) AS n
    FROM v_sm WHERE plan = 'Standard' AND midx < (SELECT MAX(midx) FROM v_sm) GROUP BY 1
),
std_cancels AS (
    SELECT event_month AS month, COUNT(*) AS cancels
    FROM events WHERE event_type = 'cancel' AND from_plan = 'Standard' GROUP BY 1
),
baseline AS (
    SELECT 1.0 * SUM(c.cancels) / SUM(r.n) AS rate
    FROM std_at_risk r JOIN std_cancels c ON c.month = r.month
    WHERE r.month BETWEEN '2024-09-01' AND '2025-02-01'
),
post AS (
    SELECT SUM(r.n) AS at_risk, SUM(c.cancels) AS cancels
    FROM std_at_risk r JOIN std_cancels c ON c.month = r.month
    WHERE r.month BETWEEN '2025-03-01' AND '2025-05-01'
),
gain AS (
    SELECT SUM(mrr) - SUM(CASE WHEN status = 'active'
                               THEN 13.99 * CASE WHEN promo_signup = 1 AND tenure_month <= 3 THEN 0.5 ELSE 1 END
                               ELSE 0 END) AS gain_3m
    FROM v_sm WHERE plan = 'Standard' AND month IN ('2025-03-01', '2025-04-01', '2025-05-01')
)
SELECT
    ROUND(100 * baseline.rate, 2)                                         AS baseline_churn_pct,
    ROUND(100.0 * post.cancels / post.at_risk, 2)                         AS post_rise_churn_pct,
    ROUND(post.cancels - baseline.rate * post.at_risk, 0)                 AS excess_cancels_3m,
    ROUND(gain.gain_3m, 0)                                                AS price_gain_3m,
    ROUND(gain.gain_3m / 3, 0)                                            AS price_gain_per_month,
    ROUND((post.cancels - baseline.rate * post.at_risk) * 15.99, 0)       AS mrr_lost_per_month_from_excess_churn
FROM baseline, post, gain;

-- 5.7 Early upgraders: Basic signups who survived to tenure month 4 and either upgraded
--     within 3 months or did not. Outcome: still subscribed at tenure month 13.
--     Requiring survival to month 4 for BOTH groups avoids immortal-time bias.
--     This is an ASSOCIATION: customers who upgrade early may simply be more engaged.
WITH basics AS (
    SELECT c.customer_id, c.signup_midx, MAX(s.tenure_month) AS max_ten
    FROM v_c c JOIN v_sm s ON s.customer_id = c.customer_id
    WHERE c.signup_plan = 'Basic' GROUP BY c.customer_id
),
early AS (
    SELECT DISTINCT customer_id FROM events
    WHERE event_type = 'upgrade' AND from_plan = 'Basic' AND tenure_month <= 3
),
mx AS (SELECT MAX(midx) AS m FROM v_sm)
SELECT
    CASE WHEN e.customer_id IS NOT NULL THEN 'upgraded in first 3 months' ELSE 'stayed Basic through month 3' END AS group_,
    COUNT(*) AS customers,
    ROUND(100.0 * SUM(CASE WHEN max_ten >= 13 THEN 1 END) / COUNT(*), 1) AS retained_12m
FROM basics b
LEFT JOIN early e ON e.customer_id = b.customer_id, mx
WHERE b.max_ten >= 4 AND b.signup_midx + 12 <= m
GROUP BY group_;
