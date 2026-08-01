<#
================================================================================
 generate_report.ps1 - emits the PBIR report definition for DomesticViolence
================================================================================
 Power BI's PBIR format stores every visual as its own JSON file. Written by
 hand that is ~1,500 lines of near-duplicate boilerplate where a single stray
 brace silently prevents the whole report from opening - and Power BI Desktop
 reports nothing at all when a project fails to load.

 So the layout is declared compactly at the bottom of this file and the JSON is
 generated. The declaration is what you review; the JSON is a build artefact.

 Run:  pwsh -File powerbi/generate_report.ps1
 Then: open powerbi/DomesticViolence.pbip and refresh.
================================================================================
#>

$ErrorActionPreference = 'Stop'

$ReportRoot = Join-Path $PSScriptRoot 'DomesticViolence.Report'
$DefRoot    = Join-Path $ReportRoot 'definition'
$PagesRoot  = Join-Path $DefRoot 'pages'

$SchemaBase = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition'

# ------------------------------------------------------------------ helpers --

# PBIR encodes literals as strings with a type marker: text is single-quoted,
# numbers carry a D/L suffix, booleans are bare.
function Lit-Text ($v) { @{ expr = @{ Literal = @{ Value = "'$v'" } } } }
function Lit-Num  ($v) { @{ expr = @{ Literal = @{ Value = "$($v)D" } } } }
function Lit-Bool ($v) { @{ expr = @{ Literal = @{ Value = $(if ($v) { 'true' } else { 'false' }) } } } }

function Field-Measure ($Entity, $Property) {
    @{
        field = @{ Measure = @{ Expression = @{ SourceRef = @{ Entity = $Entity } }; Property = $Property } }
        queryRef       = "$Entity.$Property"
        nativeQueryRef = $Property
    }
}

function Field-Column ($Entity, $Property) {
    @{
        field = @{ Column = @{ Expression = @{ SourceRef = @{ Entity = $Entity } }; Property = $Property } }
        queryRef       = "$Entity.$Property"
        nativeQueryRef = $Property
    }
}

# Shorthand: "M:FactCrimes.DV Cases" or "C:DimYear.Year"
function Field ($Spec) {
    $kind = $Spec.Substring(0, 1)
    $rest = $Spec.Substring(2)
    $dot  = $rest.IndexOf('.')
    $ent  = $rest.Substring(0, $dot)
    $prop = $rest.Substring($dot + 1)
    if ($kind -eq 'M') { Field-Measure $ent $prop } else { Field-Column $ent $prop }
}

function Projections ($Specs) {
    ,@($Specs | ForEach-Object { Field $_ })
}

function Title-Object ($Text, $Size = 11) {
    @{
        title = ,@{
            properties = @{
                show     = (Lit-Bool $true)
                text     = (Lit-Text $Text)
                fontSize = (Lit-Num $Size)
                bold     = (Lit-Bool $true)
            }
        }
    }
}

<#
 .SYNOPSIS  Build one visual container.
 .PARAMETER Roles  Ordered hashtable of query-role name -> array of field specs.
#>
function New-Visual {
    param(
        [string]$Name,
        [string]$Type,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [hashtable]$Roles = @{},
        [string]$Title,
        [int]$TitleSize = 11,
        [hashtable]$Objects,
        [array]$SortBy,
        [int]$Z = 0
    )

    $visual = [ordered]@{ visualType = $Type }

    if ($Roles.Count -gt 0) {
        $queryState = [ordered]@{}
        foreach ($role in $Roles.Keys) {
            $queryState[$role] = @{ projections = (Projections $Roles[$role]) }
        }
        $query = [ordered]@{ queryState = $queryState }

        if ($SortBy) {
            $query['sortDefinition'] = @{
                sort = ,@{
                    field     = (Field $SortBy[0]).field
                    direction = $SortBy[1]
                }
            }
        }
        $visual['query'] = $query
    }

    if ($Objects) { $visual['objects'] = $Objects }

    if ($Title) {
        $visual['visualContainerObjects'] = (Title-Object $Title $TitleSize)
    }

    $visual['drillFilterOtherVisuals'] = $true

    [ordered]@{
        '$schema' = "$SchemaBase/visualContainer/1.0.0/schema.json"
        name      = $Name
        position  = [ordered]@{ x = $X; y = $Y; z = $Z; width = $W; height = $H; tabOrder = $Z }
        visual    = $visual
    }
}

