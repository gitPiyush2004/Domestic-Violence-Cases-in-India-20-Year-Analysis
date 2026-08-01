Attribute VB_Name = "CleanCrimeData"
'==============================================================================
' CleanCrimeData - MS Excel cleaning macro for the NCRB crimes-against-women
'                  extract (CrimesOnWomenData.csv, 736 x 9).
'==============================================================================
' This is the Excel-side implementation of the same cleaning contract that
' etl/01_clean_and_wrangle.py implements in Python. It exists because the first
' pass at this data was done in Excel, and because the state-name defect is much
' easier to *see* in a worksheet than in a dataframe.
'
' What it does, in order:
'   1  Normalises entity labels  - trims, collapses whitespace, spaces out "&",
'                                  proper-cases, then applies an override map
'   2  Detects the rename split  - reports labels that differ only by casing or
'                                  "&" spacing and therefore split one entity's
'                                  series into two half-series
'   3  Unpivots wide to long     - 7 crime columns -> one CrimeCode / Cases pair
'   4  Flags the three zero kinds - entity_not_formed / source_gap / ok
'   5  Writes an audit sheet     - every decision, counted
'
' What it deliberately does NOT do: the 2020-21 label-misalignment repair. That
' correction depends on NCRB's published entity ordering and belongs in one
' place only (etl/02_validate_repair.py). Duplicating it here would create a
' second copy of the same business rule that drifts the first time either moves.
'
' Usage: open the raw CSV, Alt+F11, import this module, run CleanAndReshape.
'==============================================================================

Option Explicit

Private Const SRC_SHEET As String = "CrimesOnWomenData"
Private Const OUT_SHEET As String = "fact_long"
Private Const AUDIT_SHEET As String = "audit"

' The seven crime heads, in source column order.
Private Function CrimeCodes() As Variant
    CrimeCodes = Array("Rape", "K&A", "DD", "AoW", "AoM", "DV", "WT")
End Function


'------------------------------------------------------------------------------
' Entry point
'------------------------------------------------------------------------------
Public Sub CleanAndReshape()
    Dim wsSrc As Worksheet, wsOut As Worksheet, wsAudit As Worksheet
    Dim lastRow As Long, r As Long, c As Long, outRow As Long
    Dim rawLabel As String, cleanLabel As String
    Dim yr As Long, cases As Variant
    Dim codes As Variant
    Dim seen As Object, collisions As Object
    Dim t As Double

    t = Timer
    Application.ScreenUpdating = False
    Application.Calculation = xlCalculationManual

    On Error GoTo Fail

    Set wsSrc = ThisWorkbook.Worksheets(SRC_SHEET)
    Set seen = CreateObject("Scripting.Dictionary")
    Set collisions = CreateObject("Scripting.Dictionary")
    codes = CrimeCodes()

    lastRow = wsSrc.Cells(wsSrc.Rows.Count, 2).End(xlUp).Row

    Set wsOut = ResetSheet(OUT_SHEET)
    wsOut.Range("A1:F1").Value = _
        Array("state_clean", "state_raw", "year", "crime_code", "cases", "data_quality_flag")
    outRow = 2

    '--- pass 1: normalise labels and detect the rename split -----------------
    For r = 2 To lastRow
        rawLabel = CStr(wsSrc.Cells(r, 2).Value)
        cleanLabel = NormaliseState(rawLabel)

        If Len(cleanLabel) > 0 Then
            If Not seen.Exists(cleanLabel) Then
                seen.Add cleanLabel, rawLabel
            ElseIf seen(cleanLabel) <> rawLabel Then
                ' Same entity, two different raw spellings. This is the defect
                ' that silently splits a 21-year series into two half-series.
                If Not collisions.Exists(cleanLabel) Then
                    collisions.Add cleanLabel, seen(cleanLabel) & " | " & rawLabel
                End If
            End If
        End If
    Next r

    '--- pass 2: unpivot ------------------------------------------------------
    For r = 2 To lastRow
        rawLabel = CStr(wsSrc.Cells(r, 2).Value)
        cleanLabel = NormaliseState(rawLabel)
        yr = CLng(wsSrc.Cells(r, 3).Value)

        For c = 0 To UBound(codes)
            cases = wsSrc.Cells(r, 4 + c).Value
            If Not IsEmpty(cases) Then
                wsOut.Cells(outRow, 1).Value = cleanLabel
                wsOut.Cells(outRow, 2).Value = rawLabel
                wsOut.Cells(outRow, 3).Value = yr
                wsOut.Cells(outRow, 4).Value = codes(c)
                wsOut.Cells(outRow, 5).Value = CLng(cases)
                wsOut.Cells(outRow, 6).Value = _
                    QualityFlag(cleanLabel, yr, CStr(codes(c)), CLng(cases))
                outRow = outRow + 1
            End If
        Next c
    Next r

    '--- audit ----------------------------------------------------------------
    Set wsAudit = ResetSheet(AUDIT_SHEET)
    WriteAudit wsAudit, lastRow - 1, outRow - 2, seen.Count, collisions, Timer - t

    wsOut.Columns("A:F").AutoFit
    wsOut.Rows(1).Font.Bold = True
    wsOut.Activate
    wsOut.Range("A2").Select
    ActiveWindow.FreezePanes = True

