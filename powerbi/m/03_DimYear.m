// ---------------------------------------------------------------------------
// DimYear
// Grain: one row per year, 2001-2021 (21 rows).
// Source: data/processed/dim_year.csv
// ---------------------------------------------------------------------------
// This is deliberately a YEAR dimension, not a Power BI auto date table.
//
// The fact grain is annual - there is no month, day or transaction date in NCRB
// annual tables. Marking a real calendar table here would invite DATEADD /
// SAMEPERIODLASTYEAR against 21 synthetic 1 January dates, which works but
// implies a precision the source does not have. Year-over-year is instead done
// with an explicit integer offset (see 02_time_intelligence.dax), which is both
// honest about the grain and faster.
//
// Auto date/time should be switched OFF for this model:
//   File > Options > Data Load > Time intelligence > uncheck Auto date/time
// ---------------------------------------------------------------------------

let
    Source = Csv.Document(
        File.Contents( RepoRoot & "\data\processed\dim_year.csv" ),
        [ Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv ]
    ),

    Promoted = Table.PromoteHeaders( Source, [ PromoteAllScalars = true ] ),

    Typed = Table.TransformColumnTypes(
        Promoted,
        {
            { "year",                  Int64.Type },
            { "decade",                type text },
            { "source_export",         type text },
            { "label_alignment",       type text },
            { "is_covid_year",         type text },
            { "reporting_entities",    Int64.Type },
            { "all_crimes_comparable", type text },
            { "coverage_note",         type text }
        }
    ),

    // pandas writes Python booleans as the strings "True"/"False".
    ToBool = Table.TransformColumns(
        Typed,
        {
            { "is_covid_year",         each Text.Lower( _ ) = "true", type logical },
            { "all_crimes_comparable", each Text.Lower( _ ) = "true", type logical }
        }
    ),

    Renamed = Table.RenameColumns(
        ToBool,
        {
            { "year",                  "Year" },
            { "decade",                "Decade" },
            { "source_export",         "Source Export" },
            { "label_alignment",       "Label Alignment" },
            { "is_covid_year",         "Is COVID Year" },
            { "reporting_entities",    "Reporting Entities" },
            { "all_crimes_comparable", "All Crimes Comparable" },
            { "coverage_note",         "Coverage Note" }
        }
    )
in
    Renamed
