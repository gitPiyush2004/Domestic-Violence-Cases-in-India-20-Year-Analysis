// ---------------------------------------------------------------------------
// Parameter: RepoRoot
// ---------------------------------------------------------------------------
// Every query resolves its file path from this one value, so moving or cloning
// the repository is a single-field edit in Power Query rather than a find-and-
// replace across five queries. Set it to the folder that contains data/ and sql/.
//
// In the Power Query Editor this is created as:
//   Home > Manage Parameters > New Parameter
//   Name: RepoRoot   Type: Text   Required: yes
// ---------------------------------------------------------------------------

"C:\Users\hp\Desktop\Domestic Violance Cases\repo"
  meta [ IsParameterQuery = true, Type = "Text", IsParameterQueryRequired = true ]
