using ClosedXML.Excel;

namespace EMR.Api.Services.BulkUpload;

/// <summary>Builds upload templates (data sheet + dropdowns + dependent master sheets) and reads uploads back.</summary>
public static class BulkExcel
{
    public const int MaxRows = 10000;
    private const string InstructionsSheet = "Instructions";
    private const string ListsSheet = "Lists";
    private static readonly XLColor HeaderRequired = XLColor.FromHtml("#1F4E79");
    private static readonly XLColor HeaderOptional = XLColor.FromHtml("#5B7FA6");
    private static readonly XLColor HeaderReadOnly = XLColor.FromHtml("#8C8C8C");
    private static readonly XLColor RefHeader = XLColor.FromHtml("#375623");

    public static byte[] Build(string title, BulkTemplate t)
    {
        using var wb = new XLWorkbook();

        var ins = wb.Worksheets.Add(InstructionsSheet);
        var data = wb.Worksheets.Add(t.SheetName);
        foreach (var rs in t.RefSheets) WriteRefSheet(wb.Worksheets.Add(rs.Name), rs);
        var lists = wb.Worksheets.Add(ListsSheet);
        lists.Visibility = XLWorksheetVisibility.Hidden;

        WriteInstructions(ins, title, t);

        // Header row
        for (var i = 0; i < t.Columns.Count; i++)
        {
            var col = t.Columns[i];
            var cell = data.Cell(1, i + 1);
            cell.Value = col.Required ? col.Header + " *" : col.Header;
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = col.ReadOnly ? HeaderReadOnly : col.Required ? HeaderRequired : HeaderOptional;
            cell.Style.Alignment.WrapText = true;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            var note = col.AllowNone ? $"{col.Note} Enter {BulkValues.None} to clear the value.".Trim() : col.Note;
            if (!string.IsNullOrWhiteSpace(note)) cell.CreateComment().AddText(note);
            data.Column(i + 1).Width = col.Width;
        }
        data.Row(1).Height = 32;
        data.SheetView.FreezeRows(1);

        // Existing data
        for (var r = 0; r < t.DataRows.Count; r++)
            for (var c = 0; c < t.Columns.Count && c < t.DataRows[r].Length; c++)
                SetValue(data.Cell(r + 2, c + 1), t.DataRows[r][c]);

        // Formats and dropdowns
        var lastRow = Math.Max(t.DataRows.Count + 1000, 2000);
        var listCol = 0;
        for (var i = 0; i < t.Columns.Count; i++)
        {
            var col = t.Columns[i];
            var range = data.Range(2, i + 1, lastRow, i + 1);

            if (col.ReadOnly)
            {
                range.Style.Font.FontColor = XLColor.Gray;
                continue;
            }

            var orNone = col.AllowNone ? $" or {BulkValues.None} to clear" : "";
            var firstCell = range.FirstCell().Address.ToStringRelative();
            switch (col.Kind)
            {
                case BulkColumnKind.Date:
                    range.Style.DateFormat.Format = "dd-MM-yyyy";
                    if (col.AllowNone)
                        Validate(range, col, dv => dv.Custom(NumberOrNone(firstCell, "DATE(1900,1,1)", integer: false)), $"Enter a date (dd-MM-yyyy){orNone}.");
                    else
                        Validate(range, col, dv => dv.Date.EqualOrGreaterThan(new DateTime(1900, 1, 1)), "Enter a date (dd-MM-yyyy).");
                    continue;
                case BulkColumnKind.Integer:
                case BulkColumnKind.Decimal:
                    var integer = col.Kind == BulkColumnKind.Integer;
                    var bounds = col.Max.HasValue ? $"between {col.Min:0.##} and {col.Max:0.##}" : $"{col.Min:0.##} or more";
                    var message = $"Enter {(integer ? "a whole number" : "a number")} {bounds}{orNone}.";
                    Validate(range, col, dv => dv.Custom(NumberRule(firstCell, col, integer)), message);
                    continue;
            }

            range.Style.NumberFormat.Format = "@"; // keep codes / mobile numbers as text

            if (col.RefSheet != null)
            {
                var rs = t.RefSheets.First(s => s.Name == col.RefSheet);
                if (col.AllowNone)
                {
                    // Own list: "(None)" followed by the reference values.
                    var values = new List<string> { BulkValues.None };
                    values.AddRange(rs.Rows.Select(r => r[0]?.ToString() ?? string.Empty));
                    var src = WriteList(lists, ++listCol, col.Header, values);
                    Validate(range, col, dv => dv.List(src, true), $"Pick a value from the dropdown (see sheet {rs.Name}){orNone}.");
                }
                else if (rs.Rows.Count > 0)
                {
                    var src = wb.Worksheet(rs.Name).Range(2, 1, rs.Rows.Count + 1, 1);
                    Validate(range, col, dv => dv.List(src, true), $"Pick a value from the dropdown (see sheet {rs.Name}).");
                }
            }
            else if (col.Options is { Length: > 0 })
            {
                var values = col.AllowNone ? new[] { BulkValues.None }.Concat(col.Options).ToList() : col.Options.ToList();
                var src = WriteList(lists, ++listCol, col.Header, values);
                Validate(range, col, dv => dv.List(src, true), $"Allowed values: {string.Join(", ", values)}.");
            }
        }

        data.SetTabActive();
        ins.TabActive = false;

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    private static IXLRange WriteList(IXLWorksheet lists, int column, string header, IReadOnlyList<string> values)
    {
        lists.Cell(1, column).Value = header;
        for (var i = 0; i < values.Count; i++) lists.Cell(i + 2, column).Value = values[i];
        return lists.Range(2, column, values.Count + 1, column);
    }

    /// <summary>Custom rule: a number (optionally whole) not below <paramref name="min"/>, or the text "(None)".</summary>
    private static string NumberOrNone(string cell, string min, bool integer) =>
        $"OR({cell}=\"{BulkValues.None}\",AND(ISNUMBER({cell}),{cell}>={min}{(integer ? $",INT({cell})={cell}" : "")}))";

    /// <summary>Custom rule: a number within the column's Min/Max (whole for Integer columns), plus "(None)" when allowed.</summary>
    private static string NumberRule(string cell, BulkColumn col, bool integer)
    {
        var parts = new List<string> { $"ISNUMBER({cell})", $"{cell}>={col.Min.ToString(System.Globalization.CultureInfo.InvariantCulture)}" };
        if (col.Max.HasValue) parts.Add($"{cell}<={col.Max.Value.ToString(System.Globalization.CultureInfo.InvariantCulture)}");
        if (integer) parts.Add($"INT({cell})={cell}");
        var rule = $"AND({string.Join(",", parts)})";
        return col.AllowNone ? $"OR({cell}=\"{BulkValues.None}\",{rule})" : rule;
    }

    private static void Validate(IXLRange range, BulkColumn col, Action<IXLDataValidation> rule, string message)
    {
        var dv = range.CreateDataValidation();
        rule(dv);
        dv.IgnoreBlanks = true;
        dv.ShowErrorMessage = true;
        dv.ErrorStyle = XLErrorStyle.Stop;
        dv.ErrorTitle = col.Header;
        dv.ErrorMessage = message;
    }

    private static void SetValue(IXLCell cell, object? value)
    {
        switch (value)
        {
            case null: break;
            case DateTime dt: cell.Value = dt; break;
            case int n: cell.Value = n; break;
            case decimal d: cell.Value = d; break;
            case double d: cell.Value = d; break;
            case bool b: cell.Value = b ? BulkValues.Yes : BulkValues.No; break;
            default: cell.Value = value.ToString(); break;
        }
    }

    private static void WriteRefSheet(IXLWorksheet ws, BulkRefSheet rs)
    {
        for (var c = 0; c < rs.Headers.Length; c++)
        {
            var cell = ws.Cell(1, c + 1);
            cell.Value = rs.Headers[c];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = RefHeader;
        }
        for (var r = 0; r < rs.Rows.Count; r++)
            for (var c = 0; c < rs.Headers.Length && c < rs.Rows[r].Length; c++)
                SetValue(ws.Cell(r + 2, c + 1), rs.Rows[r][c]);
        ws.SheetView.FreezeRows(1);
        ws.Columns(1, rs.Headers.Length).AdjustToContents(1, Math.Min(rs.Rows.Count + 1, 500), 10, 70);
        ws.Range(1, 1, Math.Max(rs.Rows.Count + 1, 2), rs.Headers.Length).SetAutoFilter();
        ws.Protect().AllowElement(XLSheetProtectionElements.AutoFilter | XLSheetProtectionElements.Sort | XLSheetProtectionElements.FormatColumns);
    }

    private static void WriteInstructions(IXLWorksheet ws, string title, BulkTemplate t)
    {
        ws.Cell(1, 1).Value = $"{title} – Bulk Upload Template";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(1, 1).Style.Font.FontSize = 14;
        ws.Cell(2, 1).Value = $"Generated on {DateTime.Now:dd-MM-yyyy HH:mm}. Fill the '{t.SheetName}' sheet and upload it from the {title} screen.";

        var row = 4;
        var general = new List<string>
        {
            $"Enter data in the '{t.SheetName}' sheet only. Do not rename the sheet or change the header row.",
            "Columns marked * are mandatory for new records. Dark blue = mandatory, light blue = optional, grey = information only (ignored on upload).",
            "Code column blank = a NEW record is created (the code is generated automatically). Code filled = that EXISTING record is updated.",
            "When updating, a blank cell keeps the current value.",
            $"To clear an optional value (e.g. remove the Method from an investigation), pick or type {BulkValues.None}. Columns that allow it are marked in the table below.",
            "Dependent masters (the green-header sheets) must already exist. Pick them from the dropdown; the value 'Name [CODE]' is matched by the code in brackets.",
            "Dates: dd-MM-yyyy. Yes/No and Active/Inactive columns use the dropdown.",
            "Valid rows are saved; invalid rows are skipped and listed with the reason. Use 'Validate only' to check a file without saving anything.",
            $"Maximum {MaxRows:N0} rows per file."
        };
        general.AddRange(t.Notes);
        ws.Cell(row++, 1).Value = "Rules";
        ws.Cell(row - 1, 1).Style.Font.Bold = true;
        foreach (var n in general) ws.Cell(row++, 1).Value = "• " + n;

        row++;
        string[] headers = ["Column", "Mandatory", "Allowed values / source", "Notes"];
        for (var c = 0; c < headers.Length; c++)
        {
            var cell = ws.Cell(row, c + 1);
            cell.Value = headers[c];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = HeaderRequired;
        }
        foreach (var col in t.Columns)
        {
            row++;
            ws.Cell(row, 1).Value = col.Header;
            ws.Cell(row, 2).Value = col.ReadOnly ? "Info only" : col.Required ? "Yes" : col.AllowNone ? $"No – {BulkValues.None} clears" : "No";
            ws.Cell(row, 3).Value = col.RefSheet != null ? $"Dropdown from sheet {col.RefSheet}"
                : col.Options != null ? string.Join(" / ", col.Options)
                : col.Kind switch
                {
                    BulkColumnKind.Date => "Date (dd-MM-yyyy)",
                    BulkColumnKind.Integer => "Whole number",
                    BulkColumnKind.Decimal => "Number",
                    _ => "Text"
                };
            ws.Cell(row, 4).Value = col.Note;
        }
        ws.Column(1).Width = 28;
        ws.Column(2).Width = 12;
        ws.Column(3).Width = 40;
        ws.Column(4).Width = 90;
    }

    /// <summary>Reads the data sheet. Returns an error message when the file does not match the template.</summary>
    public static (List<BulkRow> Rows, string? Error) Read(Stream stream, BulkTemplate t)
    {
        XLWorkbook wb;
        try
        {
            wb = new XLWorkbook(stream);
        }
        catch (Exception)
        {
            return ([], "The file could not be opened. Upload the .xlsx template downloaded from this screen.");
        }

        using (wb)
        {
            if (!wb.TryGetWorksheet(t.SheetName, out var ws))
                return ([], $"Sheet '{t.SheetName}' was not found. Upload the template downloaded from this screen without renaming its sheets.");

            var headerMap = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var cell in ws.Row(1).CellsUsed())
            {
                var h = cell.GetString().Trim().TrimEnd('*').Trim();
                if (h.Length > 0) headerMap.TryAdd(h, cell.Address.ColumnNumber);
            }

            var missing = t.Columns.Where(c => !c.ReadOnly && !headerMap.ContainsKey(c.Header)).Select(c => c.Header).ToList();
            if (missing.Count > 0)
                return ([], $"Header row is missing column(s): {string.Join(", ", missing)}. Download a fresh template.");

            var lastRow = ws.LastRowUsed(XLCellsUsedOptions.Contents)?.RowNumber() ?? 1;
            var rows = new List<BulkRow>();
            for (var r = 2; r <= lastRow; r++)
            {
                var row = new BulkRow { RowNo = r };
                var any = false;
                foreach (var col in t.Columns)
                {
                    if (!headerMap.TryGetValue(col.Header, out var c)) continue;
                    var value = CellValue(ws.Cell(r, c));
                    row.Cells[col.Header] = value;
                    if (!col.AllowNone && !col.ReadOnly && value is string text
                        && string.Equals(text, BulkValues.None, StringComparison.OrdinalIgnoreCase))
                        row.NoneNotAllowed.Add(col.Header);
                    if (value != null && !col.ReadOnly) any = true;
                }
                if (!any) continue;
                rows.Add(row);
                if (rows.Count > MaxRows)
                    return ([], $"The file has more than {MaxRows:N0} data rows. Split it into smaller files.");
            }

            return rows.Count == 0
                ? ([], $"No data rows found in sheet '{t.SheetName}'.")
                : (rows, null);
        }
    }

    private static object? CellValue(IXLCell cell)
    {
        var v = cell.Value;
        return v.Type switch
        {
            XLDataType.Blank => null,
            XLDataType.Number => v.GetNumber(),
            XLDataType.DateTime => v.GetDateTime(),
            XLDataType.Boolean => v.GetBoolean(),
            XLDataType.Text => string.IsNullOrWhiteSpace(v.GetText()) ? null : v.GetText().Trim(),
            _ => cell.GetFormattedString()
        };
    }
}
