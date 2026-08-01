# Interview walkthrough

How to talk about this project. Read the numbers section until you own it — everything
else you can reason out live, but you cannot reason out a figure you never learned.

---

## First: fix the résumé bullets

Your current bullets claim **"7,500+"** and **"10K+ records"**. The source file is
**736 rows**. Unpivoted to the analytical grain it is **5,019 rows**. An interviewer who
opens the repo will see 736 in the first line of the CSV, and the gap between that and
"10K+" costs you more than the bigger number ever bought.

The honest version is also the stronger one, because scale was never what made this
project good:

> **20-Year Analysis of Domestic Violence in India (2001–2021)**
>
> - Built an end-to-end analytics pipeline over NCRB crime data — Python ETL → star
>   schema (5,019 fact rows) → SQL analytical layer → Power BI — and **found and
>   repaired a systematic label-misalignment defect in the published 2020–21 data**
>   that attributed Delhi's caseload to a union territory 50× smaller.
> - Defended the repair with **four independent statistical tests** (anomaly bands,
>   crime-mix profile matching in log space, year-over-year continuity, and total
>   invariance) — median absolute YoY swing fell from 71.2% to 13.9% with **zero change
>   to any national total**.
> - Engineered the SQL layer with window functions, multi-table joins, CASE-based risk
>   banding and **ABC classification**, establishing that **8 of 36 entities carry 72.9%**
>   of recorded domestic violence.
> - Delivered a **five-page Power BI dashboard (40 visuals, phone layouts)** with **40 DAX
>   measures** including dynamic Pareto segmentation, and a guard that **returns blank
>   rather than a plausible-looking false spike** for a year with a known source gap.

"I found a bug in the public data and proved the fix" beats "I processed 10,000 rows"
in every interview you will ever sit.

One more: the bullets say **"data scraped from government portals"**. This is a Kaggle
mirror of NCRB annual reports. Say "sourced from a Kaggle mirror of NCRB *Crime in
India* reports, cross-checked against the published PDFs." Nobody minds Kaggle. People
mind being told something was scraped when it was downloaded.

---

## The 60-second pitch

> Domestic violence — IPC 498A — is the single largest category of recorded crime
> against women in India: 1.9 million cases over 21 years, 39% of the total, more than
> rape, dowry deaths and insult to modesty combined. I built a pipeline from the raw
> NCRB extract through a star schema and a SQL layer into a Power BI dashboard.
>
> The interesting part wasn't the dashboard. While validating, I found the published
> data is silently broken for 2020 and 2021 — Delhi shows 3 domestic violence cases,
> down from 3,792, while Dadra & Nagar Haveli, population 344,000, shows 2,557. The
> cause is that NCRB reordered its entity table when Jammu & Kashmir became a UT and
> Ladakh was created, but whoever built the CSV pasted the new value block against the
> old label column. Every row from position nine down is attached to the wrong state.
>
> I repaired it against the published NCRB ordering and defended the repair with four
> independent tests. The repair only moves attribution — every national total is
> identical before and after — so I can prove it corrects rather than invents.

Then stop. That pitch is designed to make them ask a question, and every question it
provokes is one you can answer.

---

## Numbers to know cold

| | |
|---|---|
| All recorded crimes against women, 2001–2021 | **4,867,722** |
| Domestic violence (IPC 498A) | **1,909,978** — 39.2% |
| DV in 2001 → 2021 | 49,032 → 136,234 (**+178%**, CAGR **5.24%**) |
| 2020 / 2021 | **−11.0%** then **+22.1%** |
| Fact grain | **5,019** rows — 36 entities × 21 years × 7 heads, minus excluded cells |
| ABC concentration | **8 of 36 entities = 72.9%** |
| Highest volume | West Bengal, **302,143** — but 6th on intensity |
| Highest intensity 2021 | Assam, **84.8 per lakh women** (~1.9× West Bengal) |
| Fastest-growing heads | Trafficking **11.9%/yr**, kidnapping **8.9%/yr** |
| Dowry deaths | 6,738 → 6,753 — **flat**, CAGR 0.01% |
| Risk thresholds | 2.5 / 9.1 / 22.9 per lakh — quartiles of the 2021 distribution |

---

## The three stories that carry the interview

### 1. The repair — your headline

