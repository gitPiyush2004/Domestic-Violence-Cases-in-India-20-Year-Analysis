-- =============================================================================
-- 05_joins_deepdive.sql   |   Multi-table joins, self-joins, correlated logic
--
-- Everything here needs more than one table: fact joined to two or three
-- dimensions, the fact table joined to itself, and a CTE joined back to an
-- aggregate of itself. These are the queries that would be painful or impossible
-- against the original single flat sheet.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q5.1  Regional profile: fact joined to dim_state and dim_crime_type, with the
--       crime mix pivoted out by conditional aggregation.
--       Reveals that regions differ in the KIND of crime, not only the volume.
-- -----------------------------------------------------------------------------
-- Population is pre-aggregated to region in its own CTE and joined back. The
-- tempting shortcut - SUM(DISTINCT s.female_population_2011) inside the main
-- GROUP BY - happens to give the right answer on this data only because all 36
-- populations are distinct. It would silently under-count the moment two
-- entities shared a value, so it is not used.
WITH region_pop AS (
    SELECT region,
           SUM(female_population_2011) AS female_population,
           COUNT(*)                    AS entities
    FROM dim_state
    GROUP BY region
)
SELECT
    s.region,
    p.entities,
    SUM(f.cases)                                                           AS all_crimes,
    SUM(CASE WHEN c.crime_code = 'DV'   THEN f.cases END)                  AS domestic_violence,
    SUM(CASE WHEN c.crime_code = 'AoW'  THEN f.cases END)                  AS assault,
    SUM(CASE WHEN c.crime_code = 'K&A'  THEN f.cases END)                  AS kidnapping,
    SUM(CASE WHEN c.crime_code = 'Rape' THEN f.cases END)                  AS rape,
    SUM(CASE WHEN c.crime_code = 'DD'   THEN f.cases END)                  AS dowry_deaths,
    ROUND(100.0 * SUM(CASE WHEN c.crime_code = 'DV' THEN f.cases END)
                / SUM(f.cases), 1)                                         AS dv_share_pct,
    -- Cases per lakh women PER YEAR: the 21-year total divided by the number of
    -- years, so this is comparable with the single-year rates used elsewhere.
    ROUND(100000.0 * SUM(CASE WHEN c.crime_code = 'DV' THEN f.cases END)
                   / p.female_population / 21.0, 1)                        AS dv_per_lakh_per_year
FROM fact_crimes f
JOIN dim_state      s ON f.state_clean = s.state_clean
JOIN dim_crime_type c ON f.crime_code  = c.crime_code
JOIN region_pop     p ON s.region      = p.region
WHERE f.include_in_analysis = 1
GROUP BY s.region, p.entities, p.female_population
ORDER BY domestic_violence DESC;


-- -----------------------------------------------------------------------------
-- Q5.2  Self-join on the fact table: does a state's DV burden track its OTHER
--       crime burden, or is DV independent?
--
--       Matters for interpretation. If DV rises wherever all crime rises, DV is
--       largely a reporting-intensity story. If a state is DV-heavy but calm
--       elsewhere, something specific to the household is going on there.
-- -----------------------------------------------------------------------------
WITH dv AS (
    SELECT state_clean, SUM(cases) AS dv_cases
    FROM fact_crimes
    WHERE crime_code = 'DV' AND include_in_analysis = 1
    GROUP BY state_clean
),
other AS (
    SELECT state_clean, SUM(cases) AS other_cases
    FROM fact_crimes
    WHERE crime_code <> 'DV' AND include_in_analysis = 1
    GROUP BY state_clean
)
SELECT
    d.state_clean,
    s.region,
    d.dv_cases,
    o.other_cases,
    ROUND(1.0 * d.dv_cases / NULLIF(o.other_cases, 0), 3)          AS dv_to_other_ratio,
    ROUND(100.0 * d.dv_cases / (d.dv_cases + o.other_cases), 1)    AS dv_share_pct,
    CASE
        WHEN 1.0 * d.dv_cases / NULLIF(o.other_cases, 0) >= 1.0 THEN 'DV-dominant'
        WHEN 1.0 * d.dv_cases / NULLIF(o.other_cases, 0) >= 0.5 THEN 'DV-heavy'
        WHEN 1.0 * d.dv_cases / NULLIF(o.other_cases, 0) >= 0.2 THEN 'Balanced'
        ELSE 'DV-light'
    END AS crime_profile
FROM dv d
JOIN other      o ON d.state_clean = o.state_clean
JOIN dim_state  s ON d.state_clean = s.state_clean
WHERE d.dv_cases + o.other_cases >= 1000
ORDER BY dv_to_other_ratio DESC;


