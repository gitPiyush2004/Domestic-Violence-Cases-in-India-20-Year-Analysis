# Dashboard build guide

The semantic model in `powerbi/` is complete — four tables, three relationships,
thirty measures. The report ships with one blank page, because report layout is the
one part of Power BI that is genuinely faster to drag than to hand-author.

This is the page-by-page spec. Build it once and you have the dashboard the README
describes.

---

## 0. First open

1. Open `powerbi/DomesticViolence.pbip` in Power BI Desktop.
2. Power BI will ask to authorise the file data source — **Organizational / Anonymous**
   is fine for a local CSV. Set privacy level to **Public** if prompted; nothing here
   is confidential and a Private level blocks folds across queries.
3. If the repo is not at `C:\Users\hp\Desktop\Domestic Violance Cases\repo`:
   **Transform data → Manage Parameters → RepoRoot** and point it at your clone.
   That is the only path in the model.
4. **File → Options → Data Load → Time intelligence → uncheck Auto date/time.**
   The grain is annual; an auto date hierarchy on `Year` is noise.
5. Refresh.

Expected after refresh: **FactCrimes 5,019 rows · DimState 36 · DimYear 21 ·
DimCrimeType 7**. If FactCrimes shows more than 5,019, the `include_in_analysis`
filter did not apply and every rate in the report will be wrong.

---

## Theme

Save as `theme.json` and apply via **View → Themes → Browse for themes**. Muted, and
deliberately not a red-alert palette — this is a policy dashboard, not a threat board.

| Role | Hex |
|---|---|
| Focus (domestic violence) | `#7B2D26` |
| Other crime heads | `#B08968` `#8A9A8B` `#6C7B8B` `#A38560` `#7D8CA3` `#9C8AA5` |
| Class A / Critical | `#7B2D26` |
| Class B / High | `#C4703E` |
| Class C / Moderate | `#D9B48F` |
| Low | `#B7C4B5` |
| Canvas | `#F7F5F2` |
| Text | `#2B2B2B` |

Canvas 1280×720, "Fit to page", 8-px grid, snap-to-grid on.

---

## Page 1 — Executive Overview

**Question it answers:** how big is this, and is it getting worse?

**KPI row** (six cards, 200×110, across the top):

| Card | Measure | Expected (unfiltered) |
|---|---|---|
| All crimes against women | `[All Crime Cases]` | 4,867,722 |
| Domestic violence | `[DV Cases]` | 1,909,978 |
| DV share | `[DV Share %]` | 39.2% |
| Annual growth | `[DV CAGR %]` | 5.24% |
| Entities | `[States Reporting]` | 36 |
| Years | `[Years Covered]` | 21 |

**Line + column combo** — *DV cases by year*
Axis `DimYear[Year]`, columns `[DV Cases]`, line `[DV 3Y Moving Avg]`.
Annotate 2020 and 2021. The smoothed line carries the narrative; the raw columns
show the COVID dip and rebound.

**Bar** — *Top 10 states by DV cases*
Axis `DimState[State]`, value `[DV Cases]`, Top-N filter 10 by `[DV Cases]`,
data colour conditional on `[ABC Class]`.

**Donut** — *Crime mix*
Legend `DimCrimeType[Crime Type]`, value `[Total Cases]`. Detail labels: category +
percent. Domestic violence should read 39.2%.

**Card (large text)** — `[ABC Headline]`
Renders "8 of 36 entities carry 72.9% of recorded domestic violence" and rewrites
itself as the year slicer moves.

**Slicers** (left rail, 200 px): `DimYear[Year]` as a between-slider,
`DimState[Region]` as a dropdown, `DimState[Entity Type]` as tiles.

---

## Page 2 — Crime type trends

**Question:** is domestic violence growing faster than everything else? (No.)

- **Line, indexed** — axis `Year`, legend `Crime Type`, value `[DV Index (Base = 100)]`
  applied per crime head. Rebasing to 100 is what makes seven series of wildly
  different magnitude legible on one axis.
- **Bar** — CAGR by crime head, `DimCrimeType[CAGR % (static)]`. Trafficking 11.9%
  and kidnapping 8.9% both beat domestic violence at 5.2%; dowry deaths are flat at
  0.01%.
- **Table** — `Crime Type`, `IPC Section`, `Total Cases 2001-2021`,
  `Share of All Crime %`, `Is Comparable Series`, `Series Break Note`.
  Conditional-format the row background where `Is Comparable Series` is FALSE.
  Three of seven heads carry documented breaks; the table is where you say so.
- **Text box** — the dowry-deaths argument, verbatim from the README finding 4. It is
  the strongest inference in the project and it deserves prose, not a chart.

---

## Page 3 — State deep dive

**Question:** where is it worst — and does that depend on how you ask?