Know the mechanism, not just the symptom. On 31 Oct 2019 J&K became a UT and Ladakh
was carved out; on 26 Jan 2020 Dadra & Nagar Haveli merged with Daman & Diu. NCRB's
2020 table therefore lists 28 states then 8 UTs. J&K moved out of the state block
(alphabetical position 9) down into the UT block. The CSV's label column was still
generated from the pre-2019 36-entity list, so every measure row from position 9
downward is off by one or more.

The four tests, and why four:

| Test | What it rules out | Result |
|---|---|---|
| Anomaly bands (2020 vs 2017–19 mean) | "nothing is actually wrong" | 16 of 32 entities outside 0.25×–4× |
| Crime-mix profile matching, log space | "the misalignment is random" | 2019 control **34/36** self-match; 2020 only **10/36**, but **28/34** match the NCRB order |
| YoY continuity | "the fix made it worse" | median \|YoY\| **71.2% → 13.9%**; implausible jumps **15 → 0** |
| Total invariance | "you invented data" | all seven measure totals — **delta zero** |

The 2019 control is the move to emphasise. Running the same profile-match on a year
you believe is *correct* and getting 34/36 is what proves the method detects
misalignment rather than manufacturing it.

**If they push:** "Could the 2020 numbers just be real?" — Delhi does not go from 3,792
to 3. A UT of 344,000 does not out-report Delhi. And profile matching says the values
are not random, they are *shifted* — they fit other states' fingerprints, in NCRB's
published order.

### 2. Volume and intensity disagree

West Bengal is 1st by cases and 6th by rate. Assam has the highest 2021 intensity.
A dashboard that ranks only by volume is a population map with extra steps — the
biggest states have the most of everything.

So the project carries two segmentations that are *supposed* to conflict: ABC by
volume, risk zones by intensity. Class C ∩ Critical — small entities, badly affected —
is the cell every national league table buries.

Thresholds are **quartiles of the 2021 distribution**, not round numbers, on purpose:
round thresholds encode your opinion of what "high" means and quietly change meaning on
the next refresh. Quartiles let the distribution speak.

### 3. The dowry-deaths inference

Every crime head grew except dowry deaths: 6,738 in 2001, 6,753 in 2021. Flat.

Deaths are the hardest category to under-report — there is a body. So if reported
deaths are flat while reported cruelty complaints grew 178%, the most defensible
reading is that **a large share of the growth is rising reporting propensity, not
rising incidence.**

This is the answer to "what does your dashboard actually tell a policymaker?" It says:
be careful reading a rising line as a worsening problem. It may be a system that is
finally being used.

**Do not overclaim.** You cannot separate incidence from reporting with this data. The
flat dowry series is an *argument*, not a proof, and saying so is the strongest thing
you can do with it.

---

## Technical questions

**"Why a star schema, not one wide table?"**
The source has one column per crime — `Rape`, `K&A`, `DD`, `AoW`, `AoM`, `DV`, `WT`.
In that shape "which crime head grew fastest" needs seven near-duplicate measures and
cannot go on an axis. Unpivoting makes crime type a real dimension: one measure, one
slicer, and the question becomes a chart.

**"Walk me through your DAX."**
Pick `[DV Cumulative Share %]` — it's the most interesting:

```
VAR StateTotals  = ADDCOLUMNS ( ALLSELECTED ( DimState[State] ), "@dv", CALCULATE ( [DV Cases] ) )
VAR GrandTotal   = SUMX ( StateTotals, [@dv] )
VAR RunningTotal = SUMX ( FILTER ( StateTotals, [@dv] >= CurrentValue ), [@dv] )
RETURN DIVIDE ( RunningTotal, GrandTotal )
```

Build a virtual table of every visible state with its total, sum the ones ranked at or
above the current row, divide. `ALLSELECTED` rather than `ALL` is the key choice — the
classification recomputes inside the user's slicer selection, so the A-list for
2001–2010 is not the A-list for 2011–2021. That is the difference between a stored
column and a live segmentation.

**"Why no date table?"**
Because the grain is annual. A marked date table would let someone write
`SAMEPERIODLASTYEAR` against 21 synthetic 1-January timestamps — correct numbers,
implied daily precision the source doesn't have, plus an auto date hierarchy on every
year field. Year-over-year is an explicit integer offset instead.

**"Why does Power Query read `processed/` instead of the raw file?"**
The repair logic is non-trivial and lives in the ETL. Re-implementing it in M would put
the same business rule in two languages, and they'd drift the first time either was
edited. The BI layer shapes, types and filters; it does not re-derive.

