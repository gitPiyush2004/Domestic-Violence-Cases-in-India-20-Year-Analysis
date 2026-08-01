-- =============================================================================
-- 06_data_quality_audit.sql   |   Assertions that run against the loaded warehouse
--
-- These are not exploratory queries. Each one returns ZERO ROWS when the
-- warehouse is healthy, so the whole file is a regression suite: run it after
-- every reload and read any output as a failure. Writing checks this way means a
-- broken refresh is loud instead of quietly producing a plausible dashboard.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- CHECK 1  Grain integrity - the fact table must be unique on its declared key.
--          A duplicate here would double-count silently in every measure.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: duplicate grain' AS check_result, state_clean, year, crime_code, COUNT(*) AS n
FROM fact_crimes
GROUP BY state_clean, year, crime_code
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- CHECK 2  Referential integrity - no orphan fact rows against any dimension.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: orphan state' AS check_result, f.state_clean
FROM fact_crimes f LEFT JOIN dim_state d ON f.state_clean = d.state_clean
WHERE d.state_clean IS NULL
UNION ALL
SELECT 'FAIL: orphan crime_code', f.crime_code
FROM fact_crimes f LEFT JOIN dim_crime_type d ON f.crime_code = d.crime_code
WHERE d.crime_code IS NULL
UNION ALL
SELECT 'FAIL: orphan year', CAST(f.year AS TEXT)
FROM fact_crimes f LEFT JOIN dim_year d ON f.year = d.year
WHERE d.year IS NULL;


-- -----------------------------------------------------------------------------
-- CHECK 3  Domain integrity - counts cannot be negative or null.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: invalid case count' AS check_result, state_clean, year, crime_code, cases
FROM fact_crimes
WHERE cases IS NULL OR cases < 0;


-- -----------------------------------------------------------------------------
-- CHECK 4  Reconciliation to source - the warehouse total must equal the raw
--          file total. The repair re-labels rows; it must never change a sum.
--          4,867,722 is the figure computed straight off the untouched CSV.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: total does not reconcile to raw source' AS check_result,
       SUM(cases) AS warehouse_total, 4867722 AS expected_raw_total
FROM fact_crimes
HAVING SUM(cases) <> 4867722;


-- -----------------------------------------------------------------------------
-- CHECK 5  The misalignment must not come back. These are the entities whose
--          2020-21 rows were wrong in the source. Post-repair, none of them may
--          swing more than 60% year on year - that was the original symptom.
-- -----------------------------------------------------------------------------
WITH sy AS (
    SELECT state_clean, year, SUM(cases) AS total
    FROM fact_crimes
    WHERE is_structural_zero = 0 AND year BETWEEN 2019 AND 2021
    GROUP BY state_clean, year
),
yoy AS (
    SELECT
        state_clean, year, total,
        LAG(total) OVER (PARTITION BY state_clean ORDER BY year) AS prev
    FROM sy
)
SELECT 'FAIL: implausible YoY swing, repair may have regressed' AS check_result,
       state_clean, year, prev, total,
       ROUND(100.0 * (total * 1.0 / prev - 1), 1) AS yoy_pct
FROM yoy
WHERE prev >= 200
  AND ABS(100.0 * (total * 1.0 / prev - 1)) > 60;


-- -----------------------------------------------------------------------------
-- CHECK 6  Structural zeros must be exactly the pre-existence rows - no more,
--          no fewer. Telangana before 2014 (3 yrs) and Ladakh before 2020 are
--          the only legitimate cases, at 7 crime types each.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: unexpected structural zero flag' AS check_result,
       state_clean, year, COUNT(*) AS rows_flagged
FROM fact_crimes
WHERE is_structural_zero = 1
  AND NOT (state_clean = 'Telangana' AND year < 2014)
  AND NOT (state_clean = 'Ladakh'    AND year < 2020)
GROUP BY state_clean, year;


-- -----------------------------------------------------------------------------
-- CHECK 7  A flagged structural zero must actually be zero. If a pre-existence
--          row carries cases, either the flag or the data is wrong.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: structural zero carries cases' AS check_result,
       state_clean, year, crime_code, cases
FROM fact_crimes
WHERE is_structural_zero = 1 AND cases > 0;