- **Filled map** — `DimState[State]` (already tagged `StateOrProvince`), colour
  `[DV Rate per Lakh Women (Annual Avg)]`, diverging scale centred on the national
  rate. Use the map for texture, not for reading values.
- **Scatter — the centrepiece.**
  X `[DV Cases]` (log scale), Y `[DV Rate per Lakh Women (Annual Avg)]`,
  size `DimState[Female Population 2011]`, legend `[ABC Class]`,
  play axis `DimYear[Year]`.
  Add constant lines at `[Risk Threshold High]` and `[Risk Threshold Critical]`.
  **This one visual is the project's argument:** volume and intensity disagree, and
  the top-left quadrant — small entities, high intensity — is what every
  volume-ranked league table misses.
- **Table** — State · `[DV Cases]` · `[DV Rank]` · `[DV Rate per Lakh Women (Annual Avg)]` ·
  `[DV Rate Rank]` · `[Volume vs Intensity Gap]` · `[ABC Class]` · `[Risk Zone]`.
  Sort by the gap descending to surface the most-missed states first.
- **Card** — `[State Verdict]`. Writes a full sentence for whichever state is
  selected, so the page narrates itself during a demo.

---

## Page 4 — ABC classification and priority

**Question:** if you could only fund eight programmes, which eight?

- **Pareto combo** — axis `DimState[State]` sorted by `[DV Cases]` descending,
  columns `[DV Cases]`, line `[DV Cumulative Share %]` on a secondary axis 0–100%.
  Constant lines at `[Pareto 70% Line]` and `[Pareto 90% Line]`.
- **Matrix** — rows `[ABC Class]`, columns `[Risk Zone]`, values `[States Reporting]`
  and `[DV Cases]`. The off-diagonal cells are the finding: Class C ∩ Critical is
  small, intense, and invisible to volume ranking.
- **Table** — `[Priority Segment]` grouped, with states listed under each.
  P1 → P5 is the recommendation the dashboard exists to make.
- **Text box** — state plainly that ABC bands by volume and risk zones band by
  intensity, and that they are *supposed* to disagree.

---

## Page 5 — Data quality and the repair

Most portfolio dashboards hide this page. Yours should lead with it — it is the
strongest thing in the project.

- **Two cards** — Delhi 2020 as published (**3**) vs Dadra & Nagar Haveli 2020 as
  published (**2,557**). The absurdity is the hook.
- **Table** — the four validation tests and their results, from the README.
- **Column chart** — `DimYear[Reporting Entities]` by year. The 34 → 36 step in 2011
  is visible, which is where Delhi and Telangana enter.
- **Matrix** — `FactCrimes[data_quality_flag]` by year. Shows exactly which cells are
  excluded and why: `entity_not_formed`, `source_gap`, `ok`.
- **Text box** — the invariance result: all seven measure totals are unchanged by the
  repair. It re-labels; it never invents. That sentence is what makes the repair
  defensible rather than a fudge.

---

## Mobile layouts

**View → Mobile layout**, per page. Phone canvas is 320×640 — a portrait strip, not a
shrunken desktop page. Rules that matter:

1. **One column.** Cards full width, stacked, in priority order.
2. **Drop the scatter and the map.** Neither survives at 320 px. Replace with the
   top-10 bar on pages 1 and 3.
3. **Slicers to the top**, collapsed to dropdowns. Never tiles on mobile.
4. **Tables to three columns maximum** — State, Cases, Rate. Everything else is a
   horizontal scroll nobody performs.
5. **Raise every font two steps.** Desktop 9 pt is unreadable on a phone.

Per-page mobile priority order:

| Page | Mobile stack |
|---|---|
| Overview | KPI cards → trend line → top-10 bar → ABC headline |
| Crime types | CAGR bar → indexed line → break-note table |
| State deep dive | Top-10 bar by rate → verdict card → 3-column table |
| ABC | Headline card → Pareto → priority table |
| Data quality | The two absurd cards → flag matrix |

---

## Verification before you call it done

Cross-check the dashboard against `sql/QUERY_RESULTS.md` — the SQL layer and the DAX
layer are independent implementations of the same definitions, so they should agree
exactly.

| Check | Expected |
|---|---|
| Total DV cases, all years | 1,909,978 |
| DV share of all crime | 39.2% |
| DV CAGR 2001→2021 | 5.24% |
| Class A entity count | 8 |
| Class A share | 72.9% |
| West Bengal DV total | 302,143 |
| 2011 `[DV Share %]` | **blank** — this is the important one |
| FactCrimes row count | 5,019 |

If 2011 renders a value instead of a gap, the `All Crimes Comparable` flag did not
convert to boolean in Power Query and `[DV Share %]` is silently lying.
