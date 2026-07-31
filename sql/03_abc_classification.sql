-- =============================================================================
-- 03_abc_classification.sql   |   Pareto / ABC segmentation of states
--
-- ABC classification is borrowed from inventory management, where it splits SKUs
-- by contribution to value. Applied to states by contribution to national case
-- volume it answers the question a policy owner with a fixed budget actually
-- has: "how few places must I fix to move the national number?"
--
--   Class A - states covering the first 70% of cumulative volume -> act first
--   Class B - the next 20%                                       -> monitor
--   Class C - the tail 10%                                       -> report only
--
-- The mechanic is a running total over an ordered window. Note the boundary
-- rule: classification is on the cumulative total BEFORE the current row
-- (LAG of the running sum), so the state that CROSSES 70% is pulled into A
-- rather than pushed into B. Classifying on the row's own cumulative total
-- instead would land the cut mid-state and leave class A short of its 70%.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q3.1  ABC classification on 20-year domestic violence volume.
-- -----------------------------------------------------------------------------
WITH state_totals AS (
    SELECT state_clean, SUM(cases) AS dv_cases
    FROM fact_crimes
    WHERE crime_code = 'DV' AND include_in_analysis = 1
    GROUP BY state_clean
    HAVING SUM(cases) > 0
),
with_share AS (
    SELECT
        state_clean,
        dv_cases,
        ROUND(100.0 * dv_cases / SUM(dv_cases) OVER (), 2)                       AS share_pct,
        ROUND(100.0 * SUM(dv_cases) OVER (ORDER BY dv_cases DESC
                                          ROWS UNBOUNDED PRECEDING)
                    / SUM(dv_cases) OVER (), 2)                                  AS cumulative_pct,
        ROW_NUMBER() OVER (ORDER BY dv_cases DESC)                               AS rank
    FROM state_totals
),
with_prev AS (
    -- cumulative_pct of the PRECEDING row; 0 for the first row.
    SELECT *, COALESCE(LAG(cumulative_pct) OVER (ORDER BY rank), 0) AS prev_cum_pct
    FROM with_share
)
SELECT
    rank,
    state_clean,
    dv_cases,
    share_pct,
    cumulative_pct,
    CASE
        WHEN prev_cum_pct < 70 THEN 'A'
        WHEN prev_cum_pct < 90 THEN 'B'
        ELSE 'C'
    END AS abc_class,
    CASE
        WHEN prev_cum_pct < 70 THEN 'A - Critical (top 70% of volume)'
        WHEN prev_cum_pct < 90 THEN 'B - Moderate (next 20%)'
        ELSE 'C - Low (tail 10%)'
    END AS abc_label
FROM with_prev
ORDER BY rank;


-- -----------------------------------------------------------------------------
-- Q3.2  The one-line summary of the classification - the slide-ready number.
--       "N states out of 36 account for X% of all cases."
-- -----------------------------------------------------------------------------
WITH state_totals AS (
    SELECT state_clean, SUM(cases) AS dv_cases
    FROM fact_crimes
    WHERE crime_code = 'DV' AND include_in_analysis = 1
    GROUP BY state_clean HAVING SUM(cases) > 0
),
classified AS (
    SELECT
        state_clean, dv_cases,
        CASE
            WHEN COALESCE(LAG(c) OVER (ORDER BY dv_cases DESC), 0) < 70 THEN 'A'
            WHEN COALESCE(LAG(c) OVER (ORDER BY dv_cases DESC), 0) < 90 THEN 'B'
            ELSE 'C'
        END AS abc_class
    FROM (
        SELECT
            state_clean, dv_cases,
            100.0 * SUM(dv_cases) OVER (ORDER BY dv_cases DESC ROWS UNBOUNDED PRECEDING)
                  / SUM(dv_cases) OVER () AS c
        FROM state_totals
    )
)
SELECT
    abc_class,
    COUNT(*)                                                              AS states,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                    AS pct_of_states,
    SUM(dv_cases)                                                         AS dv_cases,
    ROUND(100.0 * SUM(dv_cases) / SUM(SUM(dv_cases)) OVER (), 1)          AS pct_of_cases,
    -- The efficiency ratio: share of burden divided by share of states. >1 means
    -- this class carries more than its headcount would suggest.
    ROUND((100.0 * SUM(dv_cases) / SUM(SUM(dv_cases)) OVER ())
        / (100.0 * COUNT(*)      / SUM(COUNT(*))      OVER ()), 2)        AS concentration_ratio
FROM classified
GROUP BY abc_class
ORDER BY abc_class;


-- -----------------------------------------------------------------------------
-- Q3.3  Cross-tab the two segmentations: ABC (volume) x risk zone (rate).
--
--       This is the payoff of holding both a volume view and a rate view. The
--       two disagree, and the disagreement is the insight:
--         A + Critical  -> big AND intense: unambiguous first priority
--         A + Low       -> big only because the state is big: needs scale, not alarm
--         C + Critical  -> small but intense: a real emergency that volume ranking
--                          buries entirely
-- -----------------------------------------------------------------------------
SELECT
    abc_class,
    risk_zone,
    COUNT(*)                                    AS states,
    GROUP_CONCAT(state_clean, ', ')             AS state_list,
    SUM(dv_total_cases)                         AS dv_cases,
    ROUND(AVG(dv_rate_2021), 1)                 AS avg_rate_2021
FROM dim_state
WHERE dv_total_cases > 0
GROUP BY abc_class, risk_zone
ORDER BY
    abc_class,
    CASE risk_zone WHEN 'Critical' THEN 1 WHEN 'High' THEN 2
                   WHEN 'Moderate' THEN 3 ELSE 4 END;
