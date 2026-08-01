<#
================================================================================
 lib_report.ps1 - emitter for the legacy Power BI report.json format
================================================================================
 Power BI Desktop 2.156 stores a PBIP report as a SINGLE report.json at the
 Report root - not as the PBIR definition/ folder tree. This was established by
 letting Desktop save the project itself and reading back what it wrote.

 The format nests JSON inside JSON: a visual's whole definition is a JSON
 document serialised into the "config" string of its container. That is why this
 emitter exists rather than hand-written files.

 Encoding notes learned from Desktop's own output:
   - config strings carry the version marker "5.37"
   - each visual needs a prototypeQuery whose Select entry Name matches the
     projection queryRef exactly, or the visual binds to nothing
   - mobile layout is the layouts[] entry with id = 1; desktop is id = 0
   - colours are string literals including the quotes: "'#C1121F'"
================================================================================
#>

$script:CONFIG_VERSION = '5.37'

# --- palette ----------------------------------------------------------------
# Deep reds carry the focus crime; everything else is warm neutral so the red
# actually means something. A dashboard where every element is red says nothing.
$script:PAL = @{
    Ink      = '#1F2933'
    Muted    = '#6B7280'
    Canvas   = '#FAF7F5'
    Tile     = '#FFFFFF'
    Border   = '#E7DEDA'
    Red900   = '#6A040F'
    Red700   = '#9D0208'
    Red500   = '#C1121F'
    Red300   = '#E5484D'
    Sand     = '#BC8A5F'
    Stone    = '#8A817C'
    Teal     = '#31708E'
}

function New-Id {
    param([string]$Seed)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Seed))
    (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 20)
}

# --- literal helpers --------------------------------------------------------
function LitT ($v) { @{ expr = @{ Literal = @{ Value = "'$v'" } } } }
function LitN ($v) { @{ expr = @{ Literal = @{ Value = "$($v)D" } } } }
function LitB ($v) { @{ expr = @{ Literal = @{ Value = $(if ($v) { 'true' } else { 'false' }) } } } }
function Col  ($hex) { @{ solid = @{ color = (LitT $hex) } } }

function Parse-Spec {
    param([string]$Spec)
    $kind = $Spec.Substring(0, 1)
    $rest = $Spec.Substring(2)
    $dot  = $rest.IndexOf('.')
    [pscustomobject]@{
        Kind     = $(if ($kind -eq 'M') { 'Measure' } else { 'Column' })
        Entity   = $rest.Substring(0, $dot)
        Property = $rest.Substring($dot + 1)
        QueryRef = $rest
    }
}

<#
 .SYNOPSIS Build one legacy visualContainer.
 .PARAMETER Roles   [ordered] role -> array of "M:Entity.Prop" / "C:Entity.Prop"
 .PARAMETER Mobile  @(x,y,w,h) or $null - a visual with no mobile entry is simply
                    absent from the phone canvas, which is how the visuals that
                    cannot survive 320px get dropped rather than shrunk.
 .PARAMETER Color   hex for single-series data points
 .PARAMETER Plain   suppress the white tile + border (used for text panels)
