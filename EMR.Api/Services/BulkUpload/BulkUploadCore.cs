using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using EMR.Api.Models;

namespace EMR.Api.Services.BulkUpload;

public enum BulkColumnKind { Text, Integer, Decimal, Date }

/// <summary>A column of the upload sheet.</summary>
public sealed class BulkColumn
{
    public required string Header { get; init; }
    public bool Required { get; init; }
    public BulkColumnKind Kind { get; init; } = BulkColumnKind.Text;
    /// <summary>Dropdown source: name of a reference sheet (its first column holds the values).</summary>
    public string? RefSheet { get; init; }
    /// <summary>Dropdown source: fixed values.</summary>
    public string[]? Options { get; init; }
    public string Note { get; init; } = string.Empty;
    public double Width { get; init; } = 20;
    /// <summary>Informational column: exported for reference, ignored on upload.</summary>
    public bool ReadOnly { get; init; }
    /// <summary>Nullable field: "(None)" clears the stored value (a blank cell keeps it).</summary>
    public bool AllowNone { get; init; }
    /// <summary>Excel cell validation bounds for numeric columns (the upload re-checks them).</summary>
    public decimal Min { get; init; }
    public decimal? Max { get; init; }
}

/// <summary>A dependent master shipped with the template. Column 1 is the dropdown value.</summary>
public sealed class BulkRefSheet
{
    public required string Name { get; init; }
    public required string[] Headers { get; init; }
    public List<object?[]> Rows { get; init; } = [];
}

public sealed class BulkTemplate
{
    public required string SheetName { get; init; }
    public List<BulkColumn> Columns { get; init; } = [];
    public List<object?[]> DataRows { get; init; } = [];
    public List<BulkRefSheet> RefSheets { get; init; } = [];
    public List<string> Notes { get; init; } = [];
}

public sealed class BulkContext
{
    public int CompanyId { get; init; } = 1;
    public int? UserId { get; init; }
    public int? BranchId { get; init; }
    public bool IsHO { get; init; } = true;
    public bool DryRun { get; init; }
}

/// <summary>One non-empty row read from the upload sheet (values are string, double, DateTime or bool).</summary>
public sealed class BulkRow
{
    public int RowNo { get; init; }
    public Dictionary<string, object?> Cells { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>Columns holding "(None)" although they cannot be cleared.</summary>
    public List<string> NoneNotAllowed { get; init; } = [];
}

public interface ILabBulkUploadHandler
{
    string Module { get; }
    string Title { get; }
    Task<BulkTemplate> BuildTemplateAsync(BulkContext ctx, bool withData);
    Task ImportAsync(IReadOnlyList<BulkRow> rows, BulkContext ctx, LabBulkUploadResult result);
}

public static class BulkValues
{
    public const string Active = "Active";
    public const string Inactive = "Inactive";
    public const string Yes = "Yes";
    public const string No = "No";
    /// <summary>Entered in a nullable column to clear its value on update.</summary>
    public const string None = "(None)";
    public static readonly string[] StatusOptions = [Active, Inactive];
    public static readonly string[] YesNoOptions = [Yes, No];

    public static string Pick(string name, string? code) => string.IsNullOrWhiteSpace(code) ? name : $"{name} [{code}]";
    public static string Status(bool active) => active ? Active : Inactive;
    public static string YesNo(bool value) => value ? Yes : No;

    private static readonly Regex CodeInBrackets = new(@"\[([^\[\]]+)\]\s*$", RegexOptions.Compiled);

    /// <summary>Returns the code inside a trailing "[CODE]", or null.</summary>
    public static string? ExtractCode(string raw)
    {
        var m = CodeInBrackets.Match(raw);
        return m.Success ? m.Groups[1].Value.Trim() : null;
    }

    private static readonly JsonSerializerOptions CompareOptions = new() { Converters = { new NormalizedDecimalConverter() } };

    /// <summary>Value comparison of two requests (decimals compared by value, so 100 equals 100.00).</summary>
    public static bool SameJson<T>(T a, T b) => JsonSerializer.Serialize(a, CompareOptions) == JsonSerializer.Serialize(b, CompareOptions);

    private sealed class NormalizedDecimalConverter : System.Text.Json.Serialization.JsonConverter<decimal>
    {
        public override decimal Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => reader.GetDecimal();
        public override void Write(Utf8JsonWriter writer, decimal value, JsonSerializerOptions options) =>
            writer.WriteRawValue(value.ToString("0.############################", CultureInfo.InvariantCulture));
    }
}

/// <summary>Resolves a dropdown value ("Name [CODE]"), a bare code or a unique name to a master record.</summary>
public sealed class BulkLookup<T> where T : class
{
    private readonly Dictionary<string, T> _byCode = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, List<T>> _byName = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<int, T> _byId = [];
    private readonly Func<T, string> _code;
    private readonly Func<T, string> _name;

