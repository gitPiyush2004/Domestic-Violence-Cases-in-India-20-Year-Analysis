-- =============================================================================
-- 00_schema.sql
-- Star schema for the Crimes Against Women in India analysis (2001-2021).
--
-- One central fact table at state x year x crime_type grain, three conformed
-- dimensions. Deliberately NOT one wide table: the wide layout forces seven
-- near-duplicate measures and makes "which crime type grew fastest" unanswerable
-- without a UNION per crime.
--
-- Dialect: SQLite (portable, zero-setup, runs from the repo). The DDL is written
-- so the queries port to SQL Server / Postgres with no rewrite - the only
-- non-standard piece is the AUTOINCREMENT keyword.
-- =============================================================================

DROP TABLE IF EXISTS fact_crimes;
DROP TABLE IF EXISTS dim_state;
DROP TABLE IF EXISTS dim_crime_type;
DROP TABLE IF EXISTS dim_year;

-- -----------------------------------------------------------------------------
-- DIMENSION: state / union territory
-- Grain: one row per administrative entity (36 rows).
-- Carries the Census 2011 denominators so rate-per-lakh can be computed in SQL
-- rather than being pre-baked, and the segmentation columns (risk_zone,
-- abc_class) so the dashboard and SQL agree on a single definition.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_state (
    state_clean                 TEXT    PRIMARY KEY,
    state_code                  TEXT    NOT NULL,
    entity_type                 TEXT    NOT NULL CHECK (entity_type IN ('State','Union Territory')),
    region                      TEXT    NOT NULL,
    population_2011             INTEGER NOT NULL CHECK (population_2011 > 0),
    sex_ratio_2011              INTEGER NOT NULL,
    literacy_rate_2011          REAL,
    female_population_2011      INTEGER NOT NULL CHECK (female_population_2011 > 0),
    dv_total_cases              INTEGER,
    dv_cases_2001               INTEGER,
    dv_cases_2021               INTEGER,
    all_crime_total             INTEGER,
    dv_share_of_state_crime_pct REAL,
    dv_rate_2021                REAL,
    dv_rate_20yr_avg            REAL,
    dv_cagr_pct                 REAL,
    years_observed              INTEGER,
    first_year_observed         INTEGER,
    trend_direction             TEXT,
    risk_zone                   TEXT    CHECK (risk_zone IN ('Critical','High','Moderate','Low')),
    abc_class                   TEXT    CHECK (abc_class IN ('A','B','C')),
    abc_label                   TEXT,
    share_pct                   REAL,
    cumulative_pct              REAL,
    rank                        INTEGER,
    notes                       TEXT
);

-- -----------------------------------------------------------------------------
-- DIMENSION: crime type
-- Grain: one row per IPC head reported by NCRB (7 rows).
-- ipc_section is what turns an opaque column name like 'AoM' into something a
-- stakeholder can act on.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_crime_type (
    crime_code               TEXT    PRIMARY KEY,
    crime_type               TEXT    NOT NULL UNIQUE,
    ipc_section              TEXT    NOT NULL,
    total_cases_2001_2021    INTEGER,
    share_of_all_crime_pct   REAL,
    cases_2001               INTEGER,
    cases_2021               INTEGER,
    cagr_pct                 REAL,
    is_focus_crime           INTEGER NOT NULL DEFAULT 0,
    -- Documented discontinuities in what NCRB counted. A trend drawn across one
    -- of these years measures a definition change, not a change in behaviour.
    series_break_note        TEXT,
    is_comparable_series     INTEGER NOT NULL DEFAULT 1
);

-- -----------------------------------------------------------------------------
-- DIMENSION: year
-- Grain: one row per reporting year (21 rows).
-- label_alignment records which years needed the 2020-21 misalignment repair, so
-- the provenance of every figure is queryable rather than living in a README.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_year (
    year               INTEGER PRIMARY KEY,
    decade             TEXT    NOT NULL,
    source_export      TEXT    NOT NULL,
    label_alignment    TEXT    NOT NULL,
    is_covid_year      INTEGER NOT NULL DEFAULT 0,
    reporting_entities INTEGER NOT NULL,
    -- 0 for 2011: the whole Assault-on-Women column is missing from the source,
    -- so that year's ALL-CRIME total is ~42,000 short. DV itself is intact, so
    -- only cross-crime totals and DV-as-share-of-all-crime are unusable for 2011.
    all_crimes_comparable INTEGER NOT NULL DEFAULT 1,
    coverage_note         TEXT
);

-- -----------------------------------------------------------------------------
-- FACT: reported cases
-- Grain: one row per state x year x crime_type (5,019 rows).
--
-- A raw 0 in this source can mean three different things, and conflating them is
-- how a dashboard becomes confidently wrong. data_quality_flag separates them:
--
--   'entity_not_formed' - the state did not exist yet (Telangana < 2014,
--                         Ladakh < 2020). Averaging these in drags a new state's
--                         mean down by its pre-existence years.
--   'source_gap'        - the measure is missing from the export. Assault on
--                         Women is 0 for all 35 entities in 2011 while sitting at
--                         40,012 in 2010 - a column that failed to carry through.
--   'ok'                - a genuine zero. Lakshadweep really does report 0 DV in
--                         some years, and that is a fact, not a gap.
--
-- include_in_analysis is the single boolean every query filters on, so the rule
-- lives in one place rather than being re-derived in SQL, DAX and Python.
-- -----------------------------------------------------------------------------
CREATE TABLE fact_crimes (
    fact_id                INTEGER PRIMARY KEY AUTOINCREMENT,
    state_clean            TEXT    NOT NULL REFERENCES dim_state(state_clean),
    state_code             TEXT    NOT NULL,
    entity_type            TEXT    NOT NULL,
    region                 TEXT    NOT NULL,
    year                   INTEGER NOT NULL REFERENCES dim_year(year),
    crime_code             TEXT    NOT NULL REFERENCES dim_crime_type(crime_code),
    crime_type             TEXT    NOT NULL,
    cases                  INTEGER NOT NULL CHECK (cases >= 0),
    rate_per_lakh_female   REAL,
    population_2011        INTEGER,
    female_population_2011 INTEGER,
    literacy_rate_2011     REAL,
    is_structural_zero     INTEGER NOT NULL DEFAULT 0,
    is_source_gap          INTEGER NOT NULL DEFAULT 0,
    data_quality_flag      TEXT    NOT NULL DEFAULT 'ok'
                             CHECK (data_quality_flag IN ('ok','entity_not_formed','source_gap')),
    include_in_analysis    INTEGER NOT NULL DEFAULT 1,
    UNIQUE (state_clean, year, crime_code)   -- enforces the declared grain
);

-- Indexes matching the three access patterns the dashboard actually uses:
-- filter by year, filter by crime type, drill into one state.
CREATE INDEX idx_fact_year        ON fact_crimes(year);
CREATE INDEX idx_fact_crime       ON fact_crimes(crime_code);
CREATE INDEX idx_fact_state_year  ON fact_crimes(state_clean, year);
CREATE INDEX idx_fact_analysis    ON fact_crimes(crime_code, year, include_in_analysis);
