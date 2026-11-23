using System.Data;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Channels;
using Dapper;
using EMR.Api.Data;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

/// <summary>
/// Where uploaded LOINC release files are kept (Terminology:StoragePath, default App_Data/terminology under the API).
/// Files arrive in chunks (so large releases pass the web server's request size limits) and are moved to jobs/ when
/// an import starts. The source file is kept for audit (its SHA-256 is stored with the job).
/// </summary>
public class TerminologyStorage(IConfiguration config, IWebHostEnvironment env)
{
    public const long MaxFileBytes = 1024L * 1024 * 1024;   // 1 GB
    private static readonly Regex IdRx = new("^[a-fA-F0-9]{32}$", RegexOptions.Compiled);

    public string Root
    {
        get
        {
            var p = config["Terminology:StoragePath"];
            var root = string.IsNullOrWhiteSpace(p) ? Path.Combine(env.ContentRootPath, "App_Data", "terminology") : p;
            Directory.CreateDirectory(Path.Combine(root, "uploads"));
            Directory.CreateDirectory(Path.Combine(root, "jobs"));
            return root;
        }
    }

    public static bool ValidUploadId(string? id) => id is not null && IdRx.IsMatch(id);
    public string UploadPath(string uploadId) => Path.Combine(Root, "uploads", uploadId + ".part");

    /// <summary>Appends chunk <paramref name="index"/> (0-based, in order) to the upload; returns the size so far.</summary>
    public async Task<long> AppendChunkAsync(string uploadId, int index, Stream body, CancellationToken ct)
    {
        var path = UploadPath(uploadId);
        var meta = path + ".next";
        if (index == 0)
        {
            await using (var fs0 = new FileStream(path, FileMode.Create, FileAccess.Write)) await body.CopyToAsync(fs0, ct);
        }
        else
        {
            var expected = File.Exists(meta) && int.TryParse(await File.ReadAllTextAsync(meta, ct), out var n) ? n : -1;
            if (expected != index) throw new InvalidOperationException($"Chunk {index} arrived out of order (expected {expected}). Upload the file again.");
            await using var fs = new FileStream(path, FileMode.Append, FileAccess.Write);
            await body.CopyToAsync(fs, ct);
        }
        await File.WriteAllTextAsync(meta, (index + 1).ToString(), ct);
        var size = new FileInfo(path).Length;
        if (size > MaxFileBytes) { File.Delete(path); File.Delete(meta); throw new InvalidOperationException("The file is larger than 1 GB."); }
        return size;
    }

    /// <summary>Moves a finished upload to jobs/ and returns (stored path, size, SHA-256).</summary>
    public async Task<(string Path, long Size, string Hash)> FinishUploadAsync(string uploadId, string fileName, CancellationToken ct)
    {
        var src = UploadPath(uploadId);
        if (!File.Exists(src)) throw new InvalidOperationException("The uploaded file was not found - upload it again.");
        var ext = Path.GetExtension(fileName).ToLowerInvariant() is ".zip" ? ".zip" : ".csv";
        var dest = Path.Combine(Root, "jobs", $"{DateTime.Now:yyyyMMddHHmmss}_{uploadId}{ext}");
        File.Move(src, dest, overwrite: true);
        try { File.Delete(src + ".next"); } catch { /* ignore */ }
        string hash;
        await using (var fs = File.OpenRead(dest)) hash = Convert.ToHexString(await SHA256.HashDataAsync(fs, ct)).ToLowerInvariant();
        return (dest, new FileInfo(dest).Length, hash);
    }
}

/// <summary>Import jobs waiting for the background worker.</summary>
public class TerminologyImportQueue
{
    private readonly Channel<int> _ch = Channel.CreateUnbounded<int>();
    public void Enqueue(int jobId) => _ch.Writer.TryWrite(jobId);
    public IAsyncEnumerable<int> ReadAllAsync(CancellationToken ct) => _ch.Reader.ReadAllAsync(ct);
}