-- -----------------------------------------------------------------------------
-- Q5.3  Contribution analysis: each state against the national average, using a
--       CTE joined to an aggregate of itself (a cross join to a one-row summary).
--       The "above average by Nx" framing lands harder than a raw count.
-- -----------------------------------------------------------------------------
WITH state_dv AS (
    SELECT
        f.state_clean,
        s.region,
        s.entity_type,
        SUM(f.cases)                                                  AS dv_cases,
        ROUND(100000.0 * SUM(f.cases) / s.female_population_2011, 1)  AS rate_per_lakh
    FROM fact_crimes f
    JOIN dim_state s ON f.state_clean = s.state_clean
    WHERE f.crime_code = 'DV' AND f.include_in_analysis = 1
    GROUP BY f.state_clean, s.region, s.entity_type, s.female_population_2011
),
national AS (
    SELECT
        SUM(dv_cases)  AS national_dv,
        AVG(rate_per_lakh) AS avg_rate,
        COUNT(*)       AS n_states
    FROM state_dv
)
SELECT
    sd.state_clean,
    sd.region,
    sd.dv_cases,
    ROUND(100.0 * sd.dv_cases / n.national_dv, 2)          AS pct_of_national,
    sd.rate_per_lakh,
    ROUND(n.avg_rate, 1)                                   AS national_avg_rate,
    ROUND(sd.rate_per_lakh / n.avg_rate, 2)                AS times_national_avg,
    CASE WHEN sd.rate_per_lakh > n.avg_rate THEN 'Above average'
         ELSE 'Below average' END                          AS vs_average
FROM state_dv sd
CROSS JOIN national n
ORDER BY sd.dv_cases DESC;


-- -----------------------------------------------------------------------------
-- Q5.4  Peak-year detection per state via a correlated subquery.
--       "Has this state already turned the corner, or is it still at its worst?"
--       A state peaking in 2013 and falling since is a different story from one
--       whose worst year is the most recent year.
-- -----------------------------------------------------------------------------
WITH sy AS (
    SELECT state_clean, year, SUM(cases) AS dv
    FROM fact_crimes
    WHERE crime_code = 'DV' AND include_in_analysis = 1
    GROUP BY state_clean, year
)
SELECT
    a.state_clean,
    a.year          AS peak_year,
    a.dv            AS peak_cases,
    l.dv            AS cases_2021,
    ROUND(100.0 * (l.dv * 1.0 / a.dv - 1), 1)  AS pct_off_peak,
    2021 - a.year                              AS years_since_peak,
    CASE
        WHEN a.year >= 2020 THEN 'At or near peak now'
        WHEN l.dv * 1.0 / a.dv < 0.80 THEN 'Clearly past peak (>20% below)'
        ELSE 'Off peak but still elevated'
    END AS peak_status
FROM sy a
JOIN sy l ON l.state_clean = a.state_clean AND l.year = 2021
WHERE a.dv = (SELECT MAX(b.dv) FROM sy b WHERE b.state_clean = a.state_clean)
  AND a.dv >= 500
ORDER BY a.dv DESC;


-- -----------------------------------------------------------------------------
-- Q5.5  Does reported DV track female literacy?
--       A LEFT JOIN keeps every state even where literacy is missing, so the
--       row count is stable and nothing disappears silently.
--
--       Read this one carefully in an interview: higher literacy correlating with
--       higher REPORTED DV is most plausibly a reporting-propensity effect, not
--       more violence. NCRB counts reports, not incidents.
-- -----------------------------------------------------------------------------
-- Aggregate to one row per state FIRST, then band. Banding before aggregating
-- would repeat each state's population once per fact row and inflate the
-- denominator by a factor of 21 (one per year).
WITH per_state AS (
    SELECT
        s.state_clean,
        s.literacy_rate_2011,
        s.female_population_2011,
        COALESCE(SUM(f.cases), 0) AS dv_cases
    FROM dim_state s
    LEFT JOIN fact_crimes f
           ON s.state_clean = f.state_clean
          AND f.crime_code = 'DV'
          AND f.include_in_analysis = 1
    GROUP BY s.state_clean, s.literacy_rate_2011, s.female_population_2011
)
SELECT
    CASE
        WHEN literacy_rate_2011 >= 85 THEN '1. Very high (85%+)'
        WHEN literacy_rate_2011 >= 75 THEN '2. High (75-85%)'
        WHEN literacy_rate_2011 >= 68 THEN '3. Medium (68-75%)'
        ELSE                               '4. Low (<68%)'
    END                                                          AS literacy_band,
    COUNT(*)                                                     AS states,
    SUM(dv_cases)                                                AS dv_cases,
    ROUND(AVG(literacy_rate_2011), 1)                            AS avg_literacy,
    ROUND(100000.0 * SUM(dv_cases) / SUM(female_population_2011)
          / 21.0, 1)                                             AS dv_per_lakh_per_year
FROM per_state
GROUP BY literacy_band
ORDER BY literacy_band;
