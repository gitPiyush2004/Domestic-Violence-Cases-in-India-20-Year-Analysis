// ---------------------------------------------------------------------------
// FactCrimes
// Grain: one row per state x year x crime type.
// Source: data/processed/fact_crimes_long.csv (built by etl/01_clean_and_wrangle.py)
// ---------------------------------------------------------------------------
// Design note - why this reads processed/ and not raw/:
//
// The 2020-21 label-misalignment repair (see README) is deterministic but
// non-trivial: it re-attaches NCRB's 2020 entity ordering to a label column
// generated from the pre-2019 36-entity list. That logic is the ETL's job and
// lives in exactly one place. Re-implementing it in M would create a second
// copy of the same business rule in a second language, and the two would drift
// the first time either is edited. The BI layer therefore consumes the repaired
// star schema and restricts itself to shaping, typing and filtering.
// ---------------------------------------------------------------------------

let
    Source = Csv.Document(
        File.Contents( RepoRoot & "\data\processed\fact_crimes_long.csv" ),
        [ Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv ]
    ),

    Promoted = Table.PromoteHeaders( Source, [ PromoteAllScalars = true ] ),

    // Keep only the three foreign keys, the measure, and the quality flags.
    // region / population / literacy also arrive on this file, but they are
    // state attributes - carrying them on the fact table would denormalise the
    // model and let a careless visual average a population across 21 years.
    Trimmed = Table.SelectColumns(
        Promoted,
        { "state_clean", "year", "crime_code", "cases",
          "data_quality_flag", "include_in_analysis" }
    ),

    Typed = Table.TransformColumnTypes(
        Trimmed,
        {
            { "state_clean",         type text },
            { "year",                Int64.Type },
            { "crime_code",          type text },
            { "cases",               Int64.Type },
            { "data_quality_flag",   type text },
            { "include_in_analysis", type text }   // "True"/"False" from pandas
        }
    ),

    // The single filter point for the whole model.
    //
    // Three different things look like a zero in this data and conflating them
    // is how a dashboard becomes confidently wrong:
    //   entity_not_formed - Telangana before 2014, Ladakh before 2020
    //   source_gap        - Assault on Women reads 0 for every entity in 2011
    //   ok                - a genuine zero (Lakshadweep really does report none)
    // Only the third is a real observation. The ETL encodes that decision once
    // in include_in_analysis; SQL, DAX and M all defer to it rather than each
    // re-deriving the rule.
    Analysable = Table.SelectRows(
        Typed,
        each Text.Lower( [include_in_analysis] ) = "true"
    ),

    Final = Table.RemoveColumns( Analysable, { "include_in_analysis" } )
in
    Final