/// <summary>
/// Runs LOINC imports one at a time: reads Loinc.csv (or the official release ZIP, LoincTable/Loinc.csv), checks every
/// row (code format and check digit, required fields, lengths), bulk-loads the valid rows into Terminology.StageLoinc,
/// records invalid rows in Terminology.ImportError, then lets usp_Import_Validate find duplicates and the difference
/// against the published repository. Nothing is published here - that is a separate, deliberate step.
/// </summary>
public class TerminologyImportWorker(TerminologyImportQueue queue, IServiceScopeFactory scopes, ILogger<TerminologyImportWorker> log) : BackgroundService
{
    private const int Batch = 5000;

    // the source columns this module keeps (Loinc.csv header names); the others are ignored
    private static readonly string[] Wanted =
    [
        "LOINC_NUM", "COMPONENT", "PROPERTY", "TIME_ASPCT", "SYSTEM", "SCALE_TYP", "METHOD_TYP", "CLASS", "CLASSTYPE", "STATUS",
        "LONG_COMMON_NAME", "SHORTNAME", "ORDER_OBS", "EXAMPLE_UNITS", "EXAMPLE_UCUM_UNITS", "VERSIONLASTCHANGED"
    ];

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // jobs left Queued / Running by a restart are picked up again (their staging is rebuilt from the file)
        try
        {
            using var scope = scopes.CreateScope();
            using var con = scope.ServiceProvider.GetRequiredService<IDbConnectionFactory>().CreateConnection();
            foreach (var id in await con.QueryAsync<int>("SELECT ImportJobId FROM Terminology.ImportJob WHERE Status IN ('Queued','Running') ORDER BY ImportJobId"))
                queue.Enqueue(id);
        }
        catch (Exception ex) { log.LogWarning(ex, "Terminology: could not re-queue pending imports"); }

        await foreach (var jobId in queue.ReadAllAsync(stoppingToken))
        {
            try { await RunAsync(jobId, stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                log.LogError(ex, "Terminology import {JobId} failed", jobId);
                try { await SetStatusAsync(jobId, "Failed", "The import stopped with an error: " + ex.Message); } catch { /* ignore */ }
            }
        }
    }

    private async Task SetStatusAsync(int jobId, string status, string? message = null, int? read = null, int? staged = null, int? errors = null, string? entry = null)
    {
        using var scope = scopes.CreateScope();
        using var con = scope.ServiceProvider.GetRequiredService<IDbConnectionFactory>().CreateConnection();
        await con.ExecuteAsync("Terminology.usp_Import_SetStatus", new
        {
            ImportJobId = jobId, Status = status, Message = message, RowsRead = read, RowsStaged = staged, RowsError = errors, EntryName = entry
        }, commandType: CommandType.StoredProcedure);
    }

