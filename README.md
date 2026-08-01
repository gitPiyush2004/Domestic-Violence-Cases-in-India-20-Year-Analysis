# Domestic Violence in India — a 20-Year Analysis (2001–2021)

An end-to-end analytics project on crimes against women in India: raw NCRB extract →
cleaned and **repaired** star schema → SQL analytical layer → interactive dashboard.

The focus crime is **domestic violence (IPC 498A — cruelty by a husband or his
relatives)**, which turns out to be the single largest category of recorded crime
against women in India: **1,909,978 cases, 39.2% of all 4.87M recorded cases** over
21 years.

---

## The headline of this project is a bug, not a chart

The public dataset this project starts from is **silently broken for 2020 and 2021**,
and the break is invisible unless you check. Reading it as published gives you:

| Entity | DV cases 2019 | DV cases 2020 *as published* |
|---|---|---|
| Delhi | 3,792 | **3** |
| Dadra & Nagar Haveli (pop. 344,000) | 3 | **2,557** |

Delhi did not stop having domestic violence, and a union territory of 344,000 people
did not out-report Delhi.

**Root cause.** On 31 Oct 2019 Jammu & Kashmir became a union territory and **Ladakh**
was carved out of it; on 26 Jan 2020 Dadra & Nagar Haveli merged with Daman & Diu. So
NCRB's 2020 table lists 28 states then 8 UTs — J&K moved down into the UT block, Ladakh
added, two western UTs collapsed into one row. Whoever built the CSV pasted that value
block against a label column still generated from the **pre-2019** 36-entity list, where
J&K sits alphabetically among the states at position 9. **Every measure row from
position 9 down is attached to the wrong state name**, and Ladakh's row inherits the
label "Delhi UT".

**The repair is deterministic, not guesswork** — NCRB's 2020 entity order is public
record. It is defended by four independent tests in
[`etl/02_validate_repair.py`](etl/02_validate_repair.py):

| Test | Result |
|---|---|
| Anomaly detection (2020 vs 2017–19 mean) | 16 of 32 entities outside a 0.25x–4x band |
| Profile matching (crime-mix fingerprints, log space) | 2019 control: **34/36** match their own labels. 2020: only **10/36** — but **28/34** match the NCRB order |
| Continuity (YoY swing distribution) | median \|YoY\| **71.2% → 13.9%**; implausible (>60%) jumps **15 → 0** |
| Invariance (all 7 measure totals) | **all deltas zero** — the repair re-labels, it never invents |

Because the repair only moves attribution, **every national figure is identical with or
without it**. Only state-level 2020–21 attribution was ever at risk.

**A second defect:** Assault on Women reads **0 for all 35 entities in 2011**, against
40,012 in 2010 and 45,344 in 2012 — a dropped column. Those cells are flagged and
excluded, and 2011 is marked non-comparable for all-crime totals, which is why the
DV-share series is left **blank** for 2011 rather than printing a false 55.5% spike.

---

## Repository layout

```
data/
  raw/                        untouched Kaggle extract (736 x 9) + source PDF
  reference/state_master.csv  36 entities: region, Census 2011 population,
                              sex ratio, literacy, boundary-change notes
  processed/                  the star schema (built, not hand-edited)
etl/
  01_clean_and_wrangle.py     the 10-step pipeline (documented step by step)
  02_validate_repair.py       the four-test proof of the 2020-21 repair
  etl_run_log.txt             committed run log
  repair_validation_report.txt
sql/
  00_schema.sql               star schema DDL with grain + integrity constraints
  01_kpi_headline.sql         the six KPI tiles
  02_trend_window_functions.sql  LAG, moving average, rank momentum, CAGR
  03_abc_classification.sql      Pareto / ABC segmentation
  04_risk_zones_case.sql         CASE-based risk banding + priority matrix
  05_joins_deepdive.sql          multi-table joins, self-joins, correlated subqueries
  06_data_quality_audit.sql      12 assertions, each returns 0 rows when healthy
  build_and_run.py            builds the DB and writes QUERY_RESULTS.md
  QUERY_RESULTS.md            committed real outputs of all 21 queries
powerbi/
  DomesticViolence.pbip       Power BI project (PBIP/TMDL - plain text, diffable)
  .SemanticModel/definition/  4 tables, 3 relationships, 30 measures as TMDL
  m/                          the Power Query M for each query, annotated
  dax/                        the 30 measures grouped by purpose, annotated
excel/
  CleanCrimeData.bas          VBA cleaning macro - the Excel-side implementation
                              of the same normalise/unpivot/flag contract
dashboard/
  index.html                  5-page interactive dashboard, zero dependencies
  build_data.py               serialises processed/ into data.js
  data.js                     generated - never hand-edited
docs/
  DASHBOARD_GUIDE.md          page-by-page build spec, theme, mobile layouts,
                              and the figures to verify the build against
  INTERVIEW_PREP.md           walkthrough, the numbers, and the hard questions
```

## The Power BI layer

The model is committed as **PBIP/TMDL**, not a binary `.pbix` — every table, measure
and relationship is a plain-text file that reviews in a pull request. Open
`powerbi/DomesticViolence.pbip`, point the `RepoRoot` parameter at your clone, refresh.
`docs/DASHBOARD_GUIDE.md` has the page-by-page spec.

