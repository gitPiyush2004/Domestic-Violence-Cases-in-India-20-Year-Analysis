<#
================================================================================
 generate_report.ps1 - builds DomesticViolence.Report/report.json
================================================================================
 The layout is declared here and the JSON is generated. Five pages of legacy
 report.json is thousands of lines of JSON-nested-inside-JSON in which one bad
 escape stops the report rendering, and Desktop reports nothing useful when that
 happens. This declaration is what you review; report.json is a build artefact
 and hand-edits are overwritten on the next run.

 Run:  powershell -File powerbi/generate_report.ps1
 Then: open powerbi/DomesticViolence.pbip and refresh.

 LAYOUT GRID - 1280 x 720, everything derives from it, nothing is eyeballed:
   outer margin 24 | gutter 16 | content width 1232
   two columns    : left 800, right 416  (24 + 800 + 16 + 416 + 24 = 1280)
   six KPI cards  : 192 wide, 16 apart   (6*192 + 5*16 = 1232)
   bottom of every page lands on 696, leaving a 24 margin

 PHONE GRID - 320 wide, scrolls vertically:
   margin 8 | content 304 | two half-tiles of 148 with a 16 gutter
================================================================================
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib_report.ps1')

$ReportDir = Join-Path $PSScriptRoot 'DomesticViolence.Report'
$P = $script:PAL

# grid constants
$M = 24; $LW = 800; $RX = 840; $RW = 416; $FW = 1232