    private async Task RunAsync(int jobId, CancellationToken ct)
    {
        using var scope = scopes.CreateScope();
        var factory = scope.ServiceProvider.GetRequiredService<IDbConnectionFactory>();
        string? stored, sourceName, status;
        using (var con = factory.CreateConnection())
        {
            var j = await con.QuerySingleOrDefaultAsync<(string? StoredFile, string? SourceFileName, string Status)>(
                "SELECT StoredFile, SourceFileName, Status FROM Terminology.ImportJob WHERE ImportJobId = @jobId", new { jobId });
            (stored, sourceName, status) = j;
            if (status is not ("Queued" or "Running")) return;
            // a restarted job: start clean
            await con.ExecuteAsync("DELETE FROM Terminology.StageLoinc WHERE ImportJobId = @jobId; DELETE FROM Terminology.ImportError WHERE ImportJobId = @jobId;", new { jobId });
        }
        await SetStatusAsync(jobId, "Running", "Reading the file…", 0, 0, 0);
        if (stored is null || !File.Exists(stored)) { await CriticalAsync(factory, jobId, sourceName, "The uploaded file is missing on the server."); return; }

        ZipArchive? zip = null;
        Stream? stream = null;
        string entryName = sourceName ?? Path.GetFileName(stored);
        try
        {
            if (stored.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            {
                zip = ZipFile.OpenRead(stored);
                var entry = zip.Entries.FirstOrDefault(e => e.FullName.Replace('\\', '/').EndsWith("LoincTable/Loinc.csv", StringComparison.OrdinalIgnoreCase))
                            ?? zip.Entries.FirstOrDefault(e => e.Name.Equals("Loinc.csv", StringComparison.OrdinalIgnoreCase));
                if (entry is null) { await CriticalAsync(factory, jobId, entryName, "The ZIP does not contain LoincTable/Loinc.csv - upload the official LOINC release ZIP or Loinc.csv."); return; }
                entryName = entry.FullName;
                stream = entry.Open();
            }
            else stream = File.OpenRead(stored);

            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 1 << 16);
            var header = CsvReader.ReadRecord(reader);
            if (header is null) { await CriticalAsync(factory, jobId, entryName, "The file is empty."); return; }
            var idx = header.Select((h, i) => (Name: h.Trim().ToUpperInvariant(), i)).GroupBy(x => x.Name).ToDictionary(g => g.Key, g => g.First().i);
            var missing = new[] { "LOINC_NUM", "LONG_COMMON_NAME", "COMPONENT" }.Where(c => !idx.ContainsKey(c)).ToList();
            if (missing.Count > 0)
            {
                await CriticalAsync(factory, jobId, entryName, $"Not a LOINC table file: column(s) {string.Join(", ", missing)} missing in the header. Upload Loinc.csv (LoincTable) of the official release.");
                return;
            }
            var unknown = Wanted.Where(w => !idx.ContainsKey(w)).ToList();

            var stage = NewStageTable();
            var errors = NewErrorTable();
            if (unknown.Count > 0)
                AddError(errors, jobId, entryName, 1, null, "WARNING", $"Column(s) not in this file, left empty: {string.Join(", ", unknown)}.");

            int rowNo = 1, read = 0, staged = 0, errCount = 0;
            string? Get(string[] rec, string col) => idx.TryGetValue(col, out var i) && i < rec.Length ? NullIfEmpty(rec[i]) : null;

            using var bulkCon = (SqlConnection)factory.CreateConnection();
            await bulkCon.OpenAsync(ct);

            string[]? rec;
            while ((rec = CsvReader.ReadRecord(reader)) is not null)
            {
                ct.ThrowIfCancellationRequested();
                rowNo++;
                if (rec.Length == 1 && string.IsNullOrWhiteSpace(rec[0])) continue;   // blank line
                read++;
                var code = Get(rec, "LOINC_NUM")?.Trim();
                var name = Get(rec, "LONG_COMMON_NAME");
                string? reason = null;
                if (string.IsNullOrEmpty(code)) reason = "LOINC_NUM is empty.";
                else if (!Regex.IsMatch(code, @"^\d{1,7}-\d$")) reason = $"Malformed LOINC code \"{Trunc(code, 30)}\".";
                else if (!CheckDigitOk(code)) reason = $"Check digit of {code} is wrong.";
                else if (string.IsNullOrWhiteSpace(name) && string.IsNullOrWhiteSpace(Get(rec, "COMPONENT"))) reason = "Both LONG_COMMON_NAME and COMPONENT are empty.";
                else
                {
                    var tooLong = new (string Col, int Max)[] { ("LONG_COMMON_NAME", 500), ("SHORTNAME", 255), ("COMPONENT", 500), ("PROPERTY", 100), ("TIME_ASPCT", 100),
                        ("SYSTEM", 255), ("SCALE_TYP", 100), ("METHOD_TYP", 255), ("CLASS", 100), ("CLASSTYPE", 10), ("STATUS", 30), ("ORDER_OBS", 30),
                        ("EXAMPLE_UNITS", 255), ("EXAMPLE_UCUM_UNITS", 255), ("VERSIONLASTCHANGED", 30) }
                        .FirstOrDefault(t => (Get(rec, t.Col)?.Length ?? 0) > t.Max);
                    if (tooLong.Col is not null) reason = $"{tooLong.Col} is longer than {tooLong.Max} characters.";
                }
                if (reason is not null)
                {
                    errCount++;
                    AddError(errors, jobId, entryName, rowNo, code is null ? null : Trunc(code, 40), "ERROR", reason);
                }
                else
                {
                    var r = stage.NewRow();
                    r["ImportJobId"] = jobId; r["RowNumber"] = rowNo; r["LoincCode"] = code!;
                    r["LongCommonName"] = (object?)name ?? DBNull.Value;
                    r["ShortName"] = Db(Get(rec, "SHORTNAME")); r["Component"] = Db(Get(rec, "COMPONENT")); r["Property"] = Db(Get(rec, "PROPERTY"));
                    r["TimeAspect"] = Db(Get(rec, "TIME_ASPCT")); r["SystemName"] = Db(Get(rec, "SYSTEM")); r["ScaleType"] = Db(Get(rec, "SCALE_TYP"));
                    r["MethodName"] = Db(Get(rec, "METHOD_TYP")); r["ClassName"] = Db(Get(rec, "CLASS")); r["ClassType"] = Db(Get(rec, "CLASSTYPE"));
                    r["Status"] = Db(Get(rec, "STATUS")?.ToUpperInvariant()); r["OrderObs"] = Db(Get(rec, "ORDER_OBS"));
                    r["ExampleUnits"] = Db(Get(rec, "EXAMPLE_UNITS")); r["ExampleUcumUnits"] = Db(Get(rec, "EXAMPLE_UCUM_UNITS"));
                    r["VersionLastChanged"] = Db(Get(rec, "VERSIONLASTCHANGED"));
                    r["RowHash"] = RowHash(r);
                    stage.Rows.Add(r);
                    staged++;
                }

                if (stage.Rows.Count >= Batch) { await BulkAsync(bulkCon, "Terminology.StageLoinc", stage, ct); stage.Clear(); }
                if (errors.Rows.Count >= Batch) { await BulkAsync(bulkCon, "Terminology.ImportError", errors, ct); errors.Clear(); }
                if (read % 20000 == 0) await SetStatusAsync(jobId, "Running", $"Read {read:N0} rows…", read, staged, errCount, entryName);
            }
            if (stage.Rows.Count > 0) await BulkAsync(bulkCon, "Terminology.StageLoinc", stage, ct);

            // many invalid rows means the wrong file - the import fails, the published release stays as it is
            if (read > 0 && errCount > read / 5)
                AddError(errors, jobId, entryName, null, null, "CRITICAL", $"{errCount:N0} of {read:N0} rows are invalid - this does not look like a valid LOINC table file.");
            if (errors.Rows.Count > 0) await BulkAsync(bulkCon, "Terminology.ImportError", errors, ct);

            await SetStatusAsync(jobId, "Running", $"Read {read:N0} rows; checking duplicates and comparing with the published release…", read, staged, errCount, entryName);
            await bulkCon.ExecuteAsync("Terminology.usp_Import_Validate", new { ImportJobId = jobId }, commandType: CommandType.StoredProcedure, commandTimeout: 1800);
            log.LogInformation("Terminology import {JobId}: {Read} rows read, {Staged} staged, {Errors} errors", jobId, read, staged, errCount);
        }
        finally
        {
            stream?.Dispose();
            zip?.Dispose();
        }
    }