    public IReadOnlyList<T> Items { get; }

    public BulkLookup(IEnumerable<T> items, Func<T, int> id, Func<T, string> code, Func<T, string> name)
    {
        Items = items.ToList();
        _code = code;
        _name = name;
        foreach (var item in Items)
        {
            _byId.TryAdd(id(item), item);
            var c = code(item)?.Trim();
            if (!string.IsNullOrEmpty(c)) _byCode.TryAdd(c, item);
            var n = name(item)?.Trim() ?? string.Empty;
            if (!_byName.TryGetValue(n, out var list)) _byName[n] = list = [];
            list.Add(item);
        }
    }

    public string Pick(T item) => BulkValues.Pick(_name(item), _code(item));

    public T? ById(int? id) => id.HasValue && _byId.TryGetValue(id.Value, out var v) ? v : null;

    public T? Resolve(string raw, out string? error)
    {
        error = null;
        var code = BulkValues.ExtractCode(raw);
        if (code != null && _byCode.TryGetValue(code, out var byBracket)) return byBracket;
        if (_byCode.TryGetValue(raw, out var byCode)) return byCode;
        if (_byName.TryGetValue(raw, out var byName))
        {
            if (byName.Count == 1) return byName[0];
            error = $"'{raw}' matches {byName.Count} records; pick the value from the dropdown so the code is included.";
            return null;
        }
        return null;
    }
}

/// <summary>Typed, error-collecting access to one upload row.</summary>
public sealed class RowReader(BulkRow row)
{
    private static readonly string[] DateFormats =
        ["dd-MM-yyyy", "d-M-yyyy", "dd/MM/yyyy", "d/M/yyyy", "yyyy-MM-dd", "dd-MMM-yyyy", "d-MMM-yyyy", "dd MMM yyyy", "dd.MM.yyyy"];

    public int RowNo => row.RowNo;
    public string RecordKey { get; set; } = string.Empty;
    public List<LabBulkUploadRowError> Errors { get; } = row.NoneNotAllowed.Select(col => new LabBulkUploadRowError
    {
        RowNo = row.RowNo, Field = col, Rule = LabBulkUploadRules.InvalidValue,
        Reason = $"{col} cannot be cleared with {BulkValues.None}. Leave it blank to keep the current value, or enter a value."
    }).ToList();
    public bool HasErrors => Errors.Count > 0;

    public void Fail(string field, string rule, string reason) =>
        Errors.Add(new LabBulkUploadRowError { RowNo = row.RowNo, Field = field, Rule = rule, Reason = reason });

    private object? Raw(string col) => row.Cells.TryGetValue(col, out var v) ? v : null;

    /// <summary>The cell holds "(None)": the value must be cleared.</summary>
    public bool IsNone(string col) =>
        Raw(col) is string s && string.Equals(s.Trim(), BulkValues.None, StringComparison.OrdinalIgnoreCase);

    /// <summary>No value given. "(None)" also counts: typed getters return null for it and the handler clears via IsNone.</summary>
    public bool IsBlank(string col) => Raw(col) switch
    {
        null => true,
        string s => string.IsNullOrWhiteSpace(s) || IsNone(col),
        _ => false
    };

    private bool CheckRequired(string col, bool required)
    {
        if (!IsBlank(col)) return true;
        if (required && !row.NoneNotAllowed.Contains(col)) // "(None)" in such a column is already reported
            Fail(col, LabBulkUploadRules.Required, $"{col} is required.");
        return false;
    }

    public string? Text(string col, bool required = false, int maxLength = 0)
    {
        if (!CheckRequired(col, required)) return null;
        var text = Raw(col) switch
        {
            double d => d.ToString("0.##########", CultureInfo.InvariantCulture),
            DateTime dt => dt.ToString("dd-MM-yyyy", CultureInfo.InvariantCulture),
            bool b => b ? BulkValues.Yes : BulkValues.No,
            var v => Convert.ToString(v, CultureInfo.InvariantCulture)?.Trim()
        };
        if (maxLength > 0 && text != null && text.Length > maxLength)
        {
            Fail(col, LabBulkUploadRules.InvalidValue, $"{col} must not exceed {maxLength} characters (found {text.Length}).");
            return null;
        }
        return text;
    }