function V {
    param([string]$n, [string]$type, [int]$x, [int]$y, [int]$w, [int]$h,
          $roles, [string]$title, $mobile, $sort, [string]$color, [int]$z = 0, [int]$cardSize = 26, [switch]$hideLegend)
    New-Container -Name $n -Type $type -X $x -Y $y -W $w -H $h -Roles $roles `
                  -Title $title -Mobile $mobile -SortBy $sort -Color $color -Z $z -CardSize $cardSize -HideLegend:$hideLegend
}
function T {
    param([string]$n, [int]$x, [int]$y, [int]$w, [int]$h, $runs, $mobile, [int]$z = 0, [switch]$Plain)
    New-Container -Name $n -Type 'textbox' -X $x -Y $y -W $w -H $h -TextRuns $runs -Mobile $mobile -Z $z -Plain:$Plain
}

$sections = @()

# ============================================================ 1. OVERVIEW ====
$c = @(); $z = 0
$c += T 'ovTitle' $M 20 $LW 44 @(
        @{Text='Domestic violence in India  '; Size=19; Bold=$true}
        @{Text='2001-2021'; Size=19; Color=$P.Red500; Bold=$true}
    ) @(8,8,304,56) ($z++) -Plain
$c += T 'ovContext' $RX 20 $RW 44 @(
        @{Text='1.91M recorded cases. 39.2% of all crime against women.'; Size=10; Color=$P.Muted}
    ) $null ($z++) -Plain

# KPI row. Red is reserved for the two focus-crime numbers so the eye lands there.
$kpis = @(
    @{n='kpiAll';    m='M:FactCrimes.All Crime Cases';  t='All crimes'; col=$P.Ink;    mob=@(8,168,148,88)}
    @{n='kpiDV';     m='M:FactCrimes.DV Cases';         t='DV cases';            col=$P.Red500; mob=@(8,72,148,88)}
    @{n='kpiShare';  m='M:FactCrimes.DV Share %';       t='DV share';   col=$P.Red500; mob=@(164,72,148,88)}
    @{n='kpiCagr';   m='M:FactCrimes.DV CAGR %';        t='Annual growth';       col=$P.Ink;    mob=@(164,168,148,88)}
    @{n='kpiStates'; m='M:FactCrimes.States Reporting'; t='Entities';            col=$P.Ink;    mob=$null}
    @{n='kpiYears';  m='M:FactCrimes.Years Covered';    t='Years';       col=$P.Ink;    mob=$null}
)
$x = $M
foreach ($k in $kpis) {
    $c += V $k.n 'card' $x 76 192 96 ([ordered]@{Values=@($k.m)}) $k.t $k.mob $null $k.col ($z++) 22
    $x += 208
}

$c += V 'ovTrend' 'lineClusteredColumnComboChart' $M 180 $LW 250 ([ordered]@{
        Category=@('C:DimYear.Year'); Y=@('M:FactCrimes.DV Cases'); Y2=@('M:FactCrimes.DV 3Y Moving Avg')
    }) 'Reported domestic violence by year, with 3-year trailing mean' @(8,264,304,220) $null $P.Red500 ($z++)

$c += V 'ovMix' 'donutChart' $RX 180 $RW 250 ([ordered]@{
        Category=@('C:DimCrimeType.Crime Type'); Y=@('M:FactCrimes.Total Cases')
    }) 'Crime mix, all 21 years' $null $null $null ($z++) 26 -hideLegend

$c += V 'ovStates' 'clusteredBarChart' $M 442 $LW 254 ([ordered]@{
        Category=@('C:DimState.State'); Y=@('M:FactCrimes.DV Cases')
    }) 'Domestic violence by state' @(8,492,304,280) @('M:FactCrimes.DV Cases','Descending') $P.Red500 ($z++)

$c += V 'ovAbc' 'card' $RX 442 $RW 76 ([ordered]@{Values=@('M:FactCrimes.ABC Headline')}) `
        'Concentration' @(8,780,304,88) $null $P.Red700 ($z++) 13
$c += V 'ovYear' 'slicer' $RX 530 200 166 ([ordered]@{Values=@('C:DimYear.Year')}) 'Year' @(8,876,304,140) $null $null ($z++)
$c += V 'ovRegion' 'slicer' 1056 530 200 166 ([ordered]@{Values=@('C:DimState.Region')}) 'Region' $null $null $null ($z++)

$sections += New-Section 'overview' 'Executive Overview' 0 $c

# ========================================================== 2. CRIME TYPES ===
$c = @(); $z = 0
$c += T 'ctTitle' $M 20 $FW 40 @(
        @{Text='Crime heads compared  '; Size=17; Bold=$true}
        @{Text='domestic violence is the largest, but not the fastest growing'; Size=11; Color=$P.Muted}
    ) @(8,8,304,44) ($z++) -Plain

$c += V 'ctIndexed' 'lineChart' $M 72 $LW 280 ([ordered]@{
        Category=@('C:DimYear.Year'); Series=@('C:DimCrimeType.Crime Type'); Y=@('M:FactCrimes.Index (Base = 100)')
    }) 'Indexed to 100 in the first visible year' @(8,308,304,240) $null $null ($z++)

$c += V 'ctCagr' 'clusteredBarChart' $RX 72 $RW 280 ([ordered]@{
        Category=@('C:DimCrimeType.Crime Type'); Y=@('M:FactCrimes.CAGR %')
    }) 'Compound annual growth by head' @(8,60,304,240) @('M:FactCrimes.CAGR %','Descending') $P.Red700 ($z++)

$c += V 'ctTable' 'tableEx' $M 368 $LW 328 ([ordered]@{Values=@(
        'C:DimCrimeType.Crime Type','C:DimCrimeType.IPC Section',
        'C:DimCrimeType.Total Cases 2001-2021','C:DimCrimeType.Share of All Crime %',
        'C:DimCrimeType.Is Comparable Series')
    }) 'The seven heads, with statutory basis' @(8,556,304,220) $null $null ($z++)

$c += T 'ctNote' $RX 368 $RW 160 @(
        @{Text='Dowry deaths are the control. '; Size=10; Bold=$true; Color=$P.Red700}
        @{Text="Every head grew except dowry deaths: 6,738 in 2001, 6,753 in 2021. Deaths are the hardest category to under-report, so flat deaths against a 178% rise in cruelty complaints argues much of the growth is reporting propensity, not incidence. An argument, not a proof."; Size=9}
    ) @(8,784,304,200) ($z++)

# Slicers get a real column with 152px of height each. At the 68px they had
# before, a list slicer renders its header and clips every item - present in the
# file, useless to the reader.
$c += V 'ctYear' 'slicer' $RX 544 200 152 ([ordered]@{Values=@('C:DimYear.Year')}) 'Year' @(8,996,148,150) $null $null ($z++)
$c += V 'ctCrime' 'slicer' 1056 544 200 152 ([ordered]@{Values=@('C:DimCrimeType.Crime Type')}) 'Crime head' @(164,996,148,150) $null $null ($z++)

$sections += New-Section 'crimetypes' 'Crime Type Trends' 1 $c

# =========================================================== 3. STATE VIEW ===
$c = @(); $z = 0
$c += T 'stTitle' $M 20 $LW 40 @(
        @{Text='Volume and intensity '; Size=17; Bold=$true}
        @{Text='disagree'; Size=17; Bold=$true; Color=$P.Red500}
    ) @(8,8,304,44) ($z++) -Plain
$c += V 'stVerdict' 'card' $RX 20 $RW 40 ([ordered]@{Values=@('M:FactCrimes.State Verdict')}) `
        $null @(8,60,304,80) $null $P.Ink ($z++) 11

$c += V 'stScatter' 'scatterChart' $M 72 $LW 300 ([ordered]@{
        Category=@('C:DimState.State')
        X=@('M:FactCrimes.DV Cases')
        Y=@('M:FactCrimes.DV Rate per Lakh Women (Annual Avg)')
        Size=@('C:DimState.Female Population 2011')
    }) 'Volume against intensity - the top-left quadrant is what volume ranking misses' $null $null $P.Red500 ($z++)

# Deliberately a bar chart, not a filled map. Map visuals are disabled by the
# Global > Security setting on this machine and render as an error tile. Even
# enabled, ranked bars beat a choropleth here: a map of India lets the large
# low-intensity states dominate and mis-geocodes the small union territories,
# which are exactly the entities this page exists to surface.
$c += V 'stMap' 'clusteredBarChart' $RX 72 $RW 300 ([ordered]@{
        Category=@('C:DimState.State'); Y=@('M:FactCrimes.DV Rate per Lakh Women (Annual Avg)')
    }) 'Intensity by state (cases per lakh women)' @(8,148,304,280) `
    @('M:FactCrimes.DV Rate per Lakh Women (Annual Avg)','Descending') $P.Red700 ($z++)

$c += V 'stTable' 'tableEx' $M 388 $LW 308 ([ordered]@{Values=@(
        'C:DimState.State','M:FactCrimes.DV Cases','M:FactCrimes.DV Rank',
        'M:FactCrimes.DV Rate per Lakh Women (Annual Avg)','M:FactCrimes.DV Rate Rank',
        'M:FactCrimes.Volume vs Intensity Gap','M:FactCrimes.ABC Class','M:FactCrimes.Risk Zone')
    }) 'Sorted by the gap - the most-missed states first' @(8,436,304,300) `
    @('M:FactCrimes.Volume vs Intensity Gap','Descending') $null ($z++)

$c += V 'stRegion' 'slicer' $RX 388 $RW 146 ([ordered]@{Values=@('C:DimState.Region')}) 'Region' @(8,744,304,140) $null $null ($z++)
$c += V 'stEntity' 'slicer' $RX 550 $RW 146 ([ordered]@{Values=@('C:DimState.Entity Type')}) 'Entity type' $null $null $null ($z++)

$sections += New-Section 'statedeepdive' 'State Deep Dive' 2 $c

# ================================================================== 4. ABC ===
$c = @(); $z = 0
$c += T 'abTitle' $M 20 $LW 40 @(
        @{Text='ABC classification '; Size=17; Bold=$true}
        @{Text='and intervention priority'; Size=17; Bold=$true; Color=$P.Red500}
    ) @(8,8,304,44) ($z++) -Plain
$c += V 'abHeadline' 'card' $RX 20 $RW 40 ([ordered]@{Values=@('M:FactCrimes.ABC Headline')}) `
        $null @(8,60,304,80) $null $P.Red700 ($z++) 12

$c += V 'abPareto' 'lineClusteredColumnComboChart' $M 72 $FW 280 ([ordered]@{
        Category=@('C:DimState.State'); Y=@('M:FactCrimes.DV Cases'); Y2=@('M:FactCrimes.DV Cumulative Share %')
    }) 'Pareto - bars are volume, line is cumulative share (70% and 90% are the ABC cuts)' `
    @(8,148,304,260) @('M:FactCrimes.DV Cases','Descending') $P.Red500 ($z++)

$c += V 'abMatrix' 'pivotTable' $M 368 604 230 ([ordered]@{
        Rows=@('C:DimState.ABC Class (static)'); Columns=@('C:DimState.Risk Zone (static)'); Values=@('M:FactCrimes.States Reporting')
    }) 'Where the two segmentations disagree' $null $null $null ($z++)

$c += V 'abPriority' 'tableEx' 652 368 604 230 ([ordered]@{Values=@(
        'C:DimState.State','M:FactCrimes.Priority Segment','M:FactCrimes.DV Cases')
    }) 'Priority segments' @(8,416,304,260) @('M:FactCrimes.DV Cases','Descending') $null ($z++)

$c += T 'abNote' $M 614 $FW 82 @(
        @{Text='ABC bands by volume; risk zones band by intensity. They are meant to disagree'; Size=10; Bold=$true}
        @{Text=" - a Class C entity in the Critical zone is small, badly affected, and invisible to every volume-ranked league table. Thresholds are the quartiles of the 2021 rate distribution (2.5 / 9.1 / 22.9 per lakh women), not round numbers, so they survive a refresh without quietly changing meaning."; Size=10}
    ) @(8,684,304,150) ($z++)

$sections += New-Section 'abc' 'ABC & Priority' 3 $c

# ========================================================= 5. DATA QUALITY ===
$c = @(); $z = 0
$c += T 'dqTitle' $M 20 $FW 40 @(
        @{Text='The published data is broken for 2020-21. '; Size=17; Bold=$true; Color=$P.Red700}
        @{Text='Here is the proof.'; Size=17; Bold=$true}
    ) @(8,8,304,56) ($z++) -Plain

$c += T 'dqHook' $M 72 604 180 @(
        @{Text='As published'; Size=11; Bold=$true; Color=$P.Red700}
        @{Text="`n`nDelhi, domestic violence 2019:  3,792`nDelhi, domestic violence 2020:  3`n`nDadra & Nagar Haveli (pop. 344,000), 2020:  2,557`n`nDelhi did not stop having domestic violence, and a union territory of 344,000 did not out-report it."; Size=10}
    ) @(8,72,304,200) ($z++)