# A textbox carries prose rather than a query - used for the narrative panels
# that make each page self-explanatory in a screenshot.
function New-TextBox {
    param(
        [string]$Name,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [array]$Runs,
        [int]$Z = 0
    )

    $textRuns = @($Runs | ForEach-Object {
        $run = @{ value = $_.Text }
        $style = @{}
        if ($_.Size)  { $style['fontSize']   = "$($_.Size)pt" }
        if ($_.Bold)  { $style['fontWeight'] = 'bold' }
        if ($_.Color) { $style['color']      = $_.Color }
        if ($style.Count -gt 0) { $run['textStyle'] = $style }
        $run
    })

    [ordered]@{
        '$schema' = "$SchemaBase/visualContainer/1.0.0/schema.json"
        name      = $Name
        position  = [ordered]@{ x = $X; y = $Y; z = $Z; width = $W; height = $H; tabOrder = $Z }
        visual    = [ordered]@{
            visualType = 'textbox'
            objects    = @{
                general = ,@{
                    properties = @{
                        paragraphs = ,@{ textRuns = $textRuns }
                    }
                }
            }
        }
    }
}

function Write-Json ($Object, $Path) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 40
    # Windows PowerShell 5.1 over-escapes a handful of ASCII punctuation as \uXXXX.
    # PBIR literals are single-quoted ("'text'"), so the apostrophe escape in
    # particular has to come back or every title renders as 'text'.
    #
    # Targeted replacements only - Regex::Unescape would also convert the \n
    # inside textbox strings into real newlines, which is invalid JSON. Power
    # BI's parser rejects that outright while PowerShell's silently accepts it,
    # so the mistake is invisible until Desktop refuses to open the project.
    $bs = [char]0x5C   # backslash, built from a code point so this file has none
    foreach ($pair in @(
        @("${bs}u0027", "'"),
        @("${bs}u003c", '<'),
        @("${bs}u003e", '>'),
        @("${bs}u0026", '&')
    )) {
        $json = $json.Replace($pair[0], $pair[1])
    }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Page {
    param(
        [string]$Id, [string]$DisplayName, [array]$Visuals, [int]$Ordinal,
        [hashtable]$Mobile = @{}
    )

    $pageDir = Join-Path $PagesRoot $Id
    if (Test-Path $pageDir) { Remove-Item $pageDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $pageDir | Out-Null

    Write-Json ([ordered]@{
        '$schema'     = "$SchemaBase/page/1.0.0/schema.json"
        name          = $Id
        displayName   = $DisplayName
        displayOption = 'FitToPage'
        height        = 720
        width         = 1280
    }) (Join-Path $pageDir 'page.json')

    $sep = [System.IO.Path]::DirectorySeparatorChar
    foreach ($v in $Visuals) {
        $vdir = Join-Path $pageDir "visuals$sep$($v.name)"
        Write-Json $v (Join-Path $vdir 'visual.json')

        # A visual appears on the phone canvas only if it has a mobile.json.
        # Omitting one is therefore how the scatter and the filled map get
        # dropped on mobile - neither survives at 320px, and a shrunken version
        # is worse than an absent one.
        if ($Mobile.ContainsKey($v.name)) {
            $m = $Mobile[$v.name]
            Write-Json ([ordered]@{
                '$schema' = "$SchemaBase/visualContainerMobileState/1.0.0/schema.json"
                position  = [ordered]@{
                    x = $m[0]; y = $m[1]; z = 0
                    width = $m[2]; height = $m[3]; tabOrder = 0
                }
            }) (Join-Path $vdir 'mobile.json')
        }
    }

    Write-Host ("  {0,-14} {1,-26} {2,2} visuals, {3,2} on mobile" -f `
        $Id, $DisplayName, $Visuals.Count, $Mobile.Count)
}

# ------------------------------------------------------------------- layout --
# Canvas 1280x720. Everything below is on an 8px grid.

$PAGES = [ordered]@{}

# ============================================================ 1. OVERVIEW ====
# Question: how big is this, and is it getting worse?

$kpi = @(
    @{ n = 'kpiAll';    m = 'M:FactCrimes.All Crime Cases';  t = 'All crimes vs women' }
    @{ n = 'kpiDV';     m = 'M:FactCrimes.DV Cases';         t = 'Domestic violence' }
    @{ n = 'kpiShare';  m = 'M:FactCrimes.DV Share %';       t = 'DV share' }
    @{ n = 'kpiCagr';   m = 'M:FactCrimes.DV CAGR %';        t = 'Annual growth' }
    @{ n = 'kpiStates'; m = 'M:FactCrimes.States Reporting'; t = 'Entities' }
    @{ n = 'kpiYears';  m = 'M:FactCrimes.Years Covered';    t = 'Years' }
)

$ov = @()
$ov += New-TextBox -Name 'ovTitle' -X 32 -Y 16 -W 744 -H 52 -Runs @(
    @{ Text = 'Domestic violence in India, 2001-2021'; Size = 20; Bold = $true }
)
$ov += New-Visual -Name 'ovContext' -Type 'card' -X 792 -Y 16 -W 456 -H 52 `
    -Roles @{ Values = @('M:FactCrimes.Filter Context Label') }

$x = 32
foreach ($k in $kpi) {
    $ov += New-Visual -Name $k.n -Type 'card' -X $x -Y 80 -W 192 -H 96 `
        -Roles @{ Values = @($k.m) } -Title $k.t -TitleSize 10
    $x += 204
}

$ov += New-Visual -Name 'ovTrend' -Type 'lineClusteredColumnComboChart' `
    -X 32 -Y 188 -W 744 -H 268 `
    -Roles ([ordered]@{
        Category = @('C:DimYear.Year')
        Y        = @('M:FactCrimes.DV Cases')
        Y2       = @('M:FactCrimes.DV 3Y Moving Avg')
    }) -Title 'Reported domestic violence by year, with 3-year trailing mean'

$ov += New-Visual -Name 'ovMix' -Type 'donutChart' -X 792 -Y 188 -W 456 -H 268 `
    -Roles ([ordered]@{
        Category = @('C:DimCrimeType.Crime Type')
        Y        = @('M:FactCrimes.Total Cases')
    }) -Title 'Crime mix, all 21 years'

$ov += New-Visual -Name 'ovStates' -Type 'clusteredBarChart' -X 32 -Y 468 -W 744 -H 236 `
    -Roles ([ordered]@{
        Category = @('C:DimState.State')
        Y        = @('M:FactCrimes.DV Cases')
    }) -SortBy @('M:FactCrimes.DV Cases', 'Descending') `
    -Title 'Domestic violence by state'

$ov += New-Visual -Name 'ovAbc' -Type 'card' -X 792 -Y 468 -W 456 -H 68 `
    -Roles @{ Values = @('M:FactCrimes.ABC Headline') }

$ov += New-Visual -Name 'ovYear' -Type 'slicer' -X 792 -Y 548 -W 224 -H 156 `
    -Roles @{ Values = @('C:DimYear.Year') } -Title 'Year'

$ov += New-Visual -Name 'ovRegion' -Type 'slicer' -X 1028 -Y 548 -W 220 -H 156 `
    -Roles @{ Values = @('C:DimState.Region') } -Title 'Region'

# Phone canvas is 320 wide and scrolls vertically. One column, priority order,
# slicers collapsed to the bottom. Two KPI cards per row is the most that stays
# legible; the remaining two cards are dropped rather than shrunk.
$PAGES['overview'] = @{
    Name = 'Executive Overview'; Visuals = $ov
    Mobile = @{
        kpiAll   = @(0, 0, 156, 96);    kpiDV    = @(164, 0, 156, 96)
        kpiShare = @(0, 104, 156, 96);  kpiCagr  = @(164, 104, 156, 96)
        ovTrend  = @(0, 208, 320, 240)
        ovStates = @(0, 456, 320, 300)
        ovAbc    = @(0, 764, 320, 96)
        ovYear   = @(0, 868, 320, 120)
    }
}

# ========================================================== 2. CRIME TYPES ===
# Question: is domestic violence growing faster than everything else? (No.)

$ct = @()
$ct += New-TextBox -Name 'ctTitle' -X 32 -Y 16 -W 1216 -H 44 -Runs @(
    @{ Text = 'Crime heads compared'; Size = 18; Bold = $true }
)

$ct += New-Visual -Name 'ctIndexed' -Type 'lineChart' -X 32 -Y 72 -W 744 -H 300 `
    -Roles ([ordered]@{
        Category = @('C:DimYear.Year')
        Series   = @('C:DimCrimeType.Crime Type')
        Y        = @('M:FactCrimes.DV Index (Base = 100)')
    }) -Title 'Indexed to 100 in the first visible year'

$ct += New-Visual -Name 'ctCagr' -Type 'clusteredBarChart' -X 792 -Y 72 -W 456 -H 300 `
    -Roles ([ordered]@{
        Category = @('C:DimCrimeType.Crime Type')
        Y        = @('C:DimCrimeType.CAGR % (static)')
    }) -SortBy @('C:DimCrimeType.CAGR % (static)', 'Descending') `
    -Title 'Compound annual growth by head'

$ct += New-Visual -Name 'ctTable' -Type 'tableEx' -X 32 -Y 384 -W 744 -H 240 `
    -Roles @{ Values = @(
        'C:DimCrimeType.Crime Type'
        'C:DimCrimeType.IPC Section'
        'C:DimCrimeType.Total Cases 2001-2021'
        'C:DimCrimeType.Share of All Crime %'
        'C:DimCrimeType.Is Comparable Series'
    ) } -Title 'The seven heads, with statutory basis'

$ct += New-TextBox -Name 'ctNote' -X 792 -Y 384 -W 456 -H 240 -Runs @(
    @{ Text = 'Dowry deaths are the control.'; Size = 12; Bold = $true }
    @{ Text = "`n`nEvery head grew except dowry deaths: 6,738 in 2001, 6,753 in 2021. Deaths are the hardest category to under-report, so flat deaths against a 178% rise in cruelty complaints argues that much of the growth is rising reporting propensity rather than rising incidence.`n`nThat is an argument, not a proof. This data cannot separate the two."; Size = 10 }
)

$ct += New-Visual -Name 'ctYear' -Type 'slicer' -X 32 -Y 636 -W 456 -H 68 `
    -Roles @{ Values = @('C:DimYear.Year') } -Title 'Year'

$ct += New-Visual -Name 'ctCrime' -Type 'slicer' -X 504 -Y 636 -W 272 -H 68 `
    -Roles @{ Values = @('C:DimCrimeType.Crime Type') } -Title 'Crime head'

# CAGR bar leads on mobile, not the indexed line - a seven-series line chart is
# unreadable at 320px, but it is worth keeping below the fold for scrolling.
$PAGES['crimetypes'] = @{
    Name = 'Crime Type Trends'; Visuals = $ct
    Mobile = @{
        ctCagr    = @(0, 0, 320, 260)
        ctIndexed = @(0, 268, 320, 260)
        ctTable   = @(0, 536, 320, 240)
        ctNote    = @(0, 784, 320, 200)
    }
}

# =========================================================== 3. STATE VIEW ===
# Question: where is it worst - and does that depend on how you ask?

$st = @()
$st += New-TextBox -Name 'stTitle' -X 32 -Y 16 -W 744 -H 44 -Runs @(
    @{ Text = 'Volume and intensity disagree'; Size = 18; Bold = $true }
)
$st += New-Visual -Name 'stVerdict' -Type 'card' -X 792 -Y 16 -W 456 -H 44 `
    -Roles @{ Values = @('M:FactCrimes.State Verdict') }

$st += New-Visual -Name 'stScatter' -Type 'scatterChart' -X 32 -Y 72 -W 744 -H 336 `
    -Roles ([ordered]@{
        Category = @('C:DimState.State')
        X        = @('M:FactCrimes.DV Cases')
        Y        = @('M:FactCrimes.DV Rate per Lakh Women (Annual Avg)')
        Size     = @('C:DimState.Female Population 2011')
    }) -Title 'Case volume against intensity - the top-left quadrant is what volume ranking misses'

$st += New-Visual -Name 'stMap' -Type 'filledMap' -X 792 -Y 72 -W 456 -H 336 `
    -Roles ([ordered]@{
        Category = @('C:DimState.State')
        Y        = @('M:FactCrimes.DV Rate per Lakh Women (Annual Avg)')
    }) -Title 'Intensity by state'

$st += New-Visual -Name 'stTable' -Type 'tableEx' -X 32 -Y 420 -W 976 -H 284 `
    -Roles @{ Values = @(
        'C:DimState.State'
        'M:FactCrimes.DV Cases'
        'M:FactCrimes.DV Rank'
        'M:FactCrimes.DV Rate per Lakh Women (Annual Avg)'
        'M:FactCrimes.DV Rate Rank'
        'M:FactCrimes.Volume vs Intensity Gap'
        'M:FactCrimes.ABC Class'
        'M:FactCrimes.Risk Zone'
    ) } -SortBy @('M:FactCrimes.Volume vs Intensity Gap', 'Descending') `
    -Title 'Sorted by the gap - the most-missed states first'

$st += New-Visual -Name 'stRegion' -Type 'slicer' -X 1024 -Y 420 -W 224 -H 136 `
    -Roles @{ Values = @('C:DimState.Region') } -Title 'Region'

$st += New-Visual -Name 'stEntity' -Type 'slicer' -X 1024 -Y 568 -W 224 -H 136 `
    -Roles @{ Values = @('C:DimState.Entity Type') } -Title 'Entity type'

# Scatter and filled map are deliberately absent from the phone layout. The
# scatter carries the page's whole argument at desktop size and communicates
# nothing at 320px; a map is worse. The verdict card states the finding in
# words instead, which is the right mobile substitute for a quadrant chart.
$PAGES['statedeepdive'] = @{
    Name = 'State Deep Dive'; Visuals = $st
    Mobile = @{
        stVerdict = @(0, 0, 320, 96)
        stTable   = @(0, 104, 320, 340)
        stRegion  = @(0, 452, 320, 120)
    }
}

# ================================================================== 4. ABC ===
# Question: if you could only fund eight programmes, which eight?

$ab = @()
$ab += New-TextBox -Name 'abTitle' -X 32 -Y 16 -W 744 -H 44 -Runs @(
    @{ Text = 'ABC classification and priority'; Size = 18; Bold = $true }
)
$ab += New-Visual -Name 'abHeadline' -Type 'card' -X 792 -Y 16 -W 456 -H 44 `
    -Roles @{ Values = @('M:FactCrimes.ABC Headline') }

$ab += New-Visual -Name 'abPareto' -Type 'lineClusteredColumnComboChart' `
    -X 32 -Y 72 -W 1216 -H 296 `
    -Roles ([ordered]@{
        Category = @('C:DimState.State')
        Y        = @('M:FactCrimes.DV Cases')
        Y2       = @('M:FactCrimes.DV Cumulative Share %')
    }) -SortBy @('M:FactCrimes.DV Cases', 'Descending') `
    -Title 'Pareto - bars are volume, line is cumulative share (70% and 90% are the ABC cuts)'

$ab += New-Visual -Name 'abMatrix' -Type 'pivotTable' -X 32 -Y 380 -W 600 -H 244 `
    -Roles ([ordered]@{
        Rows    = @('M:FactCrimes.ABC Class')
        Columns = @('M:FactCrimes.Risk Zone')
        Values  = @('M:FactCrimes.States Reporting')
    }) -Title 'Where the two segmentations disagree'

$ab += New-Visual -Name 'abPriority' -Type 'tableEx' -X 648 -Y 380 -W 600 -H 244 `
    -Roles @{ Values = @(
        'C:DimState.State'
        'M:FactCrimes.Priority Segment'
        'M:FactCrimes.DV Cases'
    ) } -SortBy @('M:FactCrimes.DV Cases', 'Descending') `
    -Title 'Priority segments'

$ab += New-TextBox -Name 'abNote' -X 32 -Y 636 -W 1216 -H 68 -Runs @(
    @{ Text = 'ABC bands by volume; risk zones band by intensity. They are meant to disagree - a Class C entity in the Critical zone is small, badly affected, and invisible to every volume-ranked league table. Thresholds are the quartiles of the 2021 rate distribution (2.5 / 9.1 / 22.9 per lakh women), not round numbers, so they survive a refresh without quietly changing meaning.'; Size = 10 }
)

# The ABC/Risk matrix is dropped on mobile - a cross-tab needs horizontal room
# it will never have, and the priority table carries the same conclusion.
$PAGES['abc'] = @{
    Name = 'ABC & Priority'; Visuals = $ab
    Mobile = @{
        abHeadline = @(0, 0, 320, 96)
        abPareto   = @(0, 104, 320, 280)
        abPriority = @(0, 392, 320, 280)
        abNote     = @(0, 680, 320, 140)
    }
}

# ========================================================= 5. DATA QUALITY ===
# The page most portfolio dashboards hide. This one leads with it.

$dq = @()
$dq += New-TextBox -Name 'dqTitle' -X 32 -Y 16 -W 1216 -H 44 -Runs @(
    @{ Text = 'The published data is broken for 2020-21. Here is the proof.'; Size = 18; Bold = $true }
)

$dq += New-TextBox -Name 'dqHook' -X 32 -Y 72 -W 600 -H 168 -Runs @(
    @{ Text = 'As published:'; Size = 12; Bold = $true }
    @{ Text = "`n`nDelhi, domestic violence 2019: 3,792`nDelhi, domestic violence 2020: 3`n`nDadra & Nagar Haveli (pop. 344,000), 2020: 2,557`n`nDelhi did not stop having domestic violence, and a union territory of 344,000 did not out-report it."; Size = 11 }
)

$dq += New-TextBox -Name 'dqCause' -X 648 -Y 72 -W 600 -H 168 -Runs @(
    @{ Text = 'Root cause:'; Size = 12; Bold = $true }
    @{ Text = "`n`nOn 31 Oct 2019 J&K became a UT and Ladakh was carved out; on 26 Jan 2020 D&N Haveli merged with Daman & Diu. NCRB's 2020 table lists 28 states then 8 UTs. The CSV pasted that value block against a label column still generated from the pre-2019 36-entity list, where J&K sits at position 9 among the states. Every measure row from position 9 down is attached to the wrong state."; Size = 10 }
)

$dq += New-Visual -Name 'dqEntities' -Type 'columnChart' -X 32 -Y 256 -W 600 -H 224 `
    -Roles ([ordered]@{
        Category = @('C:DimYear.Year')
        Y        = @('C:DimYear.Reporting Entities')
    }) -Title 'Reporting entities by year - the 34 to 36 step in 2011 is Delhi and Telangana entering'

$dq += New-Visual -Name 'dqFlags' -Type 'pivotTable' -X 648 -Y 256 -W 600 -H 224 `
    -Roles ([ordered]@{
        Rows    = @('C:FactCrimes.data_quality_flag')
        Columns = @('C:DimYear.Decade')
        Values  = @('M:FactCrimes.Fact Rows')
    }) -Title 'Three kinds of zero, separated'

$dq += New-TextBox -Name 'dqTests' -X 32 -Y 496 -W 1216 -H 208 -Runs @(
    @{ Text = 'Four independent tests defend the repair'; Size = 12; Bold = $true }
    @{ Text = "`n`n1.  Anomaly bands - 16 of 32 entities fall outside a 0.25x-4x band against their 2017-19 mean.`n2.  Crime-mix profile matching in log space - a 2019 control has 34/36 entities matching their own labels; 2020 has only 10/36, but 28/34 match NCRB's published order.`n3.  Year-over-year continuity - median absolute swing falls from 71.2% to 13.9%; implausible jumps above 60% fall from 15 to 0.`n4.  Invariance - all seven measure totals are unchanged. The repair re-labels; it never invents.`n`nThe 2019 control is the one that matters: running the same test on a year believed correct and getting 34/36 proves the method detects misalignment rather than manufacturing it. Because the repair only moves attribution, every national figure in this report is identical with or without it - only state-level 2020-21 attribution was ever at risk."; Size = 10 }
)

# This page is mostly prose, which is the one thing that reads well on a phone.
# The flag matrix is dropped; the entity-count chart survives because it is a
# single series.
$PAGES['dataquality'] = @{
    Name = 'Data Quality'; Visuals = $dq
    Mobile = @{
        dqTitle    = @(0, 0, 320, 60)
        dqHook     = @(0, 68, 320, 210)
        dqCause    = @(0, 286, 320, 230)
        dqTests    = @(0, 524, 320, 300)
        dqEntities = @(0, 832, 320, 240)
    }
}

# ------------------------------------------------------------------- write --

Write-Host "Generating PBIR report definition..." -ForegroundColor Cyan

if (Test-Path $PagesRoot) { Remove-Item $PagesRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $PagesRoot | Out-Null

$ordinal = 0
foreach ($id in $PAGES.Keys) {
    $mob = if ($PAGES[$id].Mobile) { $PAGES[$id].Mobile } else { @{} }
    Write-Page -Id $id -DisplayName $PAGES[$id].Name -Visuals $PAGES[$id].Visuals `
        -Ordinal $ordinal -Mobile $mob
    $ordinal++
}

Write-Json ([ordered]@{
    '$schema'      = "$SchemaBase/pagesMetadata/1.0.0/schema.json"
    pageOrder      = @($PAGES.Keys)
    activePageName = @($PAGES.Keys)[0]
}) (Join-Path $PagesRoot 'pages.json')

Write-Json ([ordered]@{
    '$schema'          = "$SchemaBase/report/1.0.0/schema.json"
    themeCollection    = @{ baseTheme = @{ name = 'CY24SU10'; reportThemeType = 'SharedResources' } }
    layoutOptimization = 'None'
}) (Join-Path $DefRoot 'report.json')

Write-Json ([ordered]@{
    '$schema' = "$SchemaBase/versionMetadata/1.0.0/schema.json"
    version   = '4.0'
}) (Join-Path $DefRoot 'version.json')

$total = ($PAGES.Values | ForEach-Object { $_.Visuals.Count } | Measure-Object -Sum).Sum
Write-Host "Done: $($PAGES.Count) pages, $total visuals." -ForegroundColor Green