    private async Task CriticalAsync(IDbConnectionFactory factory, int jobId, string? file, string reason)
    {
        using (var con = factory.CreateConnection())
            await con.ExecuteAsync("INSERT INTO Terminology.ImportError (ImportJobId, FileName, Severity, Reason) VALUES (@jobId, @file, 'CRITICAL', @reason)",
                new { jobId, file, reason });
        await SetStatusAsync(jobId, "Failed", reason);
    }

    private static async Task BulkAsync(SqlConnection con, string table, DataTable data, CancellationToken ct)
    {
        using var bulk = new SqlBulkCopy(con) { DestinationTableName = table, BatchSize = Batch, BulkCopyTimeout = 600 };
        foreach (DataColumn c in data.Columns) bulk.ColumnMappings.Add(c.ColumnName, c.ColumnName);
        await bulk.WriteToServerAsync(data, ct);
    }

    private static DataTable NewStageTable()
    {
        var t = new DataTable();
        t.Columns.Add("ImportJobId", typeof(int)); t.Columns.Add("RowNumber", typeof(int)); t.Columns.Add("LoincCode", typeof(string));
        foreach (var c in new[] { "LongCommonName", "ShortName", "Component", "Property", "TimeAspect", "SystemName", "ScaleType", "MethodName",
                                  "ClassName", "ClassType", "Status", "OrderObs", "ExampleUnits", "ExampleUcumUnits", "VersionLastChanged" })
            t.Columns.Add(c, typeof(string));
        t.Columns.Add("RowHash", typeof(byte[]));
        return t;
    }

