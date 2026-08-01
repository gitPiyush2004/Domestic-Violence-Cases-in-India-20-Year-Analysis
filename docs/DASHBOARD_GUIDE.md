# Dashboard guide

The Power BI report is **built**: 5 pages, 40 visuals, 30 of them also placed on the
phone canvas. Open `powerbi/DomesticViolence.pbip`, point `RepoRoot` at your clone,
refresh.

The layout is **generated, not drawn**. PBIP stores a report as one `report.json` in
which every visual is a JSON document serialised into a string — thousands of lines of
JSON nested inside JSON, where one bad escape stops the whole report rendering and
Power BI Desktop reports nothing useful when it does. So the layout is declared
compactly in `powerbi/generate_report.ps1` and emitted by `powerbi/lib_report.ps1`:

```bash
powershell -File powerbi/generate_report.ps1
```

The declaration at the top of that script is what you review. `report.json` is a build
artefact — **hand-edits are overwritten on the next run.** To move a visual, change the
declaration.

---

## First open

1. Open `powerbi/DomesticViolence.pbip`.
2. Authorise the file data source if prompted (a local CSV — Anonymous / Public is fine).
3. If the repo is not at the recorded path: **Transform data → Manage Parameters →
   RepoRoot**. That is the only path in the model.
4. **Refresh.** A PBIP stores definition only, so the first open always needs one
   refresh to populate the model. Any later model edit shows a "relationships have been
   modified" banner until you refresh again — that is normal, not a fault.
5. **File → Options → Data Load → uncheck Auto date/time.** The grain is annual.

Expected after refresh: **FactCrimes 5,019 · FactQuality 5,152 · DimState 36 ·
DimYear 21 · DimCrimeType 7**.

---

## Design system

Everything derives from a grid. Nothing is eyeballed, and a build-time validator
(`Assert-NoOverlap`) refuses to write a report containing overlapping or off-canvas
visuals — cheaper to catch there than in a screenshot.

**Desktop 1280 × 720** — outer margin 24, gutter 16, content 1232.
Two columns: left 800, right 416. Six KPI cards of 192 at 16 apart. Every page bottoms
out at 696, leaving a 24 margin.

**Phone 320 wide, scrolls vertically** — margin 8, content 304, half-tiles of 148.

### Palette

Deep red carries the focus crime; everything else is warm neutral. A dashboard where
every element is red says nothing.

| Role | Hex |
|---|---|
| Focus / brand red | `#C1121F` |
| Deep red (secondary) | `#9D0208` |
| Ink (text) | `#1F2933` |
| Muted (labels, axes) | `#6B7280` |
| Canvas | `#FAF7F5` |
| Tile | `#FFFFFF` |
| Border | `#E7DEDA` |
| Teal (non-crime metric) | `#31708E` |

Red is reserved for the two focus-crime KPIs (DV cases, DV share) and the domestic
violence series. The entity-count chart on the data-quality page is teal precisely
because it is *not* a crime count — colour carries meaning or it carries nothing.

Every visual sits on a white tile with a 6px-radius border on the warm canvas; text
panels are `-Plain` (no tile) so prose reads as prose.

---

## The five pages

### 1 · Executive Overview — *how big is this, and is it getting worse?*
Six KPI cards (all crimes, DV, DV share, CAGR, entities, years) · DV by year as columns
with the 3-year trailing mean overlaid · crime-mix donut · DV by state · a
`[ABC Headline]` card that rewrites itself as the year slicer moves · year and region
slicers.

### 2 · Crime Type Trends — *is DV growing faster than everything else?*
All seven heads indexed to 100 in the first visible year — rebasing is what makes seven
series of wildly different magnitude legible on one axis · CAGR by head · the statutory
table with IPC sections and `Is Comparable Series` · the dowry-deaths argument in prose.

### 3 · State Deep Dive — *where is it worst, and does that depend on how you ask?*
The volume-vs-intensity scatter is the page's whole argument · ranked intensity bars ·
a table sorted by `[Volume vs Intensity Gap]` so the most-missed states surface first ·
a `[State Verdict]` card that narrates whichever state is selected.

**Deliberately not a filled map.** Map visuals are disabled by the Global → Security
setting on the build machine and render as an error tile. Even enabled, ranked bars beat
a choropleth here: a map of India lets the large low-intensity states dominate visually
and routinely mis-geocodes the small union territories — exactly the entities this page
exists to surface.

### 4 · ABC & Priority — *if you could only fund eight programmes, which eight?*
Pareto combo (bars = volume, line = cumulative share) · the ABC × Risk Zone matrix where
the two segmentations disagree · priority segments P1–P5.

**ABC boundary convention.** A state is class A if the cumulative share reached *before*
it is under 70%. That puts Madhya Pradesh — whose running total lands on 72.9% — inside
class A and gives **8 of 36 carrying 72.9%**. Banding on the inclusive cumulative
instead would drop MP into B and report "7 of 36 carry 68.0%", which would contradict
the ETL, the SQL layer and this README. Same data, same intent, one boundary rule apart
— so the DAX follows the ETL.

### 5 · Data Quality — *why you can trust these numbers*
Most portfolio dashboards hide this page. This one leads with it: the two absurd
published numbers, the root cause, entity coverage by year, the three kinds of zero, and
the four validation tests.

The flag matrix reads from **`FactQuality`** — the same source rows *without* the
`include_in_analysis` filter. `FactCrimes` is filtered at load, which is right for every
analytical visual but makes the exclusions invisible; a data-quality page that can only
ever render "ok" is worse than no page. `FactQuality` carries no cases column at all, so
nothing on it can be summed by accident.

---

## Mobile

30 of the 40 visuals carry a phone placement. In this format a visual appears on the
phone canvas **only if it has a `layouts[]` entry with `id: 1`**, so omitting one is the
mechanism for dropping a visual rather than shrinking it.

Deliberately absent from mobile:

| Dropped | Why |
|---|---|
| State scatter | Carries the page's argument at desktop size, communicates nothing at 320px |
| Two of six KPI cards | Two per row is the most that stays legible; the rest are dropped, not shrunk |
| Secondary slicers | One filter per page on a phone |

The State page substitutes the `[State Verdict]` card for the scatter — a sentence is the
right mobile replacement for a quadrant chart.

Review with **View → Mobile layout**, or edit the `mobile` tuple on the relevant visual
in `generate_report.ps1` and re-run.

---

## Verification

Cross-check against `sql/QUERY_RESULTS.md` — the SQL and DAX layers are independent
implementations of the same definitions, so they must agree.

| Check | Expected |
|---|---|
| All crimes against women | 4,867,722 |
| Total DV cases | 1,909,978 |
| DV share of all crime | 39.2% |
| DV CAGR 2001→2021 | 5.24% |
| Class A entity count / share | 8 · 72.9% |
| West Bengal DV total | 302,143 |
| FactCrimes row count | 5,019 |
| `[DV Share %]` with only 2011 selected | **blank** |

That last row is the important one. If 2011 alone renders a value instead of an empty
card, the `All Crimes Comparable` flag did not convert to boolean in Power Query and the
measure is silently lying.
