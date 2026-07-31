"""
build_data.py
=============
Serialises data/processed/*.csv into dashboard/data.js as a single JS object.

The dashboard is a static file on GitHub Pages, so it cannot query SQLite. This
keeps it honest anyway: the numbers are GENERATED from the same processed tables
the SQL warehouse loads, never retyped. Re-run the ETL and re-run this, and the
dashboard cannot silently disagree with the queries.

Run:  python3 dashboard/build_data.py
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
PROC = ROOT / "data" / "processed"
RAW = ROOT / "data" / "raw"


def clean(obj):
    """Recursively replace NaN with None so the output is valid JSON."""
    if isinstance(obj, dict):
        return {k: clean(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [clean(v) for v in obj]
    if isinstance(obj, float) and (np.isnan(obj) or np.isinf(obj)):
        return None
    if isinstance(obj, (np.integer,)):
        return int(obj)
    if isinstance(obj, (np.floating,)):
        return None if np.isnan(obj) else float(obj)
    if isinstance(obj, (np.bool_,)):
        return bool(obj)
    return obj


def records(name: str, cols: list[str] | None = None) -> list[dict]:
    df = pd.read_csv(PROC / name)
    if cols:
        df = df[cols]
    return clean(df.to_dict("records"))


def build_repair_evidence() -> dict:
    """The before/after table for the data-quality page.

    Recomputed from the RAW file so the page shows the actual defect, not a
    remembered version of it.
    """
    raw = pd.read_csv(RAW / "CrimesOnWomenData.csv", index_col=0)
    import re

    def nm(s):
        s = re.sub(r"\s*&\s*", " & ", re.sub(r"\s+", " ", str(s).strip())).title()
        return {"Delhi Ut": "Delhi UT"}.get(s, s)

    raw["S"] = raw.State.map(nm)
    before = (raw[raw.Year.isin([2019, 2020, 2021])]
              .pivot_table(index="S", columns="Year", values="DV", aggfunc="sum"))

    after = pd.read_csv(PROC / "fact_crimes_long.csv")
    after = (after[(after.crime_type == "Domestic Violence")
                   & (after.year.isin([2019, 2020, 2021]))]
             .pivot_table(index="state_clean", columns="year", values="cases", aggfunc="sum"))

    # The entities whose 2020 value moved most dramatically - the visible defect.
    focus = ["Delhi UT", "West Bengal", "Uttar Pradesh", "Rajasthan", "Maharashtra",
             "Tripura", "Uttarakhand", "Chandigarh", "Telangana", "Odisha",
             "Punjab", "Tamil Nadu"]
    rows = []
    for st in focus:
        b = before.loc[st] if st in before.index else None
        a = after.loc[st] if st in after.index else None
        if b is None or a is None:
            continue
        rows.append({
            "state": st,
            "dv_2019": int(b.get(2019, 0)),
            "raw_2020": int(b.get(2020, 0)),
            "raw_2021": int(b.get(2021, 0)),
            "fixed_2020": int(a.get(2020, 0)),
            "fixed_2021": int(a.get(2021, 0)),
        })
    return clean(rows)


def build_cube(dim_state: pd.DataFrame) -> dict:
    """A dense [state][crime][year] cube of case counts.

    The dashboard needs to re-aggregate on every filter change (year range,
    region, entity type, crime head), which pre-baked summary tables cannot do -
    they only answer the questions they were built for. The full fact table at
    36 x 7 x 21 is just 5,292 numbers, so shipping the whole grain costs ~30 KB
    and buys genuine cross-filtering instead of static pictures.

    `null` marks a cell excluded by data quality (entity not formed, or the AoW
    2011 source gap) so the front end can skip it rather than treating it as a
    real zero - the same include_in_analysis rule the SQL uses.
    """
    fact = pd.read_csv(PROC / "fact_crimes_long.csv")
    states = dim_state.state_clean.tolist()
    crimes = (pd.read_csv(PROC / "dim_crime_type.csv")
              .sort_values("total_cases_2001_2021", ascending=False).crime_type.tolist())
    years = list(range(2001, 2022))

    lookup = {}
    for r in fact.itertuples():
        lookup[(r.state_clean, r.crime_type, r.year)] = (
            int(r.cases) if r.include_in_analysis else None
        )

    cube = [[[lookup.get((s, c, y)) for y in years] for c in crimes] for s in states]
    filled = sum(1 for s in cube for c in s for v in c if v is not None)
    print(f"  cube           {len(states)}x{len(crimes)}x{len(years)} "
          f"= {len(states) * len(crimes) * len(years)} cells, {filled} usable")
    return {"states": states, "crimes": crimes, "years": years, "values": cube}


def main() -> None:
    trend = pd.read_csv(PROC / "national_trend.csv")
    dim_state = pd.read_csv(PROC / "dim_state.csv")
    mix = pd.read_csv(PROC / "crime_mix_by_year.csv")
    heat = pd.read_csv(PROC / "dv_state_year_matrix.csv")
    thresholds = json.loads((PROC / "risk_thresholds.json").read_text())

    # Heatmap: top 20 entities by DV volume keeps the grid readable; the rest
    # stay reachable in the table view.
    top20 = dim_state.nlargest(20, "dv_total_cases").state_clean.tolist()
    heat_rows = []
    for _, r in heat.iterrows():
        if r.state_clean not in top20:
            continue
        heat_rows.append({
            "state": r.state_clean,
            "values": clean([None if pd.isna(r[str(y)]) else int(r[str(y)])
                             for y in range(2001, 2022)]),
        })
    heat_rows.sort(key=lambda d: -sum(v or 0 for v in d["values"]))

    a_states = dim_state[dim_state.abc_class == "A"]
    payload = {
        "meta": {
            "years": list(range(2001, 2022)),
            "source": "NCRB Crime in India, 2001-2021 (Kaggle mirror)",
            "entities": int(len(dim_state)),
            "fact_rows": int(len(pd.read_csv(PROC / "fact_crimes_long.csv"))),
            "risk_thresholds": thresholds,
        },
        "kpi": {
            "dv_total": int(dim_state.dv_total_cases.sum()),
            "all_crimes": int(dim_state.all_crime_total.sum()),
            "dv_share": round(100 * dim_state.dv_total_cases.sum()
                              / dim_state.all_crime_total.sum(), 1),
            "dv_2001": int(trend.dv_cases.iloc[0]),
            "dv_2021": int(trend.dv_cases.iloc[-1]),
            "growth_pct": round(100 * (trend.dv_cases.iloc[-1] / trend.dv_cases.iloc[0] - 1), 1),
            "cagr_pct": round(100 * ((trend.dv_cases.iloc[-1] / trend.dv_cases.iloc[0])
                                     ** (1 / 20) - 1), 2),
            "covid_dip": float(trend.loc[trend.year == 2020, "dv_yoy_pct"].iloc[0]),
            "rebound": float(trend.loc[trend.year == 2021, "dv_yoy_pct"].iloc[0]),
            "class_a_count": int(len(a_states)),
            "class_a_share": round(100 * a_states.dv_total_cases.sum()
                                   / dim_state.dv_total_cases.sum(), 1),
            "peak_year": int(trend.loc[trend.dv_cases.idxmax(), "year"]),
            "cases_per_day_2021": round(trend.dv_cases.iloc[-1] / 365, 0),
        },
        "trend": clean(trend.to_dict("records")),
        "crime_mix": clean(mix.to_dict("records")),
        "crime_types": records("dim_crime_type.csv"),
        "states": clean(dim_state.to_dict("records")),
        "abc": records("abc_classification_states.csv"),
        "regions": records("region_summary.csv"),
        "years": records("dim_year.csv"),
        "heatmap": heat_rows,
        "repair": build_repair_evidence(),
        "cube": build_cube(dim_state),
    }

    js = ("// GENERATED by dashboard/build_data.py - do not edit by hand.\n"
          "// Source of truth: data/processed/*.csv (built by etl/01_clean_and_wrangle.py)\n"
          "window.DATA = " + json.dumps(payload, indent=1, allow_nan=False) + ";\n")
    (ROOT / "dashboard" / "data.js").write_text(js)

    size_kb = len(js) / 1024
    print(f"Wrote dashboard/data.js  ({size_kb:.0f} KB)")
    for k, v in payload.items():
        if isinstance(v, list):
            print(f"  {k:<14s} {len(v):>4} records")
        elif isinstance(v, dict):
            print(f"  {k:<14s} {len(v):>4} keys")


if __name__ == "__main__":
    main()