    private static DataTable NewErrorTable()
    {
        var t = new DataTable();
        t.Columns.Add("ImportJobId", typeof(int)); t.Columns.Add("FileName", typeof(string)); t.Columns.Add("RowNumber", typeof(int));
        t.Columns.Add("LoincCode", typeof(string)); t.Columns.Add("Severity", typeof(string)); t.Columns.Add("Reason", typeof(string));
        return t;
    }

    private static void AddError(DataTable t, int jobId, string? file, int? row, string? code, string severity, string reason)
    {
        var r = t.NewRow();
        r["ImportJobId"] = jobId; r["FileName"] = (object?)Trunc(file, 260) ?? DBNull.Value; r["RowNumber"] = (object?)row ?? DBNull.Value;
        r["LoincCode"] = (object?)code ?? DBNull.Value; r["Severity"] = severity; r["Reason"] = Trunc(reason, 500)!;
        t.Rows.Add(r);
    }

    /// <summary>Hash of the fields compared between releases (a different hash = the concept changed).</summary>
    private static byte[] RowHash(DataRow r)
    {
        var s = string.Join('\u001f', new[] { "LongCommonName", "ShortName", "Component", "Property", "TimeAspect", "SystemName", "ScaleType",
            "MethodName", "ClassName", "ClassType", "Status", "OrderObs", "ExampleUnits", "ExampleUcumUnits" }.Select(c => r[c] as string ?? ""));
        return SHA256.HashData(Encoding.UTF8.GetBytes(s));
    }

    /// <summary>LOINC check digit (mod 10, as published by Regenstrief).</summary>
    public static bool CheckDigitOk(string code)
    {
        var dash = code.IndexOf('-');
        if (dash <= 0) return false;
        var digits = code[..dash];
        var check = code[(dash + 1)..];
        // double every other digit starting from the rightmost, sum all digits, check = (10 - sum % 10) % 10
        var sum = 0;
        var dbl = true;
        for (var i = digits.Length - 1; i >= 0; i--)
        {
            var d = digits[i] - '0';
            if (dbl) { d *= 2; if (d > 9) d = d / 10 + d % 10; }
            sum += d;
            dbl = !dbl;
        }
        return ((10 - sum % 10) % 10).ToString() == check;
    }

    private static object Db(string? v) => (object?)v ?? DBNull.Value;
    private static string? NullIfEmpty(string? v) => string.IsNullOrWhiteSpace(v) ? null : v.Trim();
    private static string? Trunc(string? v, int max) => v is null ? null : v.Length <= max ? v : v[..max];
}

/// <summary>Minimal RFC 4180 CSV reader (quoted fields, doubled quotes, line breaks inside quotes) - streams a record at a time.</summary>
public static class CsvReader
{
    public static string[]? ReadRecord(TextReader r)
    {
        var fields = new List<string>();
        var sb = new StringBuilder();
        var inQuotes = false;
        var any = false;
        while (true)
        {
            var ch = r.Read();
            if (ch == -1)
            {
                if (!any && sb.Length == 0 && fields.Count == 0) return null;
                fields.Add(sb.ToString());
                return fields.ToArray();
            }
            any = true;
            var c = (char)ch;
            if (inQuotes)
            {
                if (c == '"')
                {
                    if (r.Peek() == '"') { r.Read(); sb.Append('"'); }
                    else inQuotes = false;
                }
                else sb.Append(c);
            }
            else if (c == '"') inQuotes = true;
            else if (c == ',') { fields.Add(sb.ToString()); sb.Clear(); }
            else if (c == '\r') { if (r.Peek() == '\n') r.Read(); fields.Add(sb.ToString()); return fields.ToArray(); }
            else if (c == '\n') { fields.Add(sb.ToString()); return fields.ToArray(); }
            else sb.Append(c);
        }
    }
}
