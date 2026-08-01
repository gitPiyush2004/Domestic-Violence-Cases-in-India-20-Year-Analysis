// ---------------------------------------------------------------------------
// DimCrimeType
// Grain: one row per crime head (7).
// Source: data/processed/dim_crime_type.csv
// ---------------------------------------------------------------------------
// Unpivoting the seven wide crime columns into this dimension is the single
// most important modelling decision in the project. As published, the source
// carries one column per crime (Rape, K&A, DD, AoW, AoM, DV, WT). In that shape
// the question "which crime head grew fastest?" needs seven near-duplicate
// measures and cannot be put on an axis. As a dimension it is one measure and
// one slicer.
//
// is_comparable_series carries the statutory-break warnings - three of the
// seven heads must not be trended across specific years. Surfacing that as a
// model column rather than a footnote means a visual can grey the series out.
// ---------------------------------------------------------------------------

let
    Source = Csv.Document(
        File.Contents( RepoRoot & "\data\processed\dim_crime_type.csv" ),
        [ Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv ]
    ),

    Promoted = Table.PromoteHeaders( Source, [ PromoteAllScalars = true ] ),

    Typed = Table.TransformColumnTypes(
        Promoted,
        {
            { "crime_code",             type text },
            { "crime_type",             type text },
            { "ipc_section",            type text },
            { "total_cases_2001_2021",  Int64.Type },
            { "share_of_all_crime_pct", type number },
            { "cagr_pct",               type number },
            { "is_focus_crime",         type text },
            { "series_break_note",      type text },
            { "is_comparable_series",   type text }
        }
    ),

    ToBool = Table.TransformColumns(
        Typed,
        {
            { "is_focus_crime",       each Text.Lower( _ ) = "true", type logical },
            { "is_comparable_series", each Text.Lower( _ ) = "true", type logical }
        }
    ),

    Selected = Table.SelectColumns(
        ToBool,
        { "crime_code", "crime_type", "ipc_section", "total_cases_2001_2021",
          "share_of_all_crime_pct", "cagr_pct", "is_focus_crime",
          "is_comparable_series", "series_break_note" }
    ),

    Renamed = Table.RenameColumns(
        Selected,
        {
            { "crime_code",             "Crime Code" },
            { "crime_type",             "Crime Type" },
            { "ipc_section",            "IPC Section" },
            { "total_cases_2001_2021",  "Total Cases 2001-2021" },
            { "share_of_all_crime_pct", "Share of All Crime %" },
            { "cagr_pct",               "CAGR % (static)" },
            { "is_focus_crime",         "Is Focus Crime" },
            { "is_comparable_series",   "Is Comparable Series" },
            { "series_break_note",      "Series Break Note" }
        }
    ),

    // Sort crime heads by volume, not alphabetically, so every stacked bar and
    // legend in the report orders the same way and the eye can compare across
    // visuals without re-reading the legend each time.
    Sorted = Table.Sort( Renamed, { { "Total Cases 2001-2021", Order.Descending } } ),
    WithIndex = Table.AddIndexColumn( Sorted, "Crime Sort", 1, 1, Int64.Type )
in
    WithIndex