#>
function New-Container {
    param(
        [string]$Name, [string]$Type,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        $Roles, [string]$Title, [int]$TitleSize = 10,
        $Mobile, $SortBy, $TextRuns, [int]$Z = 0,
        [string]$Color, [switch]$Plain, [int]$CardSize = 26, [switch]$HideLegend
    )

    $vid = New-Id $Name

    $layouts = @( @{ id = 0; position = [ordered]@{ x = $X; y = $Y; z = $Z; width = $W; height = $H; tabOrder = ($Z * 100) } } )
    if ($Mobile) {
        $layouts += @{ id = 1; position = [ordered]@{ x = $Mobile[0]; y = $Mobile[1]; z = $Z; width = $Mobile[2]; height = $Mobile[3]; tabOrder = ($Z * 100) } }
    }

    $single = [ordered]@{ visualType = $Type }

    if ($Roles -and $Roles.Count -gt 0) {
        $aliases = @{}
        $from    = @()
        $select  = @()
        $projections = [ordered]@{}

        foreach ($role in $Roles.Keys) {
            $refs = @()
            foreach ($spec in $Roles[$role]) {
                $f = Parse-Spec $spec
                if (-not $aliases.ContainsKey($f.Entity)) {
                    $alias = 'e' + $aliases.Count
                    $aliases[$f.Entity] = $alias
                    $from += [ordered]@{ Name = $alias; Entity = $f.Entity; Type = 0 }
                }
                $a = $aliases[$f.Entity]
                $sel = [ordered]@{}
                $sel[$f.Kind] = [ordered]@{
                    Expression = @{ SourceRef = @{ Source = $a } }
                    Property   = $f.Property
                }
                $sel['Name'] = $f.QueryRef
                $sel['NativeReferenceName'] = $f.Property
                $select += $sel
                $refs   += @{ queryRef = $f.QueryRef }
            }
            $projections[$role] = @($refs)
        }

        $proto = [ordered]@{ Version = 2; From = @($from); Select = @($select) }

        if ($SortBy) {
            $sf = Parse-Spec $SortBy[0]
            $dir = if ($SortBy[1] -eq 'Descending') { 2 } else { 1 }
            if (-not $aliases.ContainsKey($sf.Entity)) {
                $sa = 'e' + $aliases.Count
                $aliases[$sf.Entity] = $sa
                $proto.From += [ordered]@{ Name = $sa; Entity = $sf.Entity; Type = 0 }
            }
            $ordExpr = [ordered]@{}
            $ordExpr[$sf.Kind] = [ordered]@{
                Expression = @{ SourceRef = @{ Source = $aliases[$sf.Entity] } }
                Property   = $sf.Property
            }
            $proto['OrderBy'] = @( [ordered]@{ Direction = $dir; Expression = $ordExpr } )
        }

        $single['projections']    = $projections
        $single['prototypeQuery'] = $proto
    }

    # --- visual-level formatting --------------------------------------------
    $objects = [ordered]@{}

    if ($TextRuns) {
        $runs = @($TextRuns | ForEach-Object {
            $r = [ordered]@{ value = $_.Text }
            $st = [ordered]@{}
            if ($_.Size)  { $st['fontSize']   = "$($_.Size)pt" }
            if ($_.Bold)  { $st['fontWeight'] = 'bold' }
            if ($_.Color) { $st['color']      = $_.Color } else { $st['color'] = $script:PAL.Ink }
            $st['fontFamily'] = "'Segoe UI', wf_segoe-ui_normal, helvetica, arial, sans-serif"
            $r['textStyle'] = $st
            $r
        })
        $objects['general'] = @( @{ properties = @{ paragraphs = @( @{ textRuns = $runs } ) } } )
    }

    if ($Color -and $Type -ne 'textbox' -and $Type -ne 'card' -and $Type -ne 'slicer') {
        $objects['dataPoint'] = @( @{ properties = @{ defaultColor = (Col $Color) } } )
    }

    if ($Type -eq 'card') {
        $objects['labels'] = @( @{ properties = [ordered]@{
            color    = (Col $(if ($Color) { $Color } else { $script:PAL.Ink }))
            fontSize = (LitN $CardSize)
            bold     = (LitB $true)
        } } )
        # Category label OFF. The container title already names the measure, so
        # the label underneath was a second copy of the same words - and the
        # three stacked elements (title, value, label) overflowed a 96px card
        # once the title was centred, clipping the value itself.
        $objects['categoryLabels'] = @( @{ properties = [ordered]@{
            show = (LitB $false)
        } } )
    }

    if ($Type -in @('clusteredBarChart', 'columnChart', 'lineChart', 'lineClusteredColumnComboChart', 'scatterChart', 'donutChart')) {
        $objects['legend'] = @( @{ properties = [ordered]@{ show = (LitB (-not $HideLegend)); fontSize = (LitN 9); labelColor = (Col $script:PAL.Muted); position = (LitT 'Bottom') } } )
        $objects['categoryAxis']   = @( @{ properties = [ordered]@{ fontSize = (LitN 9); labelColor = (Col $script:PAL.Muted); showAxisTitle = (LitB $false) } } )
        $objects['valueAxis']      = @( @{ properties = [ordered]@{ fontSize = (LitN 9); labelColor = (Col $script:PAL.Muted); showAxisTitle = (LitB $false) } } )
    }

    if ($Type -in @('tableEx', 'pivotTable')) {
        $objects['grid']   = @( @{ properties = [ordered]@{ gridVertical = (LitB $false); outlineColor = (Col $script:PAL.Border) } } )
        $objects['values'] = @( @{ properties = [ordered]@{ fontSize = (LitN 9); fontColor = (Col $script:PAL.Ink) } } )
        $objects['columnHeaders'] = @( @{ properties = [ordered]@{ fontSize = (LitN 9); bold = (LitB $true); fontColor = (Col $script:PAL.Muted) } } )
    }

    $single['objects'] = $objects

    # --- container-level formatting (the "tile" look) -----------------------
    $vc = [ordered]@{}
    if ($Title) {
        # KPI cards centre their title so the title, the value and the category
        # label all sit on one axis. Charts keep left-aligned titles, which is
        # where the eye starts on a plot.
        $align = if ($Type -eq 'card') { 'center' } else { 'left' }
        # 9pt on cards: at 10pt, "Domestic violence" and "Annual growth" both
        # truncate inside a 192px tile once the title is centred.
        if ($Type -eq 'card') { $TitleSize = 9 }
        $vc['title'] = @( @{ properties = [ordered]@{
            show       = (LitB $true)
            text       = (LitT ($Title -replace "'", "''"))
            fontSize   = (LitN $TitleSize)
            bold       = (LitB $true)
            fontColor  = (Col $script:PAL.Ink)
            alignment  = (LitT $align)
        } } )
    }
    if (-not $Plain) {
        $vc['background'] = @( @{ properties = [ordered]@{
            show         = (LitB $true)
            color        = (Col $script:PAL.Tile)
            transparency = (LitN 0)
        } } )
        $vc['border'] = @( @{ properties = [ordered]@{
            show   = (LitB $true)
            color  = (Col $script:PAL.Border)
            radius = (LitN 6)
        } } )
        $vc['padding'] = @( @{ properties = [ordered]@{
            left = (LitN 8); right = (LitN 8); top = (LitN 6); bottom = (LitN 6)
        } } )
    }
    $single['vcObjects'] = $vc
    $single['drillFilterOtherVisuals'] = $true

    $config = [ordered]@{ name = $vid; layouts = @($layouts); singleVisual = $single }

    [ordered]@{
        x = $X; y = $Y; z = $Z; width = $W; height = $H
        config  = ($config | ConvertTo-Json -Depth 40 -Compress)
        filters = '[]'
    }
}