**"What's `include_in_analysis`?"**
Three different things look like a zero: `entity_not_formed` (Telangana before 2014),
`source_gap` (Assault on Women is missing for every entity in 2011), and a genuine `ok`
zero (Lakshadweep really reports none some years). Only the third is an observation.
The ETL encodes that once in one boolean, and SQL, DAX and M all defer to it instead of
each re-deriving the rule three times and getting it slightly different.

**"Show me something you deliberately made worse."**
`[DV Share %]` returns **blank** for 2011. Assault on Women is missing that year, so the
all-crime denominator is ~40,000 short and the share computes to about 55% against a
39.2% baseline. A footnote doesn't stop someone reading that spike off a chart, so the
measure refuses. The line has a visible gap. **A dashboard should be silent where the
data is unsound rather than plausible** — that's the sentence to say.

**"Tell me about a bug you found in your own work."**
The ABC classification. The ETL reported *8 of 36 entities carry 72.9%*; the DAX version
on the dashboard reported *7 of 36 carry 68.0%*. Same data, same intent — one boundary
rule apart. The ETL classes a state as A if the cumulative share reached **before** it is
under 70%, which puts Madhya Pradesh (running total 72.9%) inside A. My DAX banded on the
**inclusive** cumulative, which pushed MP out.

Neither is objectively wrong; the failure was that the dashboard contradicted its own
README. I changed the DAX to match the ETL because the ETL and SQL layer are the system
of record. **The lesson I'd give is that "which side of the threshold does the crossing
item go" is a business rule, and it has to be written down once and referenced, not
re-decided in each language.**

**"Why is the report layout generated by a script?"**
PBIP stores the report as a single `report.json` where every visual is a JSON document
serialised into a string — JSON nested inside JSON. Five pages is thousands of lines of
near-duplicate boilerplate in which one bad escape stops the entire report rendering, and
Desktop reports nothing useful when that happens. So `generate_report.ps1` holds a compact
declaration and emits the JSON, and a build-time validator refuses to write a report with
overlapping or off-canvas visuals. Layout bugs become build failures instead of things you
notice in a screenshot two days later.

The other payoff: because the model is TMDL and the report is generated, **the whole
project reviews as text in a pull request.** A `.pbix` is an opaque binary you can only
diff by opening it.

**"Talk me through a design decision on the dashboard."**
Red is reserved. Only the two focus-crime figures — DV cases and DV share — and the
domestic-violence series are red; everything else is warm neutral, and the entity-count
chart on the data-quality page is teal because it is *not* a crime count. A dashboard
where everything is red communicates nothing. Colour either carries meaning or it is
decoration.

I also dropped the filled map. Map visuals were disabled by a security policy on the
build machine, but even enabled I would not use one here: a choropleth of India lets the
large low-intensity states dominate visually and mis-geocodes the small union
territories — which are exactly the entities the page exists to surface. Ranked bars let
you read the actual rate.

**"How would you scale this?"**
District-level NCRB tables push it to ~700 districts × 21 years × 7 heads ≈ 100k rows —
still trivially import-mode. The real scaling problem isn't volume, it's boundary
churn: districts split and merge constantly, so you'd need a slowly-changing dimension
with valid-from/valid-to, which this state-level model gets to avoid.

---

## Weaknesses — name them before they do

- **NCRB counts cases reported to police, not incidents.** NFHS-5 puts spousal violence
  prevalence near 1 in 3 ever-married women — orders of magnitude above anything here.
  Every number in the dashboard is a *reporting* measure.
- **Fixed Census 2011 denominator** for all 21 years. The 2021 census was postponed, so
  it's the only census-grade figure in the window. Rates are a comparable index across
  states, not a live incidence rate.
- **Three series carry documented breaks** — AoW (2011 gap, 2013 statutory widening),
  AoM (unexplained 2014/2017 steps), WT (2011 reporting change). Flagged in the model
  as `Is Comparable Series`.
- **J&K case counts before 2020 include Ladakh** while the denominator excludes it —
  about a 2% effect on that one entity.
- **Undivided Andhra Pradesh includes Telangana before 2014.** Cross-2014 AP
  comparisons need care.

Volunteering these reads as rigour. Being caught by them reads as the opposite.

---

## Questions to ask them back

- Where does the org draw the line between correcting upstream data and flagging it for
  the source to fix?
- How are metric definitions kept consistent when the same measure is computed in the
  warehouse and again in the BI layer?
- What's the review process before a dashboard reaches a decision-maker?