-- -----------------------------------------------------------------------------
-- CHECK 7b  data_quality_flag must follow the documented PRECEDENCE rule, not a
--           one-to-one mapping onto the two booleans.
--
--           The two conditions genuinely overlap: Telangana / 2011 / AoW is both
--           an entity that did not exist yet AND inside the missing-AoW column.
--           entity_not_formed wins, because "the state did not exist" is the more
--           fundamental reason and a reader should see that first. An earlier
--           version of this check asserted exact equivalence and correctly failed
--           on that one row - the rule needed stating, not the data fixing.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: quality flag violates precedence rule' AS check_result,
       state_clean, year, crime_code, data_quality_flag,
       is_structural_zero, is_source_gap, include_in_analysis
FROM fact_crimes
WHERE data_quality_flag <> CASE
          WHEN is_structural_zero = 1 THEN 'entity_not_formed'   -- highest precedence
          WHEN is_source_gap      = 1 THEN 'source_gap'
          ELSE 'ok'
      END
   OR include_in_analysis <> CASE WHEN data_quality_flag = 'ok' THEN 1 ELSE 0 END;


-- -----------------------------------------------------------------------------
-- CHECK 7c  No measure-year may be entirely zero across every entity while its
--           neighbours are large. That pattern is what AoW 2011 looked like, and
--           it is the shape of a dropped column. Any NEW instance must be
--           investigated and flagged, not silently averaged into a trend.
-- -----------------------------------------------------------------------------
WITH by_cy AS (
    SELECT crime_code, year, SUM(cases) AS total
    FROM fact_crimes
    GROUP BY crime_code, year
),
windowed AS (
    SELECT crime_code, year, total,
           LAG(total)  OVER (PARTITION BY crime_code ORDER BY year) AS prev,
           LEAD(total) OVER (PARTITION BY crime_code ORDER BY year) AS next
    FROM by_cy
)
SELECT 'FAIL: unflagged all-entity zero year' AS check_result,
       w.crime_code, w.year, w.prev, w.total, w.next
FROM windowed w
WHERE w.total = 0 AND w.prev > 1000 AND w.next > 1000
  AND NOT EXISTS (
        SELECT 1 FROM fact_crimes f
        WHERE f.crime_code = w.crime_code AND f.year = w.year AND f.is_source_gap = 1
  );


-- -----------------------------------------------------------------------------
-- CHECK 8  Rate consistency - the stored rate must equal cases / female pop.
--          Guards against a stale derived column after a partial reload.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: rate does not recompute' AS check_result,
       state_clean, year, crime_code, cases, rate_per_lakh_female,
       ROUND(100000.0 * cases / female_population_2011, 2) AS recomputed
FROM fact_crimes
WHERE ABS(rate_per_lakh_female - 100000.0 * cases / female_population_2011) > 0.02;


-- -----------------------------------------------------------------------------
-- CHECK 9  Dimension cardinality - 36 entities, 21 years, 7 crime heads.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: unexpected dimension cardinality' AS check_result,
       (SELECT COUNT(*) FROM dim_state)      AS states,
       (SELECT COUNT(*) FROM dim_year)       AS years,
       (SELECT COUNT(*) FROM dim_crime_type) AS crime_types
WHERE (SELECT COUNT(*) FROM dim_state)      <> 36
   OR (SELECT COUNT(*) FROM dim_year)       <> 21
   OR (SELECT COUNT(*) FROM dim_crime_type) <> 7;


-- -----------------------------------------------------------------------------
-- CHECK 10 Panel coverage - every entity must be present for every year it
--          existed. Expected gaps: Delhi 2001-2010 (absent from the source),
--          Telangana 2001-2010, Ladakh 2001-2019.
-- -----------------------------------------------------------------------------
SELECT 'FAIL: unexpected panel gap' AS check_result, s.state_clean, y.year
FROM dim_state s
CROSS JOIN dim_year y
LEFT JOIN fact_crimes f
       ON f.state_clean = s.state_clean AND f.year = y.year AND f.crime_code = 'DV'
WHERE f.fact_id IS NULL
  AND NOT (s.state_clean = 'Delhi UT'  AND y.year <= 2010)
  AND NOT (s.state_clean = 'Telangana' AND y.year <= 2010)
  AND NOT (s.state_clean = 'Ladakh'    AND y.year <= 2019);
