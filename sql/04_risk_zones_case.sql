-- =============================================================================
-- 04_risk_zones_case.sql   |   High-risk zone identification with CASE logic
--
-- Absolute case counts rank states by population, not by danger. Uttar Pradesh
-- leads almost every crime table in India because 200 million people live there.
-- Normalising by female population turns "where are the most cases" into "where
-- is a woman most exposed" - which is the question that changes a decision.
--
-- Band cut points are the quartiles of the 2021 rate distribution (computed in
-- etl/01_clean_and_wrangle.py and written to data/processed/risk_thresholds.json
-- so SQL, DAX and the dashboard cannot drift apart):
--   Critical  >= Q3       High  >= median       Moderate  >= Q1       Low  < Q1
-- Quartiles rather than round numbers keeps the bands meaningful if the data is
-- refreshed - a hardcoded "60 per lakh" silently stops being the top quartile.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q4.1  Risk banding for 2021, volume rank against rate rank side by side.
--       The gap between the two ranks is the whole argument for normalising.
-- -----------------------------------------------------------------------------
WITH dv_2021 AS (
    SELECT
        f.state_clean,
        s.entity_type,
        s.region,
        s.female_population_2011,
        SUM(f.cases)                                                       AS dv_cases,
        ROUND(100000.0 * SUM(f.cases) / s.female_population_2011, 1)       AS rate_per_lakh
    FROM fact_crimes f
    JOIN dim_state s ON f.state_clean = s.state_clean
    WHERE f.crime_code = 'DV' AND f.year = 2021 AND f.include_in_analysis = 1
    GROUP BY f.state_clean, s.entity_type, s.region, s.female_population_2011
),
banded AS (
    SELECT
        *,
        CASE
            WHEN rate_per_lakh >= 22.9 THEN 'Critical'
            WHEN rate_per_lakh >=  9.1 THEN 'High'
            WHEN rate_per_lakh >=  2.5 THEN 'Moderate'
            ELSE 'Low'
        END AS risk_zone,
        RANK() OVER (ORDER BY dv_cases     DESC) AS volume_rank,
        RANK() OVER (ORDER BY rate_per_lakh DESC) AS rate_rank
    FROM dv_2021
)
SELECT
    state_clean,
    entity_type,
    region,
    dv_cases,
    rate_per_lakh,
    risk_zone,
    volume_rank,
    rate_rank,
    volume_rank - rate_rank AS rank_gap,
    -- Narrates the disagreement so the table reads without a footnote.
    CASE
        WHEN volume_rank - rate_rank >=  8 THEN 'Rate hides in a big population'
        WHEN volume_rank - rate_rank <= -8 THEN 'Small state, disproportionate burden'
        ELSE 'Volume and rate broadly agree'
    END AS interpretation
FROM banded
ORDER BY rate_per_lakh DESC;


-- -----------------------------------------------------------------------------
-- Q4.2  Zone summary: how much of India's burden and population sits in each band.
-- -----------------------------------------------------------------------------
WITH dv_2021 AS (
    SELECT
        f.state_clean,
        s.female_population_2011,
        SUM(f.cases)                                                 AS dv_cases,
        100000.0 * SUM(f.cases) / s.female_population_2011           AS rate
    FROM fact_crimes f
    JOIN dim_state s ON f.state_clean = s.state_clean
    WHERE f.crime_code = 'DV' AND f.year = 2021 AND f.include_in_analysis = 1
    GROUP BY f.state_clean, s.female_population_2011
)
SELECT
    CASE WHEN rate >= 22.9 THEN 'Critical'
         WHEN rate >=  9.1 THEN 'High'
         WHEN rate >=  2.5 THEN 'Moderate'
         ELSE 'Low' END                                              AS risk_zone,
    COUNT(*)                                                         AS states,
    SUM(dv_cases)                                                    AS dv_cases_2021,
    ROUND(100.0 * SUM(dv_cases) / SUM(SUM(dv_cases)) OVER (), 1)     AS pct_of_cases,
    SUM(female_population_2011)                                      AS female_population,
    ROUND(100.0 * SUM(female_population_2011)
                / SUM(SUM(female_population_2011)) OVER (), 1)       AS pct_of_women,
    ROUND(100000.0 * SUM(dv_cases) / SUM(female_population_2011), 1) AS zone_rate
FROM dv_2021
GROUP BY risk_zone
ORDER BY zone_rate DESC;


-- -----------------------------------------------------------------------------
-- Q4.3  Priority matrix: cross rate LEVEL against rate TREND.
--
--       Level alone cannot separate a bad-but-improving state from a
--       moderate-but-deteriorating one. Those need opposite responses: protect
--       the first, intervene in the second. A 2x2 on level x direction is what
--       a steering committee can actually assign owners against.
-- -----------------------------------------------------------------------------
SELECT
    s.state_clean,
    s.region,
    s.dv_cases_2021,
    s.dv_rate_2021,
    s.dv_cagr_pct,
    s.risk_zone,
    s.abc_class,
    s.trend_direction,
    CASE
        WHEN s.risk_zone IN ('Critical','High') AND s.dv_cagr_pct > 2
            THEN 'P1 - Escalate: high level, still rising'
        WHEN s.risk_zone IN ('Critical','High') AND s.dv_cagr_pct <= 2
            THEN 'P2 - Sustain: high level, contained'
        WHEN s.risk_zone IN ('Moderate','Low')  AND s.dv_cagr_pct > 5
            THEN 'P3 - Watch: low level, fast deterioration'
        ELSE 'P4 - Maintain'
    END AS priority_action
FROM dim_state s
WHERE s.dv_cases_2021 > 0
ORDER BY
    CASE
        WHEN s.risk_zone IN ('Critical','High') AND s.dv_cagr_pct > 2  THEN 1
        WHEN s.risk_zone IN ('Critical','High') AND s.dv_cagr_pct <= 2 THEN 2
        WHEN s.risk_zone IN ('Moderate','Low')  AND s.dv_cagr_pct > 5  THEN 3
        ELSE 4
    END,
    s.dv_rate_2021 DESC;