    public decimal? Decimal(string col, bool required = false, decimal min = 0, decimal? max = null)
    {
        if (!CheckRequired(col, required)) return null;
        decimal value;
        switch (Raw(col))
        {
            case double d: value = (decimal)d; break;
            case string s when decimal.TryParse(s.Replace(",", ""), NumberStyles.Number, CultureInfo.InvariantCulture, out var p): value = p; break;
            default:
                Fail(col, LabBulkUploadRules.InvalidValue, $"{col} must be a number (found '{Text(col)}').");
                return null;
        }
        if (value < min || (max.HasValue && value > max.Value))
        {
            Fail(col, LabBulkUploadRules.InvalidValue, max.HasValue
                ? $"{col} must be between {min} and {max} (found {value})."
                : $"{col} must be {min} or more (found {value}).");
            return null;
        }
        return value;
    }

    public int? Int(string col, bool required = false, int min = 0, int? max = null)
    {
        var d = Decimal(col, required, min, max);
        if (d == null) return null;
        if (d.Value != Math.Truncate(d.Value))
        {
            Fail(col, LabBulkUploadRules.InvalidValue, $"{col} must be a whole number (found {d}).");
            return null;
        }
        return (int)d.Value;
    }

    public DateTime? Date(string col, bool required = false)
    {
        if (!CheckRequired(col, required)) return null;
        switch (Raw(col))
        {
            case DateTime dt: return dt.Date;
            case double d when d > 0 && d < 2958466: return DateTime.FromOADate(d).Date;
            case string s when DateTime.TryParseExact(s.Trim(), DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var p): return p.Date;
        }
        Fail(col, LabBulkUploadRules.InvalidValue, $"{col} must be a date in dd-MM-yyyy format (found '{Text(col)}').");
        return null;
    }

    public bool? YesNo(string col, bool required = false)
    {
        if (!CheckRequired(col, required)) return null;
        switch (Raw(col))
        {
            case bool b: return b;
            case double d when d is 0 or 1: return d == 1;
        }
        switch (Text(col)?.ToLowerInvariant())
        {
            case "yes" or "y" or "true" or "1": return true;
            case "no" or "n" or "false" or "0": return false;
        }
        Fail(col, LabBulkUploadRules.InvalidValue, $"{col} must be Yes or No (found '{Text(col)}').");
        return null;
    }

    /// <summary>Active / Inactive → true / false.</summary>
    public bool? Status(string col)
    {
        var v = Option(col, BulkValues.StatusOptions);
        return v == null ? null : v == BulkValues.Active;
    }

    /// <summary>Returns the canonical option (case-insensitive match), or null.</summary>
    public string? Option(string col, string[] options, bool required = false)
    {
        var text = Text(col, required);
        if (text == null) return null;
        var match = options.FirstOrDefault(o => string.Equals(o, text, StringComparison.OrdinalIgnoreCase));
        if (match == null)
            Fail(col, LabBulkUploadRules.InvalidValue, $"{col} '{text}' is not allowed. Allowed: {string.Join(", ", options)}.");
        return match;
    }

    /// <param name="current">Code / name of the record's current link. A cell still holding it returns null
    /// (= keep current), so exported rows re-upload even when that master has since been deactivated.</param>
    public T? Ref<T>(string col, BulkLookup<T> lookup, bool required = false, string? master = null, string? current = null) where T : class
    {
        var text = Text(col, required);
        if (text == null) return null;
        var code = BulkValues.ExtractCode(text);
        if (!string.IsNullOrWhiteSpace(current)
            && (string.Equals(current, text, StringComparison.OrdinalIgnoreCase) || string.Equals(current, code, StringComparison.OrdinalIgnoreCase)))
            return null;
        var item = lookup.Resolve(text, out var error);
        if (item == null)
            Fail(col, LabBulkUploadRules.InvalidRef, error ?? $"{master ?? col} '{text}' does not exist or is inactive. Pick a value from the dropdown / reference sheet.");
        return item;
    }
}

public static class BulkResultExtensions
{
    public static void AddFailure(this LabBulkUploadResult result, RowReader r)
    {
        foreach (var e in r.Errors) e.RecordKey = r.RecordKey;
        result.Errors.AddRange(r.Errors);
        result.Failed++;
    }

    /// <summary>Runs the save (unless dry run) and books the row as inserted / updated, or failed with the database message.</summary>
    public static async Task SaveRowAsync(this LabBulkUploadResult result, RowReader r, BulkContext ctx, bool isInsert, Func<Task> save)
    {
        if (!ctx.DryRun)
        {
            try
            {
                await save();
            }
            catch (Exception ex)
            {
                r.Fail(string.Empty, LabBulkUploadRules.SaveFailed, ex.Message);
                result.AddFailure(r);
                return;
            }
        }
        if (isInsert) result.Inserted++; else result.Updated++;
    }
}