Three decisions worth knowing before reading the DAX:

- **Power Query reads `processed/`, not `raw/`.** The 2020-21 repair lives in the ETL
  and nowhere else. Re-implementing it in M would put one business rule in two
  languages and guarantee they drift.
- **No date table.** The grain is annual. A marked calendar table would allow
  `SAMEPERIODLASTYEAR` against 21 synthetic timestamps — correct answers, implied
  precision the source does not have. Year-over-year is an explicit integer offset.
- **`[DV Share %]` returns blank for 2011.** The all-crime denominator is short that
  year because Assault on Women is missing, which would print a ~55% share against a
  39.2% baseline. The measure refuses rather than lying, and the line shows a gap.
  A dashboard should be silent where the data is unsound rather than plausible.

## Reproduce it

```bash
python3 etl/01_clean_and_wrangle.py    # clean, repair, reshape -> data/processed/
python3 etl/02_validate_repair.py      # prove the repair
python3 sql/build_and_run.py           # build SQLite, run 21 queries, run 12 checks
python3 dashboard/build_data.py        # regenerate dashboard/data.js
```

Then open `dashboard/index.html`. Nothing needs installing beyond `pandas` and `numpy`;
the dashboard has no libraries at all.

---

## The data model

A star schema, not one wide sheet. The source arrives with one column per crime
(`Rape`, `K&A`, `DD`, `AoW`, `AoM`, `DV`, `WT`), which cannot answer "which crime type
grew fastest" without seven near-duplicate measures. Unpivoting makes crime type a real
dimension.

- **`fact_crimes`** — 5,019 rows at `state × year × crime_type`
- **`dim_state`** (36) · **`dim_year`** (21) · **`dim_crime_type`** (7)

**Three kinds of zero** are separated by `data_quality_flag`, because conflating them is
how a dashboard becomes confidently wrong:

| Flag | Meaning | Example |
|---|---|---|
| `entity_not_formed` | the entity did not exist yet | Telangana < 2014, Ladakh < 2020 |
| `source_gap` | the measure is missing from the export | Assault on Women, 2011 |
| `ok` | a genuine zero | Lakshadweep really reports 0 DV in some years |

`include_in_analysis` is the single boolean every query filters on, so the rule lives in
one place instead of being re-derived in SQL, DAX and Python separately.

## Two segmentations that disagree — on purpose

**ABC classification** (volume): **8 of 36 entities carry 72.9%** of all recorded
domestic violence. That is the most actionable number in the project — a national
intervention needs 8 well-funded programmes, not 36.

**Risk zones** (intensity): cases per lakh women, banded at the **quartiles** of the
2021 distribution (not round numbers, so the bands survive a data refresh).

The two name different states, and the gap is the insight:

- **West Bengal** leads on volume (302,143 cases) — but ranks 6th on intensity.
- **Assam** has the highest 2021 intensity (**84.8 per lakh women**, ~1.9× West Bengal).
- Class **C + Critical** entities are small but intense — buried entirely by any
  volume-only ranking.

## Selected findings

1. Domestic violence is **39.2%** of all recorded crimes against women — more than
   rape, dowry deaths and insult to modesty combined.
2. Reported cases compounded at **5.24%/yr**, 49,032 (2001) → 136,234 (2021), **+178%**.
3. **2020 fell 11.0%**, then **2021 rebounded +22.1%** — best read as lockdown
   suppressing *reporting access*, not violence, with the backlog arriving in 2021.
4. **Dowry deaths are flat** — 6,738 (2001) → 6,753 (2021), CAGR 0.01% — while every
   other head grew. Deaths are the hardest category to under-report, so that flatness
   argues the growth elsewhere is substantially a *reporting-propensity* story.
5. Fastest-growing heads are **kidnapping (8.9%/yr)** and **trafficking (11.9%/yr)**,
   both well above domestic violence.

## Honest limitations

- NCRB counts cases **reported to police**, not incidents. NFHS-5 puts spousal violence
  prevalence near 1 in 3 ever-married women — orders of magnitude above anything here.
- Rates use a **fixed Census 2011** denominator (the only census-grade figure in the
  window), so they are a comparable index, not a live incidence rate.
- Three series carry documented breaks — **AoW** (2011 gap, 2013 statutory widening),
  **AoM** (unexplained 2014/2017 steps), **WT** (2011 reporting change). Do not trend
  across those years.
- J&K case counts before 2020 include the Ladakh districts while its denominator
  excludes them (~2% effect on that one entity).

## Source

NCRB *Crime in India* annual reports, 2001–2021, via a Kaggle mirror
(`data/raw/CrimesOnWomenData.csv`, 736 rows × 9 columns). Denominators from Census 2011.

---

### Status

Data pipeline, repair proof, SQL layer and interactive dashboard are complete and
verified (all 12 data-quality assertions pass). The Power BI semantic model
(PBIP/TMDL — 4 tables, 3 relationships, 30 measures), the annotated Power Query M and
DAX references, the Excel cleaning macro and the `docs/` write-ups are in.

Outstanding: the Power BI **report pages** ship as a single blank canvas. The model is
done and the layout is specified page by page in `docs/DASHBOARD_GUIDE.md`, but the
visuals themselves still need to be dragged in Power BI Desktop — report layout is the
one part of the stack that is genuinely faster to build by hand than to author as JSON.
