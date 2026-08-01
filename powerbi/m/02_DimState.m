// ---------------------------------------------------------------------------
// DimState
// Grain: one row per reporting entity (36: 28 states + 8 union territories).
// Source: data/processed/dim_state.csv
// ---------------------------------------------------------------------------
// The ETL pre-computes the per-state aggregates (totals, CAGR, ABC class, risk
// zone) so the SQL layer and the BI layer agree by construction. The dashboard
// still recomputes ABC and risk dynamically in DAX - see 04_abc_pareto.dax -
// because those must respond to slicers. The stored columns are the static
// reference the dynamic versions are validated against.
// ---------------------------------------------------------------------------

let
    Source = Csv.Document(
        File.Contents( RepoRoot & "\data\processed\dim_state.csv" ),
        [ Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv ]
    ),

    Promoted = Table.PromoteHeaders( Source, [ PromoteAllScalars = true ] ),

    Selected = Table.SelectColumns(
        Promoted,
        { "state_clean", "state_code", "entity_type", "region",
          "population_2011", "female_population_2011", "sex_ratio_2011",
          "literacy_rate_2011", "dv_total_cases", "dv_cagr_pct",
          "trend_direction", "risk_zone", "abc_class", "rank", "notes" }
    ),

    Typed = Table.TransformColumnTypes(
        Selected,
        {
            { "state_clean",            type text },
            { "state_code",             type text },
            { "entity_type",            type text },
            { "region",                 type text },
            { "population_2011",        Int64.Type },
            { "female_population_2011", Int64.Type },
            { "sex_ratio_2011",         Int64.Type },
            { "literacy_rate_2011",     type number },
            { "dv_total_cases",         Int64.Type },
            { "dv_cagr_pct",            type number },
            { "trend_direction",        type text },
            { "risk_zone",              type text },
            { "abc_class",              type text },
            { "rank",                   Int64.Type },
            { "notes",                  type text }
        }
    ),

    Renamed = Table.RenameColumns(
        Typed,
        {
            { "state_clean",            "State" },
            { "state_code",             "State Code" },
            { "entity_type",            "Entity Type" },
            { "region",                 "Region" },
            { "population_2011",        "Population 2011" },
            { "female_population_2011", "Female Population 2011" },
            { "sex_ratio_2011",         "Sex Ratio 2011" },
            { "literacy_rate_2011",     "Literacy Rate 2011" },
            { "dv_total_cases",         "DV Total Cases (static)" },
            { "dv_cagr_pct",            "DV CAGR % (static)" },
            { "trend_direction",        "Trend Direction" },
            { "risk_zone",              "Risk Zone (static)" },
            { "abc_class",              "ABC Class (static)" },
            { "rank",                   "DV Rank (static)" },
            { "notes",                  "Boundary Notes" }
        }
    ),

    // Sort order for the risk-zone slicer. Alphabetical would read
    // Critical / High / Low / Moderate, which is meaningless as a severity axis.
    WithRiskSort = Table.AddColumn(
        Renamed, "Risk Zone Sort",
        each if      [#"Risk Zone (static)"] = "Critical" then 1
             else if [#"Risk Zone (static)"] = "High"     then 2
             else if [#"Risk Zone (static)"] = "Moderate" then 3
             else if [#"Risk Zone (static)"] = "Low"      then 4
             else 9,
        Int64.Type
    )
in
    WithRiskSort