$c += T 'dqCause' 652 72 604 180 @(
        @{Text='Root cause'; Size=11; Bold=$true}
        @{Text="`n`nOn 31 Oct 2019 J&K became a UT and Ladakh was carved out; on 26 Jan 2020 D&N Haveli merged with Daman & Diu. NCRB's 2020 table lists 28 states then 8 UTs. The CSV pasted that value block against a label column still generated from the pre-2019 36-entity list, where J&K sits at position 9 among the states. Every measure row from position 9 down is attached to the wrong state."; Size=9}
    ) @(8,280,304,220) ($z++)

$c += V 'dqEntities' 'columnChart' $M 268 604 200 ([ordered]@{
        Category=@('C:DimYear.Year'); Y=@('M:FactCrimes.Source Reporting Entities')
    }) 'Reporting entities by year - the 34 to 36 step in 2011 is Delhi and Telangana entering' `
    @(8,508,304,220) $null $P.Teal ($z++)

$c += V 'dqFlags' 'pivotTable' 652 268 604 200 ([ordered]@{
        Rows=@('C:FactQuality.Quality Flag'); Columns=@('C:DimYear.Decade'); Values=@('M:FactQuality.Quality Cells')
    }) 'Three kinds of zero, separated' @(8,736,304,180) $null $null ($z++)

$c += T 'dqTests' $M 484 $FW 212 @(
        @{Text='Four independent tests defend the repair'; Size=11; Bold=$true; Color=$P.Red700}
        @{Text="`n`n1.  Anomaly bands - 16 of 32 entities fall outside a 0.25x-4x band against their 2017-19 mean.`n2.  Crime-mix profile matching in log space - a 2019 control has 34/36 entities matching their own labels; 2020 has only 10/36, but 28/34 match NCRB's published order.`n3.  Year-over-year continuity - median absolute swing falls from 71.2% to 13.9%; implausible jumps above 60% fall from 15 to 0.`n4.  Invariance - all seven measure totals are unchanged. The repair re-labels; it never invents.`n`nThe 2019 control is the one that matters: running the same test on a year believed correct and getting 34/36 proves the method detects misalignment rather than manufacturing it. Because the repair only moves attribution, every national figure in this report is identical with or without it."; Size=9}
    ) @(8,924,304,300) ($z++)

