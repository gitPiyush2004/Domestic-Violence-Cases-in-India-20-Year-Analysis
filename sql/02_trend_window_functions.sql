-- =============================================================================
-- 02_trend_window_functions.sql   |   Trend, YoY, CAGR, momentum
--
-- Window functions do the work here. The alternative - self-joining the fact
-- table to itself on year = year - 1 - scans the table twice and breaks silently
-- wherever a year is missing for an entity (Telangana 2013->2014, Ladakh 2019->
-- 2020). LAG over an ordered partition handles those gaps by construction.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q2.1  National DV trend with YoY, 3-year moving average and an index base.
--       Three different lenses on one series:
--         dv_yoy_pct        - short-term shock (finds COVID)
--         moving_avg_3yr    - trend with the shock smoothed out
--         index_2001        - cumulative scale of change (reads as "x times 2001")
-- -----------------------------------------------------------------------------
WITH yearly AS (
    SELECT year, SUM(cases) AS dv_cases
    FROM fact_crimes
    WHERE crime_code = 'DV' AND include_in_analysis = 1
    GROUP BY year
)
SELECT
    year,
    dv_cases,
    LAG(dv_cases) OVER (ORDER BY year)                                    AS prev_year,
    dv_cases - LAG(dv_cases) OVER (ORDER BY year)                         AS abs_change,
    ROUND(100.0 * (dv_cases * 1.0 / LAG(dv_cases) OVER (ORDER BY year) - 1), 2)
                                                                          AS dv_yoy_pct,
    ROUND(AVG(dv_cases) OVER (ORDER BY year ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0)
                                                                          AS moving_avg_3yr,
    ROUND(100.0 * dv_cases / FIRST_VALUE(dv_cases) OVER (ORDER BY year), 1)
                                                                          AS index_2001,
    -- Running total: cumulative human cost across the two decades.
    SUM(dv_cases) OVER (ORDER BY year)                                    AS cumulative_cases
FROM yearly
ORDER BY year;


-- -----------------------------------------------------------------------------
-- Q2.2  Which crime head grew fastest? Long-form pays off here: one query
--       covers all seven heads. In the original wide layout this needed a
--       seven-branch UNION ALL.
-- -----------------------------------------------------------------------------
WITH by_type AS (
    SELECT crime_type, year, SUM(cases) AS cases
    FROM fact_crimes
    WHERE include_in_analysis = 1
    GROUP BY crime_type, year
),
endpoints AS (
    SELECT
        crime_type,
        MAX(CASE WHEN year = 2001 THEN cases END) AS cases_2001,
        MAX(CASE WHEN year = 2021 THEN cases END) AS cases_2021,
        SUM(cases)                               AS total_cases,
        MAX(cases)                               AS peak_cases,
        -- The year the head peaked: ranks within the head, then picks rank 1.
        MAX(CASE WHEN rnk = 1 THEN year END)     AS peak_year
    FROM (
        SELECT *, RANK() OVER (PARTITION BY crime_type ORDER BY cases DESC) AS rnk
        FROM by_type
    )
    GROUP BY crime_type
)
SELECT
    crime_type,
    cases_2001,
    cases_2021,
    total_cases,
    peak_year,
    ROUND(100.0 * (cases_2021 * 1.0 / cases_2001 - 1), 1)                       AS growth_pct,
    ROUND(100.0 * (POWER(cases_2021 * 1.0 / cases_2001, 1.0 / 20) - 1), 2)      AS cagr_pct,
    RANK() OVER (ORDER BY POWER(cases_2021 * 1.0 / cases_2001, 1.0 / 20) DESC)  AS growth_rank,
    RANK() OVER (ORDER BY total_cases DESC)                                     AS volume_rank
FROM endpoints
ORDER BY cagr_pct DESC;


-- -----------------------------------------------------------------------------
-- Q2.3  State-level momentum: rank each state within its own year, then measure
--       how far it moved up or down the table over 20 years.
--
--       Rank movement is the interesting signal: a state can grow in absolute
--       terms while still improving RELATIVE to everywhere else. Volume alone
--       hides that; this exposes it.
-- -----------------------------------------------------------------------------
WITH state_year AS (
    SELECT state_clean, year, SUM(cases) AS dv_cases
    FROM fact_crimes
    WHERE crime_code = 'DV' AND include_in_analysis = 1
    GROUP BY state_clean, year
),
ranked AS (
    SELECT
        state_clean, year, dv_cases,
        RANK() OVER (PARTITION BY year ORDER BY dv_cases DESC) AS rank_in_year
    FROM state_year
)
SELECT
    r.state_clean,
    s.region,
    MAX(CASE WHEN r.year = 2001 THEN r.rank_in_year END) AS rank_2001,
    MAX(CASE WHEN r.year = 2021 THEN r.rank_in_year END) AS rank_2021,
    MAX(CASE WHEN r.year = 2001 THEN r.rank_in_year END)
      - MAX(CASE WHEN r.year = 2021 THEN r.rank_in_year END)  AS places_gained,
    MAX(CASE WHEN r.year = 2001 THEN r.dv_cases END)     AS dv_2001,
    MAX(CASE WHEN r.year = 2021 THEN r.dv_cases END)     AS dv_2021,
    CASE
        WHEN MAX(CASE WHEN r.year = 2001 THEN r.rank_in_year END)
           - MAX(CASE WHEN r.year = 2021 THEN r.rank_in_year END) <= -5 THEN 'Deteriorated sharply'
        WHEN MAX(CASE WHEN r.year = 2001 THEN r.rank_in_year END)
           - MAX(CASE WHEN r.year = 2021 THEN r.rank_in_year END) < 0  THEN 'Deteriorated'
        WHEN MAX(CASE WHEN r.year = 2001 THEN r.rank_in_year END)
           - MAX(CASE WHEN r.year = 2021 THEN r.rank_in_year END) = 0  THEN 'Unchanged'
        WHEN MAX(CASE WHEN r.year = 2001 THEN r.rank_in_year END)
           - MAX(CASE WHEN r.year = 2021 THEN r.rank_in_year END) < 5  THEN 'Improved'
        ELSE 'Improved sharply'
    END AS rank_movement
FROM ranked r
JOIN dim_state s ON r.state_clean = s.state_clean
GROUP BY r.state_clean, s.region
HAVING rank_2001 IS NOT NULL AND rank_2021 IS NOT NULL
ORDER BY places_gained;


-- -----------------------------------------------------------------------------
-- Q2.4  The COVID shock, isolated.
--       2020 and 2021 are the two years the source file had mislabelled, so this
--       query doubles as the payoff of the repair: the shock is only legible once
--       state attribution is correct.
-- -----------------------------------------------------------------------------
WITH sy AS (
    SELECT state_clean, year, SUM(cases) AS dv
    FROM fact_crimes
    WHERE crime_code = 'DV' AND include_in_analysis = 1 AND year BETWEEN 2019 AND 2021
    GROUP BY state_clean, year
),
p AS (
    SELECT
        state_clean,
        MAX(CASE WHEN year = 2019 THEN dv END) AS dv_2019,
        MAX(CASE WHEN year = 2020 THEN dv END) AS dv_2020,
        MAX(CASE WHEN year = 2021 THEN dv END) AS dv_2021
    FROM sy GROUP BY state_clean
)
SELECT
    state_clean,
    dv_2019, dv_2020, dv_2021,
    ROUND(100.0 * (dv_2020 * 1.0 / dv_2019 - 1), 1) AS covid_dip_pct,
    ROUND(100.0 * (dv_2021 * 1.0 / dv_2020 - 1), 1) AS rebound_pct,
    CASE
        WHEN dv_2021 > dv_2019 AND dv_2020 < dv_2019 THEN 'Dipped then overshot 2019'
        WHEN dv_2020 < dv_2019 AND dv_2021 <= dv_2019 THEN 'Dipped, not yet recovered'
        WHEN dv_2020 >= dv_2019                        THEN 'No lockdown dip'
        ELSE 'Other'
    END AS covid_pattern
FROM p
WHERE dv_2019 >= 500      -- suppress small-count noise
ORDER BY covid_dip_pct;
