"""
01_clean_and_wrangle.py
=======================
Cleans, repairs and reshapes the raw NCRB "Crimes on Women" extract (2001-2021)
into a star schema that both SQL and Power BI consume.

This script is the reproducible twin of the Excel / Power Query stage of the
project. Every transform maps 1:1 to a documented Power Query step in
`powerbi/power_query_m/`, so the Python and Power BI lineage cannot drift.

Pipeline
--------
  raw/CrimesOnWomenData.csv (736 x 9, wide)
      |
      |-- STEP 1  drop the unnamed export index column
      |-- STEP 2  standardise 70 raw state spellings -> 36 canonical entities
      |-- STEP 3  REPAIR the 2020-21 row misalignment (see repair_2020_21)
      |-- STEP 4  harmonise entities across the 2019-20 reorganisation
      |-- STEP 5  validate: dtypes, negatives, duplicate grain, panel coverage
      |-- STEP 6  unpivot 7 crime columns -> long fact grain
      |-- STEP 7  conform to the state master (region, population, sex ratio)
      |-- STEP 8  flag structural zeros vs true zeros
      |-- STEP 9  derive rate per lakh female population (NCRB convention)
      |-- STEP 10 build dimensions, aggregates, ABC classification, risk bands
      v
  processed/*.csv

Run:  python3 etl/01_clean_and_wrangle.py
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
REF = ROOT / "data" / "reference"
OUT = ROOT / "data" / "processed"
OUT.mkdir(parents=True, exist_ok=True)

# NCRB's abbreviated headers -> analyst-facing name + the IPC section behind it.
CRIME_MAP = {
    "DV": ("Domestic Violence", "Cruelty by Husband or his Relatives (IPC 498A)"),
    "AoW": ("Assault on Women", "Assault on Women with Intent to Outrage Modesty (IPC 354)"),
    "K&A": ("Kidnapping & Abduction", "Kidnapping and Abduction of Women (IPC 363-369)"),
    "Rape": ("Rape", "Rape (IPC 376)"),
    "AoM": ("Insult to Modesty", "Insult to the Modesty of Women (IPC 509)"),
    "DD": ("Dowry Deaths", "Dowry Deaths (IPC 302 / 304B)"),
    "WT": ("Women Trafficking", "Importation of Girls / Trafficking (IPC 366B, 372, 373)"),
}
CRIME_COLS = list(CRIME_MAP.keys())

TELANGANA_FORMED = 2014   # carved out of Andhra Pradesh, 02-Jun-2014
LADAKH_FORMED = 2020      # carved out of J&K, 31-Oct-2019; NCRB reports it from 2020
MERGER_YEAR = 2020        # D & N Haveli + Daman & Diu merged, 26-Jan-2020

# (measure, year) cells that are missing from the source rather than genuinely
# zero. Assault on Women is 0 for ALL 35 entities in 2011 while sitting at 40,012
# in 2010 and 45,344 in 2012 - a whole column failed to carry through the export.
# Left as zeros these would read as "assaults stopped for one year" and would also
# understate the 2011 all-crime total by ~42,000 cases.
SOURCE_GAPS = [("AoW", 2011)]

# Documented discontinuities. These are real changes in what NCRB counted, not
# data faults, so they are annotated rather than repaired - but any trend drawn
# across one of these years is measuring a definition, not a behaviour.
SERIES_BREAKS = {
    "AoW": "Source gap in 2011 (all entities zero, excluded). The +56% step in 2013 "
           "follows the Criminal Law (Amendment) Act 2013, which widened IPC 354.",
    "AoM": "Unstable series: +74% in 2014 and -73% in 2017 with no corresponding "
           "statutory change. Treat IPC 509 levels as indicative; do not trend "
           "across 2016/2017.",
    "WT": "Series break in 2011 (36 -> 2,435 cases) from a widening of trafficking "
          "reporting. Pre-2011 and post-2011 figures are not comparable.",
    "DV": "No known break. Continuous IPC 498A reporting across all 21 years.",
    "Rape": "Definition of rape widened by the Criminal Law (Amendment) Act 2013; "
            "the 2013 step (+5%) is modest but the basis changed.",
    "K&A": "No known break.",
    "DD": "No known break.",
}

# ---------------------------------------------------------------------------
# The entity order NCRB uses in its 2020 and 2021 tables: 28 states
# alphabetically, then 8 UTs alphabetically. Note what changed after 2019:
#   - Jammu & Kashmir moved out of the state block and into the UT block
#   - Ladakh appeared as a brand-new UT
#   - D & N Haveli and Daman & Diu collapsed into one row
# The Kaggle CSV pasted these value rows against a label column still built
# from the OLD 36-entity list, which is what silently corrupts 2020 and 2021.
# ---------------------------------------------------------------------------
NCRB_ORDER_2020 = [
    "Andhra Pradesh", "Arunachal Pradesh", "Assam", "Bihar", "Chhattisgarh",
    "Goa", "Gujarat", "Haryana", "Himachal Pradesh", "Jharkhand", "Karnataka",
    "Kerala", "Madhya Pradesh", "Maharashtra", "Manipur", "Meghalaya",
    "Mizoram", "Nagaland", "Odisha", "Punjab", "Rajasthan", "Sikkim",
    "Tamil Nadu", "Telangana", "Tripura", "Uttar Pradesh", "Uttarakhand",
    "West Bengal",
    "A & N Islands", "Chandigarh", "D & N Haveli and Daman & Diu", "Delhi UT",
    "Jammu & Kashmir", "Ladakh", "Lakshadweep", "Puducherry",
]

log_lines: list[str] = []


def log(msg: str = "") -> None:
    print(msg)
    log_lines.append(msg)


# ---------------------------------------------------------------------------
# STEP 1 - Load raw, drop the export artefact column
# ---------------------------------------------------------------------------
def load_raw() -> pd.DataFrame:
    df = pd.read_csv(RAW / "CrimesOnWomenData.csv")

    # Kaggle exports pandas' RangeIndex as an unnamed first column. It carries no
    # information and would be mistaken for a key, so it goes first.
    artefacts = [c for c in df.columns if c.startswith("Unnamed") or c.strip() == ""]
    df = df.drop(columns=artefacts)

    log("STEP 1  Load raw")
    log(f"        rows={len(df)}  cols={len(df.columns)}  dropped index artefact: {artefacts}")
    log(f"        columns: {list(df.columns)}")
    log()
    return df


# ---------------------------------------------------------------------------
# STEP 2 - State name standardisation
# ---------------------------------------------------------------------------
def standardise_state(raw: str) -> str:
    """Collapse a raw state string to its canonical Title Case form.

    The source is two stitched exports with different conventions:
      2001-2010  ALL CAPS, ampersands spaced   -> 'D & N HAVELI', 'A & N ISLANDS'
      2011-2021  Title Case, ampersands tight  -> 'D&N Haveli',   'A & N Islands'

    Left uncleaned this inflates 36 real entities into 70 dimension members, and
    every state total silently splits in two at the 2010/2011 boundary.
    """
    s = re.sub(r"\s+", " ", str(raw).strip())   # collapse repeated whitespace
    s = re.sub(r"\s*&\s*", " & ", s)            # normalise ampersands: D&N -> D & N
    s = s.title()                               # ALL CAPS and Title Case converge
    return {"Delhi Ut": "Delhi UT"}.get(s, s)   # .title() mangles the acronym


def clean_states(df: pd.DataFrame) -> pd.DataFrame:
    before = df["State"].nunique()
    df["state_clean"] = df["State"].map(standardise_state)
    after = df["state_clean"].nunique()

    log("STEP 2  Standardise state names")
    log(f"        distinct raw spellings : {before}")
    log(f"        distinct after cleaning: {after}  (collapsed {before - after})")

    collapsed = (
        df.groupby("state_clean")["State"]
        .agg(lambda s: sorted(set(s)))
        .loc[lambda s: s.map(len) > 1]
    )
    log(f"        {len(collapsed)} canonical names absorbed >1 raw spelling, e.g.:")
    for name, variants in list(collapsed.items())[:4]:
        log(f"          {variants}  ->  '{name}'")
    log()
    return df


# ---------------------------------------------------------------------------
# STEP 3 - Repair the 2020-21 row misalignment
# ---------------------------------------------------------------------------
def repair_2020_21(df: pd.DataFrame) -> pd.DataFrame:
    """Re-attach the 2020 and 2021 measure rows to the correct entity.

    THE BUG
    -------
    In the 2020 and 2021 blocks the measures belong to a DIFFERENT entity than
    the label on their row. Reading the file as-is produces nonsense:

        Delhi          DV  3,792 (2019) ->     3 (2020)   -99.9%
        D & N Haveli   DV      3 (2019) -> 2,557 (2020)  +85,133%

    Delhi does not stop having domestic violence, and a UT of 344k people does
    not out-report Delhi.

    ROOT CAUSE
    ----------
    On 31-Oct-2019 J&K was reorganised: it became a UT and Ladakh was carved out
    of it. On 26-Jan-2020 D & N Haveli merged with Daman & Diu. So NCRB's 2020
    table has 28 states + 8 UTs, with J&K moved into the UT block, Ladakh added,
    and the two western UTs collapsed into one row.

    Whoever assembled the Kaggle CSV pasted that value block against a label
    column still generated from the pre-2019 list, where J&K sits alphabetically
    among the states at position 9. Every measure row from position 9 onward is
    therefore attached to the wrong label, and Ladakh's row inherits the label
    'Delhi UT'.

    EVIDENCE (all reproducible via etl/02_validate_repair.py)
    --------------------------------------------------------
    1. Positional: the 36 measure rows match NCRB_ORDER_2020 exactly, and that
       ordering is documented public record, not a guess.
    2. Profile matching: nearest-neighbour matching each 2020 measure row against
       each state's 2017-19 mean profile recovers NCRB_ORDER_2020, not the file's
       own labels.
    3. Continuity: repairing collapses median |YoY| for 2019->2020 from 71.2% to
       13.9% and removes all 15 implausible (>60%) jumps.
    4. Invariance: national totals are byte-identical before and after, because
       this only re-labels rows. That is the signature of a label bug, and it
       also means every national-level figure in this project is unaffected.

    2001-2019 rows are untouched - the 2019 block passes the same profile test
    in place (34/36), so the misalignment is confined to the last two years.
    """
    log("STEP 3  Repair 2020-21 row misalignment")

    frames, repaired_years = [], []
    for year, block in df.groupby("Year", sort=True):
        block = block.reset_index(drop=True)
        if year < MERGER_YEAR:
            frames.append(block)
            continue

        if len(block) != len(NCRB_ORDER_2020):
            raise ValueError(
                f"{year}: expected {len(NCRB_ORDER_2020)} rows to apply the NCRB "
                f"ordering, found {len(block)}. Refusing to guess."
            )

        moved = int((block.state_clean.values != np.array(NCRB_ORDER_2020)).sum())
        block["state_original_label"] = block.state_clean
        block["state_clean"] = NCRB_ORDER_2020
        block["is_repaired"] = True
        frames.append(block)
        repaired_years.append((year, moved))

        if year == MERGER_YEAR:  # print the audit trail once
            shown = block.loc[
                block.state_original_label != block.state_clean,
                ["state_original_label", "state_clean", "DV"],
            ]
            log(f"        {year}: {moved}/{len(block)} rows re-attached. Sample of the remap:")
            for r in shown.head(8).itertuples():
                log(f"          label '{r.state_original_label:<28s}' "
                    f"-> actually '{r.state_clean}'  (DV={r.DV:,})")
            log(f"          ... {len(shown) - 8} more")

    for year, moved in repaired_years:
        log(f"        repaired {year}: {moved} of {len(NCRB_ORDER_2020)} rows re-attached")

    out = pd.concat(frames, ignore_index=True)
    out["is_repaired"] = out.get("is_repaired", pd.Series(dtype=object)).fillna(False).astype(bool)
    out["state_original_label"] = out.state_original_label.fillna(out.state_clean)

    # Invariance check: relabelling must not change a single measure total.
    for col in CRIME_COLS:
        assert df[col].sum() == out[col].sum(), f"repair altered {col} totals"
    log(f"        invariance check: all 7 measure totals unchanged -> PASS")
    log(f"        new entity introduced by the repair: Ladakh "
        f"(from {LADAKH_FORMED}, {int(out[(out.state_clean == 'Ladakh')].DV.sum())} DV cases)")
    log()
    return out


# ---------------------------------------------------------------------------
# STEP 4 - Entity harmonisation across the reorganisation
# ---------------------------------------------------------------------------
def harmonise_entities(df: pd.DataFrame) -> pd.DataFrame:
    """Make the 21-year panel comparable across boundary changes.

    D & N Haveli and Daman & Diu were separate UTs to 2019 and one UT from 2020.
    A series that splits in 2020 cannot be trended, so the two predecessors are
    summed for 2001-2019 into the post-merger entity. This is additive, so no
    national total moves.

    Telangana (2014) and Ladakh (2020) are NOT back-filled - they genuinely did
    not exist earlier. They are handled with structural-zero flags in STEP 8 so
    that "no data" never averages in as "zero cases".
    """
    log("STEP 4  Harmonise entities across the 2019-20 reorganisation")
    merged_name = "D & N Haveli and Daman & Diu"
    predecessors = ["D & N Haveli", "Daman & Diu"]

    mask = df.state_clean.isin(predecessors)
    log(f"        merging {predecessors} -> '{merged_name}' for {df.loc[mask, 'Year'].min()}-"
        f"{df.loc[mask, 'Year'].max()} ({int(mask.sum())} rows -> "
        f"{df.loc[mask, 'Year'].nunique()} rows)")
    df.loc[mask, "state_clean"] = merged_name

    agg = {c: "sum" for c in CRIME_COLS}
    agg["state_original_label"] = lambda s: " + ".join(sorted(set(s)))
    agg["is_repaired"] = "max"
    df = df.groupby(["state_clean", "Year"], as_index=False).agg(agg)

    log(f"        rows after harmonisation: {len(df)}")
    log(f"        distinct entities        : {df.state_clean.nunique()}")
    log()
    return df


# ---------------------------------------------------------------------------
# STEP 5 - Validation gate
# ---------------------------------------------------------------------------
def validate(df: pd.DataFrame) -> None:
    log("STEP 5  Validation gate")

    nulls = int(df[CRIME_COLS].isna().sum().sum())
    negatives = int((df[CRIME_COLS] < 0).sum().sum())
    non_int = [c for c in CRIME_COLS if not pd.api.types.is_integer_dtype(df[c])]
    dupes = int(df.duplicated(["state_clean", "Year"]).sum())

    log(f"        null measures        : {nulls}")
    log(f"        negative counts      : {negatives}")
    log(f"        non-integer measures : {non_int or 'none'}")
    log(f"        duplicate state-year : {dupes}")
    log(f"        year range           : {df.Year.min()}-{df.Year.max()} "
        f"({df.Year.nunique()} years)")

    grid = pd.crosstab(df.state_clean, df.Year)
    gaps = [(st, int(yr)) for st in grid.index for yr in grid.columns if grid.at[st, yr] == 0]
    log(f"        panel coverage       : {len(df)}/{grid.shape[0] * grid.shape[1]} cells "
        f"({len(gaps)} gaps)")
    for st in sorted({s for s, _ in gaps}):
        yrs = sorted(y for s, y in gaps if s == st)
        log(f"          gap: {st:<22s} absent {min(yrs)}-{max(yrs)} ({len(yrs)} yrs)")

    assert nulls == 0 and negatives == 0 and dupes == 0, "validation gate failed"
    log("        gate: PASS")
    log()


# ---------------------------------------------------------------------------
# STEP 6 - Unpivot wide -> long
# ---------------------------------------------------------------------------
def unpivot(df: pd.DataFrame) -> pd.DataFrame:
    """One row per state-year-crime_type.

    The wide layout cannot answer "which crime type grew fastest" without seven
    near-identical measures. Long form makes crime type a real dimension, so one
    measure plus a slicer replaces seven measures in both SQL and DAX.
    """
    long = df.melt(
        id_vars=["state_clean", "Year"],
        value_vars=CRIME_COLS,
        var_name="crime_code",
        value_name="cases",
    )
    long["crime_type"] = long.crime_code.map(lambda c: CRIME_MAP[c][0])
    long = long.rename(columns={"Year": "year"})

    log("STEP 6  Unpivot to long fact grain")
    log(f"        {len(df)} wide rows x {len(CRIME_COLS)} crime columns -> {len(long)} fact rows")
    log(f"        grain: state_clean + year + crime_type")
    log()
    return long


# ---------------------------------------------------------------------------
# STEP 7 - Conform to the state master
# ---------------------------------------------------------------------------
def conform(long: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    master = pd.read_csv(REF / "state_master.csv")

    # Census 2011 publishes sex ratio as females per 1000 males, so
    # female share of the population = ratio / (1000 + ratio).
    master["female_population_2011"] = (
        master.population_2011 * master.sex_ratio_2011 / (1000 + master.sex_ratio_2011)
    ).round().astype(int)

    log("STEP 7  Conform to state master")
    orphan_fact = sorted(set(long.state_clean) - set(master.state_clean))
    orphan_dim = sorted(set(master.state_clean) - set(long.state_clean))
    log(f"        fact entities with no master row : {orphan_fact or 'none'}")
    log(f"        master rows with no fact data    : {orphan_dim or 'none'}")
    assert not orphan_fact, f"referential integrity broken: {orphan_fact}"

    long = long.merge(
        master[["state_clean", "state_code", "entity_type", "region", "population_2011",
                "female_population_2011", "literacy_rate_2011"]],
        on="state_clean", how="left", validate="many_to_one",
    )
    log(f"        joined {len(master)} master rows; referential integrity: PASS")
    log()
    return long, master


# ---------------------------------------------------------------------------
# STEP 8 - Structural zeros
# ---------------------------------------------------------------------------
def flag_zeros(long: pd.DataFrame) -> pd.DataFrame:
    """Separate the three things a 0 can mean in this file.

    A single `cases = 0` hides three completely different facts, and treating
    them alike is how a dashboard ends up confidently wrong:

      entity_not_formed - the state did not exist yet (Telangana pre-2014,
                          Ladakh pre-2020). Averaging these in drags a new
                          state's mean down by its pre-existence years.
      source_gap        - the measure is missing from the export (AoW 2011).
                          Reads as "assaults stopped for a year" if trusted.
      ok                - a genuine zero: the entity existed and reported none.
                          Lakshadweep really does report 0 DV in some years.

    `include_in_analysis` is the single boolean every downstream query filters
    on, so the rule lives in one place instead of being re-derived in SQL, DAX
    and Python separately.
    """
    long["is_structural_zero"] = (
        ((long.state_clean == "Telangana") & (long.year < TELANGANA_FORMED))
        | ((long.state_clean == "Ladakh") & (long.year < LADAKH_FORMED))
    )
    long["is_source_gap"] = False
    for code, year in SOURCE_GAPS:
        long.loc[(long.crime_code == code) & (long.year == year), "is_source_gap"] = True

    long["data_quality_flag"] = np.select(
        [long.is_structural_zero, long.is_source_gap],
        ["entity_not_formed", "source_gap"],
        default="ok",
    )
    long["include_in_analysis"] = long.data_quality_flag == "ok"

    log("STEP 8  Classify zeros (entity_not_formed / source_gap / ok)")
    for flag, n in long.data_quality_flag.value_counts().items():
        log(f"        {flag:<20s} {n:>5} fact rows")
    for code, year in SOURCE_GAPS:
        affected = int(((long.crime_code == code) & (long.year == year)).sum())
        log(f"        source gap: {code} {year} - {affected} rows excluded "
            f"({CRIME_MAP[code][0]} is 0 for every entity that year)")
    log(f"        genuine zeros retained: "
        f"{int(((long.cases == 0) & long.include_in_analysis).sum())} rows")
    log(f"        analysis rows: {int(long.include_in_analysis.sum())}")
    log()
    return long


# ---------------------------------------------------------------------------
# STEP 9 - NCRB-convention rate
# ---------------------------------------------------------------------------
def add_rates(long: pd.DataFrame) -> pd.DataFrame:
    """Rate per 100,000 (one lakh) female population.

    Absolute counts answer "where are the most cases", which is mostly a
    question about population size. The rate answers "where is a woman most
    exposed", which is the decision-relevant question. The denominator is fixed
    at Census 2011 - the only census-grade figure inside the window - so this is
    a comparable index across states, not a live incidence rate.
    """
    long["rate_per_lakh_female"] = (
        long.cases / long.female_population_2011 * 100_000
    ).round(2)
    log("STEP 9  Derive rate per lakh female population")
    log("        denominator: Census 2011 female population (fixed across years)")
    log()
    return long


# ---------------------------------------------------------------------------
# STEP 10 - Dimensions, aggregates, ABC, risk bands
# ---------------------------------------------------------------------------
def abc_classify(df: pd.DataFrame, value_col: str, key_col: str) -> pd.DataFrame:
    """Pareto / ABC segmentation on contribution to national volume.

      A = entities covering the first 70% of cumulative volume  -> act first
      B = the next 20%                                          -> monitor
      C = the tail 10%                                          -> report only

    Ranking by contribution rather than by raw count is what makes this
    actionable: it says how few states you must move to move the national number.
    """
    out = df.sort_values(value_col, ascending=False).reset_index(drop=True)
    out["share_pct"] = (out[value_col] / out[value_col].sum() * 100).round(2)
    out["cumulative_pct"] = out.share_pct.cumsum().round(2)
    out["rank"] = np.arange(1, len(out) + 1)

    # The entity that CROSSES a boundary belongs to the class it completes,
    # otherwise the 70% cut lands mid-entity and class A under-covers.
    prev_cum = out.cumulative_pct.shift(1).fillna(0)
    out["abc_class"] = np.where(prev_cum < 70, "A", np.where(prev_cum < 90, "B", "C"))
    out["abc_label"] = out.abc_class.map({
        "A": "A - Critical (top 70% of volume)",
        "B": "B - Moderate (next 20%)",
        "C": "C - Low (tail 10%)",
    })
    return out[[key_col, value_col, "share_pct", "cumulative_pct", "rank",
                "abc_class", "abc_label"]]


def build_outputs(wide: pd.DataFrame, long: pd.DataFrame, master: pd.DataFrame) -> None:
    log("STEP 10 Build dimensions and aggregates")
    analysis = long[long.include_in_analysis]

    # ---- dim_crime_type -----------------------------------------------------
    dim_crime = pd.DataFrame(
        [{"crime_code": k, "crime_type": v[0], "ipc_section": v[1]} for k, v in CRIME_MAP.items()]
    )
    totals = analysis.groupby("crime_type").cases.sum()
    dim_crime["total_cases_2001_2021"] = dim_crime.crime_type.map(totals)
    dim_crime["share_of_all_crime_pct"] = (
        dim_crime.total_cases_2001_2021 / dim_crime.total_cases_2001_2021.sum() * 100
    ).round(2)
    first = analysis[analysis.year == 2001].groupby("crime_type").cases.sum()
    last = analysis[analysis.year == 2021].groupby("crime_type").cases.sum()
    dim_crime["cases_2001"] = dim_crime.crime_type.map(first)
    dim_crime["cases_2021"] = dim_crime.crime_type.map(last)
    dim_crime["cagr_pct"] = (
        ((dim_crime.cases_2021 / dim_crime.cases_2001) ** (1 / 20) - 1) * 100
    ).round(2)
    dim_crime["is_focus_crime"] = dim_crime.crime_type.eq("Domestic Violence")
    dim_crime["series_break_note"] = dim_crime.crime_code.map(SERIES_BREAKS)
    dim_crime["is_comparable_series"] = ~dim_crime.crime_code.isin(["AoW", "AoM", "WT"])
    dim_crime = dim_crime.sort_values("total_cases_2001_2021", ascending=False)

    # ---- dim_year -----------------------------------------------------------
    dim_year = pd.DataFrame({"year": sorted(long.year.unique())})
    dim_year["decade"] = np.where(dim_year.year <= 2010, "2001-2010", "2011-2021")
    dim_year["source_export"] = np.where(
        dim_year.year <= 2010, "Export A (ALL CAPS labels)", "Export B (Title Case labels)")
    dim_year["label_alignment"] = np.where(
        dim_year.year >= MERGER_YEAR, "Repaired (NCRB 2020 entity order)", "As published")
    dim_year["is_covid_year"] = dim_year.year.isin([2020, 2021])
    dim_year["reporting_entities"] = dim_year.year.map(wide.groupby("Year").state_clean.nunique())
    # 2011 is missing the whole Assault-on-Women column, so its ALL-CRIME total is
    # ~42,000 short. DV itself is intact that year; only cross-crime totals and
    # DV-as-share-of-all-crime are unusable for 2011.
    gap_years = {y for _, y in SOURCE_GAPS}
    dim_year["all_crimes_comparable"] = ~dim_year.year.isin(gap_years)
    dim_year["coverage_note"] = np.where(
        dim_year.year.isin(gap_years),
        "Assault on Women missing from the source; all-crime total understated",
        "Complete across all 7 crime heads",
    )

    # ---- DV slices ----------------------------------------------------------
    dv = long[long.crime_type == "Domestic Violence"]
    dv_an = dv[dv.include_in_analysis]

    dim_state = master.copy()
    dim_state["dv_total_cases"] = dim_state.state_clean.map(
        dv_an.groupby("state_clean").cases.sum()).fillna(0).astype(int)
    dim_state["dv_cases_2021"] = dim_state.state_clean.map(
        dv[dv.year == 2021].set_index("state_clean").cases).fillna(0).astype(int)
    dim_state["dv_cases_2001"] = dim_state.state_clean.map(
        dv[dv.year == 2001].set_index("state_clean").cases).fillna(0).astype(int)
    dim_state["all_crime_total"] = dim_state.state_clean.map(
        analysis.groupby("state_clean").cases.sum()).fillna(0).astype(int)
    dim_state["dv_share_of_state_crime_pct"] = (
        dim_state.dv_total_cases / dim_state.all_crime_total * 100).round(2)
    dim_state["dv_rate_2021"] = (
        dim_state.dv_cases_2021 / dim_state.female_population_2011 * 100_000).round(2)
    dim_state["dv_rate_20yr_avg"] = dim_state.state_clean.map(
        dv_an.groupby("state_clean").rate_per_lakh_female.mean()).round(2)
    dim_state["years_observed"] = dim_state.state_clean.map(
        dv_an.groupby("state_clean").year.nunique()).fillna(0).astype(int)
    dim_state["first_year_observed"] = dim_state.state_clean.map(
        dv_an.groupby("state_clean").year.min())

    # CAGR over each entity's OWN observed window, so Telangana, Ladakh and
    # Delhi are not penalised for entering the panel late.
    def cagr(state: str) -> float:
        obs = dv_an[(dv_an.state_clean == state) & (dv_an.cases > 0)]
        if len(obs) < 2:
            return np.nan
        f, l = obs.loc[obs.year.idxmin()], obs.loc[obs.year.idxmax()]
        span = l.year - f.year
        if span <= 0 or f.cases <= 0:
            return np.nan
        return round(((l.cases / f.cases) ** (1 / span) - 1) * 100, 2)

    dim_state["dv_cagr_pct"] = dim_state.state_clean.map(cagr)
    dim_state["trend_direction"] = np.select(
        [dim_state.dv_cagr_pct > 2, dim_state.dv_cagr_pct < -2],
        ["Worsening", "Improving"], default="Stable")

    # ---- risk bands: quartiles of the 2021 rate distribution ---------------
    rates = dim_state.loc[dim_state.dv_cases_2021 > 0, "dv_rate_2021"]
    q1, q2, q3 = (round(float(rates.quantile(q)), 1) for q in (0.25, 0.50, 0.75))
    log(f"        risk-band cut points from the 2021 rate distribution: "
        f"Q1={q1}  median={q2}  Q3={q3}")

    def band(rate: float) -> str:
        if rate >= q3:
            return "Critical"
        if rate >= q2:
            return "High"
        if rate >= q1:
            return "Moderate"
        return "Low"

    dim_state["risk_zone"] = dim_state.dv_rate_2021.map(band)
    (OUT / "risk_thresholds.json").write_text(json.dumps(
        {"metric": "dv_rate_per_lakh_female_2021", "method": "quartiles of the 2021 distribution",
         "moderate_min": q1, "high_min": q2, "critical_min": q3}, indent=2) + "\n")

    # ---- ABC on 20-year DV volume ------------------------------------------
    abc = abc_classify(
        dim_state.loc[dim_state.dv_total_cases > 0, ["state_clean", "dv_total_cases"]],
        "dv_total_cases", "state_clean")
    dim_state = dim_state.merge(abc.drop(columns=["dv_total_cases"]), on="state_clean", how="left")
    dim_state["abc_class"] = dim_state.abc_class.fillna("C")
    dim_state["abc_label"] = dim_state.abc_label.fillna("C - Low (tail 10%)")

    # ---- national trend -----------------------------------------------------
    nat = analysis.groupby(["year", "crime_type"], as_index=False).cases.sum()
    trend = (analysis.groupby("year", as_index=False).cases.sum()
             .rename(columns={"cases": "all_crimes"})
             .merge(nat[nat.crime_type == "Domestic Violence"][["year", "cases"]]
                    .rename(columns={"cases": "dv_cases"}), on="year"))
    # DV share needs a complete all-crime denominator. 2011 is missing the whole
    # AoW column, so its share would read 55.5% against ~46% either side - an
    # artefact. Blanked rather than plotted, so the chart cannot mislead.
    gap_years = {y for _, y in SOURCE_GAPS}
    trend["all_crimes_comparable"] = ~trend.year.isin(gap_years)
    trend["dv_share_pct"] = (trend.dv_cases / trend.all_crimes * 100).round(2)
    trend.loc[trend.year.isin(gap_years), ["dv_share_pct", "all_crimes"]] = np.nan
    trend["dv_yoy_pct"] = (trend.dv_cases.pct_change() * 100).round(2)
    trend["all_yoy_pct"] = (trend.all_crimes.pct_change() * 100).round(2)
    trend["dv_index_2001"] = (trend.dv_cases / trend.dv_cases.iloc[0] * 100).round(1)
    trend["dv_3yr_moving_avg"] = trend.dv_cases.rolling(3).mean().round(0)
    fem = master.female_population_2011.sum()
    trend["dv_rate_per_lakh_female"] = (trend.dv_cases / fem * 100_000).round(2)

    # ---- region rollup ------------------------------------------------------
    region = (dv_an.groupby("region")
              .agg(dv_total=("cases", "sum"), entities=("state_clean", "nunique"))
              .reset_index())
    region["female_population"] = region.region.map(
        master.groupby("region").female_population_2011.sum())
    region["dv_per_lakh_female_20yr"] = (
        region.dv_total / region.female_population * 100_000).round(1)
    region["share_of_national_pct"] = (region.dv_total / region.dv_total.sum() * 100).round(2)
    region = region.sort_values("dv_total", ascending=False)

    # ---- matrices for heatmap / composition --------------------------------
    mix = nat.pivot(index="year", columns="crime_type", values="cases").reset_index()
    heat = (dv.pivot_table(index="state_clean", columns="year", values="cases", aggfunc="sum")
            .reindex(dim_state.sort_values("dv_total_cases", ascending=False).state_clean))

    outputs = {
        "fact_crimes_long.csv": long,
        "crimes_clean_wide.csv": wide,
        "dim_state.csv": dim_state,
        "dim_crime_type.csv": dim_crime,
        "dim_year.csv": dim_year,
        "abc_classification_states.csv": abc,
        "national_trend.csv": trend,
        "crime_mix_by_year.csv": mix,
        "region_summary.csv": region,
        "dv_state_year_matrix.csv": heat.reset_index(),
    }
    for name, frame in outputs.items():
        frame.to_csv(OUT / name, index=False)
        log(f"        wrote {name:34s} {frame.shape[0]:>5} rows x {frame.shape[1]:>2} cols")
    log()

    # ---- headline figures ---------------------------------------------------
    log("HEADLINE FIGURES")
    log(f"        All crimes against women 2001-2021  : {analysis.cases.sum():,}")
    log(f"        Domestic violence (IPC 498A)         : {dv_an.cases.sum():,} "
        f"({dv_an.cases.sum() / analysis.cases.sum() * 100:.1f}% of all cases)")
    log(f"        DV 2001 -> 2021                      : {trend.dv_cases.iloc[0]:,} -> "
        f"{trend.dv_cases.iloc[-1]:,} "
        f"({(trend.dv_cases.iloc[-1] / trend.dv_cases.iloc[0] - 1) * 100:+.1f}%)")
    log(f"        DV national CAGR                     : "
        f"{((trend.dv_cases.iloc[-1] / trend.dv_cases.iloc[0]) ** (1 / 20) - 1) * 100:.2f}%")
    a = dim_state[dim_state.abc_class == "A"]
    log(f"        Class A entities                     : {len(a)} carrying "
        f"{a.dv_total_cases.sum() / dim_state.dv_total_cases.sum() * 100:.1f}% of DV volume")
    log(f"        Largest DV volume 2001-2021          : "
        f"{dim_state.loc[dim_state.dv_total_cases.idxmax(), 'state_clean']} "
        f"({dim_state.dv_total_cases.max():,})")
    top_rate = dim_state.sort_values("dv_rate_2021", ascending=False).head(3)
    log(f"        Highest DV rate 2021 (per lakh women): " + ", ".join(
        f"{r.state_clean} {r.dv_rate_2021:.1f}" for r in top_rate.itertuples()))
    log(f"        COVID 2020 DV YoY                    : "
        f"{trend.loc[trend.year == 2020, 'dv_yoy_pct'].iloc[0]:+.1f}%")
    log(f"        2021 rebound DV YoY                  : "
        f"{trend.loc[trend.year == 2021, 'dv_yoy_pct'].iloc[0]:+.1f}%")
    log(f"        Risk zones (2021)                    : "
        f"{dim_state.risk_zone.value_counts().to_dict()}")
    log()


def main() -> None:
    log("=" * 78)
    log("CRIMES AGAINST WOMEN IN INDIA (2001-2021) - ETL RUN LOG")
    log("=" * 78)
    log()

    wide = load_raw()
    wide = clean_states(wide)
    wide = repair_2020_21(wide)
    wide = harmonise_entities(wide)
    validate(wide)

    long = unpivot(wide)
    long, master = conform(long)
    long = flag_zeros(long)
    long = add_rates(long)
    long = long[[
        "state_clean", "state_code", "entity_type", "region", "year",
        "crime_code", "crime_type", "cases", "rate_per_lakh_female",
        "population_2011", "female_population_2011", "literacy_rate_2011",
        "is_structural_zero", "is_source_gap", "data_quality_flag",
        "include_in_analysis",
    ]]

    build_outputs(wide, long, master)

    (ROOT / "etl" / "etl_run_log.txt").write_text("\n".join(log_lines) + "\n")
    print("Run log written to etl/etl_run_log.txt")


if __name__ == "__main__":
    main()