$sections += New-Section 'dataquality' 'Data Quality' 4 $c

# ------------------------------------------------------------------- write --
Write-Host 'Generating report.json...' -ForegroundColor Cyan

$stale = Join-Path $ReportDir 'definition'
if (Test-Path $stale) { Remove-Item $stale -Recurse -Force; Write-Host '  removed stale PBIR definition/ folder' }

$problems = Assert-NoOverlap -Sections $sections
if ($problems.Count -gt 0) {
    Write-Host 'LAYOUT PROBLEMS:' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw 'Refusing to write a report with overlapping or out-of-bounds visuals.'
}
Write-Host '  layout check passed (no overlaps, nothing off-canvas)' -ForegroundColor DarkGray

Write-ReportJson -Path (Join-Path $ReportDir 'report.json') -Sections $sections

$total = ($sections | ForEach-Object { $_.visualContainers.Count } | Measure-Object -Sum).Sum
$mob = 0
foreach ($s in $sections) { foreach ($v in $s.visualContainers) { if ($v.config -match '"id":1') { $mob++ } } }
foreach ($s in $sections) {
    $pm = 0; foreach ($v in $s.visualContainers) { if ($v.config -match '"id":1') { $pm++ } }
    Write-Host ("  {0,-22} {1,2} visuals, {2,2} on phone" -f $s.displayName, $s.visualContainers.Count, $pm)
}
Write-Host "Done: $($sections.Count) pages, $total visuals, $mob phone placements." -ForegroundColor Green
