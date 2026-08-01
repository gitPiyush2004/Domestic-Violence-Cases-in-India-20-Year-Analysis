-- =============================================================================
-- 01_kpi_headline.sql   |   The six numbers that open the dashboard
--
-- Every KPI tile on page 1 traces to a query here. Keeping them in SQL rather
-- than only in DAX means the dashboard can be reconciled against the warehouse
-- line by line - the first thing a reviewer asks for.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q1.1  Portfolio scale: all crimes against women, split by IPC head.
--       Answers "how big is the problem, and which head dominates?"
--       ORDER BY total DESC is what surfaces domestic violence as the #1 head -
--       the finding the whole project is built on.
-- -----------------------------------------------------------------------------
SELECT
    d.crime_type,
    d.ipc_section,
    SUM(f.cases)                                                   AS total_cases,
    ROUND(100.0 * SUM(f.cases) / SUM(SUM(f.cases)) OVER (), 2)      AS pct_of_all_crime,
    MIN(f.year)                                                    AS first_year,
    MAX(f.year)                                                    AS last_year
FROM fact_crimes f
JOIN dim_crime_type d ON f.crime_code = d.crime_code
WHERE f.include_in_analysis = 1
GROUP BY d.crime_type, d.ipc_section
ORDER BY total_cases DESC;


-- -----------------------------------------------------------------------------
-- Q1.2  The six headline KPIs, one row.
--       Conditional aggregation (SUM(CASE WHEN ...)) pivots year filters into
--       columns in a single pass over the fact table - cheaper and far easier to
--       reconcile than six separate scalar subqueries.
-- -----------------------------------------------------------------------------
SELECT
    SUM(CASE WHEN crime_code = 'DV' THEN cases END)                            AS dv_total_20yr,
    SUM(cases)                                                                AS all_crimes_20yr,
    ROUND(100.0 * SUM(CASE WHEN crime_code = 'DV' THEN cases END)
                / SUM(cases), 1)                                              AS dv_pct_of_all_crime,
    SUM(CASE WHEN crime_code = 'DV' AND year = 2001 THEN cases END)            AS dv_2001,
    SUM(CASE WHEN crime_code = 'DV' AND year = 2021 THEN cases END)            AS dv_2021,
    ROUND(100.0 * (SUM(CASE WHEN crime_code = 'DV' AND year = 2021 THEN cases END) * 1.0
                 / SUM(CASE WHEN crime_code = 'DV' AND year = 2001 THEN cases END) - 1), 1)
                                                                              AS dv_growth_pct,
    -- CAGR over 20 compounding periods (2001 -> 2021)
    ROUND(100.0 * (POWER(
            SUM(CASE WHEN crime_code = 'DV' AND year = 2021 THEN cases END) * 1.0
          / SUM(CASE WHEN crime_code = 'DV' AND year = 2001 THEN cases END), 1.0 / 20) - 1), 2)
                                                                              AS dv_cagr_pct,
    COUNT(DISTINCT state_clean)                                               AS entities,
    COUNT(DISTINCT year)                                                      AS years_covered
FROM fact_crimes
WHERE include_in_analysis = 1;


-- -----------------------------------------------------------------------------
-- Q1.3  Is domestic violence gaining or losing share of the total?
--       A rising absolute count could simply mean all crime is rising. Share
--       isolates whether DV is outpacing everything else - a different, and more
--       useful, claim.
--
--       The share is NULLed for 2011. That year's Assault-on-Women column is
--       missing from the source, so the denominator is ~42,000 short and the
--       share would print 55.5% against ~46% either side. Publishing that number
--       would invent a spike; suppressing it is the honest move. The join to
--       dim_year is what makes the suppression rule data-driven rather than a
--       hardcoded "AND year <> 2011" buried in the WHERE clause.
-- -----------------------------------------------------------------------------
SELECT
    f.year,
    SUM(CASE WHEN f.crime_code = 'DV' THEN f.cases END)                AS dv_cases,
    CASE WHEN y.all_crimes_comparable = 1 THEN SUM(f.cases) END        AS all_cases,
    CASE WHEN y.all_crimes_comparable = 1
         THEN ROUND(100.0 * SUM(CASE WHEN f.crime_code = 'DV' THEN f.cases END)
                          / SUM(f.cases), 2) END                       AS dv_share_pct,
    y.coverage_note
FROM fact_crimes f
JOIN dim_year y ON f.year = y.year
WHERE f.include_in_analysis = 1
GROUP BY f.year, y.all_crimes_comparable, y.coverage_note
ORDER BY f.year;