function New-Section {
    param([string]$Id, [string]$DisplayName, [int]$Ordinal, [array]$Containers)

    $pageCfg = [ordered]@{
        objects = [ordered]@{
            background = @( @{ properties = [ordered]@{
                color        = (Col $script:PAL.Canvas)
                transparency = (LitN 0)
            } } )
            displayArea = @( @{ properties = [ordered]@{ verticalAlignment = (LitT 'Top') } } )
        }
    }

    [ordered]@{
        name             = (New-Id "section-$Id")
        displayName      = $DisplayName
        filters          = '[]'
        ordinal          = $Ordinal
        visualContainers = @($Containers)
        config           = ($pageCfg | ConvertTo-Json -Depth 20 -Compress)
        displayOption    = 0
        width            = 1280
        height           = 720
    }
}

<#
 .SYNOPSIS Fail the build if any two visuals overlap, on either canvas.
 Catching this here is much cheaper than spotting it in a screenshot.
#>
function Assert-NoOverlap {
    param([array]$Sections)
    $problems = @()
    foreach ($s in $Sections) {
        foreach ($layoutId in 0, 1) {
            $boxes = @()
            foreach ($v in $s.visualContainers) {
                $cfg = $v.config | ConvertFrom-Json
                $L = $cfg.layouts | Where-Object { $_.id -eq $layoutId }
                if ($L) {
                    $boxes += [pscustomobject]@{
                        Name = $cfg.name
                        X = $L.position.x; Y = $L.position.y
                        W = $L.position.width; H = $L.position.height
                    }
                }
            }
            for ($i = 0; $i -lt $boxes.Count; $i++) {
                for ($j = $i + 1; $j -lt $boxes.Count; $j++) {
                    $a = $boxes[$i]; $b = $boxes[$j]
                    $overlapX = ($a.X -lt ($b.X + $b.W)) -and ($b.X -lt ($a.X + $a.W))
                    $overlapY = ($a.Y -lt ($b.Y + $b.H)) -and ($b.Y -lt ($a.Y + $a.H))
                    if ($overlapX -and $overlapY) {
                        $canvas = if ($layoutId -eq 0) { 'desktop' } else { 'mobile' }
                        $problems += "$($s.displayName) [$canvas]: $($a.Name) overlaps $($b.Name)"
                    }
                }
            }
            # desktop canvas is 1280x720; the phone canvas scrolls vertically
            foreach ($b in $boxes) {
                if ($b.X -lt 0 -or ($b.X + $b.W) -gt $(if ($layoutId -eq 0) { 1280 } else { 320 })) {
                    $problems += "$($s.displayName): $($b.Name) runs off the right edge"
                }
                if ($layoutId -eq 0 -and ($b.Y + $b.H) -gt 720) {
                    $problems += "$($s.displayName): $($b.Name) runs off the bottom"
                }
            }
        }
    }
    return $problems
}

function Write-ReportJson {
    param([string]$Path, [array]$Sections)

    $cfg = [ordered]@{
        version                     = $script:CONFIG_VERSION
        themeCollection             = @{}
        activeSectionIndex          = 0
        linguisticSchemaSyncVersion = 2
    }

    $report = [ordered]@{
        config             = ($cfg | ConvertTo-Json -Depth 10 -Compress)
        layoutOptimization = 0
        report             = @{}
        sections           = @($Sections)
    }

    $json = $report | ConvertTo-Json -Depth 60

    # Deliberately NO un-escaping pass.
    #
    # PS 5.1 renders an apostrophe as ', a valid JSON escape that decodes
    # back to ' on read. "Fixing" it corrupts this format: the inner config JSON
    # already contains ', the outer document escapes that backslash to
    # \\u0027, and a naive .Replace() turns it into \' - not a valid escape, and
    # Power BI rejects the document. The double encoding round-trips correctly
    # on its own.
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
