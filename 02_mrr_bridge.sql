-- ============================================================
-- 02_mrr_bridge.sql  |  Project 4D
-- Questions: How is MRR growing, and what is it made of?
--            How much existing revenue do we keep (net revenue retention)?
-- Skills: self-joins on month, CASE classification, conditional pivots,
--         reconciliation. Requires 00_views.sql.
--
-- An "MRR bridge" explains each month's change: opening MRR + new + upgrades
-- + price/promo effects + resumes - downgrades - pauses - churn = closing MRR.
-- ============================================================

-- 2.1 Monthly MRR and customers on the books
SELECT
    month,
    COUNT(*)                                          AS customers_subscribed,
    SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS customers_paying,
    ROUND(SUM(mrr), 2)                                AS mrr,
    ROUND(SUM(mrr) / NULLIF(SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END), 0), 2) AS arpu_paying
FROM v_sm
GROUP BY month
ORDER BY month;

-- 2.2 MRR bridge: what moved MRR each month, by cause
WITH pairs AS (
    SELECT
        c.month, c.midx, c.customer_id, c.plan, c.mrr, c.tenure_month, c.promo_signup,
        p.plan AS prev_plan, p.mrr AS prev_mrr
    FROM v_sm c
    LEFT JOIN v_sm p ON p.customer_id = c.customer_id AND p.midx = c.midx - 1
),
moves AS (
    SELECT
        month,
        CASE
            WHEN prev_plan IS NULL THEN 'new'
            WHEN plan <> prev_plan AND
                 (CASE plan WHEN 'Basic' THEN 1 WHEN 'Standard' THEN 2 ELSE 3 END) >
                 (CASE prev_plan WHEN 'Basic' THEN 1 WHEN 'Standard' THEN 2 ELSE 3 END) THEN 'upgrade'
            WHEN plan <> prev_plan THEN 'downgrade'
            WHEN prev_mrr = 0 AND mrr > 0 THEN 'resume'
            WHEN mrr = 0 AND prev_mrr > 0 THEN 'pause'
            WHEN mrr > prev_mrr AND promo_signup = 1 AND tenure_month = 4 THEN 'promo_rolloff'
            WHEN mrr > prev_mrr THEN 'price_increase'
            WHEN mrr < prev_mrr THEN 'other_decrease'
            ELSE 'unchanged'
        END AS cat,
        mrr - COALESCE(prev_mrr, 0) AS delta
    FROM pairs
    UNION ALL
    -- churn: billed last month, no row this month
    SELECT DATE(p.month, '+1 month'), 'churn', -p.mrr
    FROM v_sm p
    LEFT JOIN v_sm c ON c.customer_id = p.customer_id AND c.midx = p.midx + 1
    WHERE c.customer_id IS NULL AND p.midx < (SELECT MAX(midx) FROM v_sm)
)
SELECT
    month,
    ROUND(SUM(CASE WHEN cat = 'new'            THEN delta ELSE 0 END), 2) AS new_mrr,
    ROUND(SUM(CASE WHEN cat = 'upgrade'        THEN delta ELSE 0 END), 2) AS upgrade,
    ROUND(SUM(CASE WHEN cat = 'promo_rolloff'  THEN delta ELSE 0 END), 2) AS promo_rolloff,
    ROUND(SUM(CASE WHEN cat = 'price_increase' THEN delta ELSE 0 END), 2) AS price_increase,
    ROUND(SUM(CASE WHEN cat = 'resume'         THEN delta ELSE 0 END), 2) AS resume,
    ROUND(SUM(CASE WHEN cat = 'downgrade'      THEN delta ELSE 0 END), 2) AS downgrade,
    ROUND(SUM(CASE WHEN cat = 'pause'          THEN delta ELSE 0 END), 2) AS pause,
    ROUND(SUM(CASE WHEN cat = 'churn'          THEN delta ELSE 0 END), 2) AS churn,
    ROUND(SUM(delta), 2)                                                   AS net_change
FROM moves
WHERE cat <> 'unchanged'
GROUP BY month
ORDER BY month;

-- 2.3 Reconciliation: closing MRR must equal prior closing MRR + net change
--     max_abs_difference should be 0.00 (tiny rounding at most)
WITH closing AS (
    SELECT midx, month, SUM(mrr) AS mrr FROM v_sm GROUP BY midx, month
),
pairs AS (
    SELECT c.midx, c.month, c.customer_id, c.mrr, p.mrr AS prev_mrr
    FROM v_sm c LEFT JOIN v_sm p ON p.customer_id = c.customer_id AND p.midx = c.midx - 1
),
net AS (
    SELECT month, SUM(mrr - COALESCE(prev_mrr, 0)) AS d FROM pairs GROUP BY month
    UNION ALL
    SELECT DATE(p.month, '+1 month'), -SUM(p.mrr)
    FROM v_sm p LEFT JOIN v_sm c ON c.customer_id = p.customer_id AND c.midx = p.midx + 1
    WHERE c.customer_id IS NULL AND p.midx < (SELECT MAX(midx) FROM v_sm)
    GROUP BY DATE(p.month, '+1 month')
),
net_by_month AS (SELECT month, SUM(d) AS net_change FROM net GROUP BY month)
SELECT ROUND(MAX(ABS(cur.mrr - prev.mrr - n.net_change)), 4) AS max_abs_difference,
       COUNT(*) AS months_checked
FROM closing cur
JOIN closing prev ON prev.midx = cur.midx - 1
JOIN net_by_month n ON n.month = cur.month;

-- 2.4 Net revenue retention (12 months): MRR today from customers who were
--     subscribed 12 months ago, divided by those customers' MRR back then.
--     (Churned customers contribute 0 today, so this captures churn, pauses,
--     upgrades, downgrades and price changes together.)
SELECT
    DATE(p.month, '+12 months')                                AS month,
    ROUND(SUM(p.mrr), 2)                                       AS mrr_12m_ago,
    ROUND(SUM(COALESCE(c.mrr, 0)), 2)                          AS mrr_now_same_customers,
    ROUND(100.0 * SUM(COALESCE(c.mrr, 0)) / SUM(p.mrr), 1)     AS nrr_pct
FROM v_sm p
LEFT JOIN v_sm c ON c.customer_id = p.customer_id AND c.midx = p.midx + 12
WHERE p.midx + 12 <= (SELECT MAX(midx) FROM v_sm)
GROUP BY 1
ORDER BY 1;