Done:
    Application.Calculation = xlCalculationAutomatic
    Application.ScreenUpdating = True
    Exit Sub

Fail:
    MsgBox "CleanAndReshape failed on row " & r & ": " & Err.Description, vbCritical
    Resume Done
End Sub


'------------------------------------------------------------------------------
' Label normalisation.
'
' The source carries the same entity under several spellings because it was
' assembled from two NCRB export vintages: an ALL-CAPS block covering 2001-2010
' and a Title Case block covering 2011-2021. "D & N HAVELI" and "D&N Haveli" are
' one union territory; left alone they produce two states with 10 and 11 years
' each instead of one with 21.
'------------------------------------------------------------------------------
Private Function NormaliseState(ByVal s As String) As String
    Dim v As String

    v = Trim$(s)
    If Len(v) = 0 Then
        NormaliseState = ""
        Exit Function
    End If

    ' Give "&" consistent surrounding spaces, then collapse the doubles that
    ' creates where spaces already existed.
    v = Replace(v, "&", " & ")
    Do While InStr(v, "  ") > 0
        v = Replace(v, "  ", " ")
    Loop
    v = Trim$(v)

    ' Application.Proper is the same transform pandas' .str.title() applies, so
    ' the two pipelines agree on casing by construction.
    v = Application.WorksheetFunction.Proper(v)

    ' Overrides where proper-casing is wrong or the published name differs.
    Select Case v
        Case "Delhi Ut":            v = "Delhi UT"
        Case "A & N Islands":       v = "A & N Islands"
        Case "D & N Haveli":        v = "D & N Haveli"
        Case "Jammu & Kashmir":     v = "Jammu & Kashmir"
    End Select

    NormaliseState = v
End Function


'------------------------------------------------------------------------------
' The three kinds of zero. Conflating them is how a dashboard becomes
' confidently wrong, so they are separated at the point of reshape.
'------------------------------------------------------------------------------
Private Function QualityFlag(ByVal state As String, ByVal yr As Long, _
                             ByVal code As String, ByVal cases As Long) As String
    If cases > 0 Then
        QualityFlag = "ok"
        Exit Function
    End If

    ' Assault on Women reads zero for every entity in 2011 - a dropped column in
    ' the export, not a national collapse. 40,012 cases in 2010, 45,344 in 2012.
    If code = "AoW" And yr = 2011 Then
        QualityFlag = "source_gap"
        Exit Function
    End If

    ' Entities that did not exist yet.
    If state = "Telangana" And yr < 2014 Then
        QualityFlag = "entity_not_formed"
        Exit Function
    End If
    If state = "Ladakh" And yr < 2020 Then
        QualityFlag = "entity_not_formed"
        Exit Function
    End If

    ' A genuine zero. Lakshadweep really does report none in some years.
    QualityFlag = "ok"
End Function


'------------------------------------------------------------------------------
Private Sub WriteAudit(ws As Worksheet, ByVal srcRows As Long, ByVal outRows As Long, _
                       ByVal entityCount As Long, collisions As Object, ByVal secs As Double)
    Dim i As Long, k As Variant

    ws.Range("A1").Value = "Cleaning audit"
    ws.Range("A1").Font.Bold = True

    ws.Range("A3").Value = "Source rows"
    ws.Range("B3").Value = srcRows
    ws.Range("A4").Value = "Fact rows after unpivot"
    ws.Range("B4").Value = outRows
    ws.Range("A5").Value = "Expected (source x 7)"
    ws.Range("B5").Value = srcRows * 7
    ws.Range("A6").Value = "Distinct entities after normalisation"
    ws.Range("B6").Value = entityCount
    ws.Range("A7").Value = "Label collisions resolved"
    ws.Range("B7").Value = collisions.Count
    ws.Range("A8").Value = "Elapsed (s)"
    ws.Range("B8").Value = Round(secs, 2)

    ' The reconciliation that matters: unpivot must be lossless.
    ws.Range("A10").Value = "Row-count reconciliation"
    ws.Range("B10").Value = IIf(outRows = srcRows * 7, "PASS", "FAIL - investigate")
    ws.Range("B10").Font.Bold = True

    If collisions.Count > 0 Then
        ws.Range("A12").Value = "Entities recovered from split labels"
        ws.Range("A12").Font.Bold = True
        ws.Range("A13").Value = "clean label"
        ws.Range("B13").Value = "raw spellings merged"
        i = 14
        For Each k In collisions.Keys
            ws.Cells(i, 1).Value = k
            ws.Cells(i, 2).Value = collisions(k)
            i = i + 1
        Next k
    End If

    ws.Columns("A:B").AutoFit
End Sub


'------------------------------------------------------------------------------
Private Function ResetSheet(ByVal nm As String) As Worksheet
    Dim ws As Worksheet
    On Error Resume Next
    Set ws = ThisWorkbook.Worksheets(nm)
    On Error GoTo 0

    If ws Is Nothing Then
        Set ws = ThisWorkbook.Worksheets.Add( _
            After:=ThisWorkbook.Worksheets(ThisWorkbook.Worksheets.Count))
        ws.Name = nm
    Else
        ws.Cells.Clear
    End If

    Set ResetSheet = ws
End Function
