using System.Collections.Concurrent;
using System.Data;
using Dapper;
using EMR.Api.Data;

namespace EMR.Api.Services.BillReader;

public interface IBillReaderService
{
    Task<BillReadResult> ReadAsync(int companyId, int branchId, byte[] file, string fileName, CancellationToken ct);
    Task<int> LearnAsync(int companyId, int? supplierId, string pairsJson);
}

/// <summary>
/// Reads a supplier's bill (SQLScripts/2367): text (BillTextSource) -> layout (BillParser, ML heading model) -> supplier by GSTIN
/// or name, items by learnt names / code / ML similarity (BillItemMatcher), GST from the Item Master when the bill does not show it.
/// The matcher of a company is cached and rebuilt after 10 minutes or when the users teach it new names.
/// </summary>
public sealed class BillReaderService(IDbConnectionFactory db, BillTextSource source, ILogger<BillReaderService> logger) : IBillReaderService
{
    private sealed record ItemRow(int ItemId, string ItemCode, string ItemName, string? Strength, string? PackSize, string? GenericName, string? ManufacturerName, string? Barcode, decimal GstPercent, int ConversionQty);
    private sealed record SupplierRow(int SupplierId, string SupplierName, string? Gstin, string? DrugLicenceNo, string? Phone);
    private sealed record AliasRow(int SupplierId, string BillText, int ItemId, int Hits);
    private sealed record Catalog(BillItemMatcher Matcher, Dictionary<int, ItemRow> Items, List<SupplierRow> Suppliers);

    private static readonly ConcurrentDictionary<int, Catalog> Cache = new();

    private async Task<Catalog> CatalogAsync(int companyId)
    {
        if (Cache.TryGetValue(companyId, out var c) && (DateTime.UtcNow - c.Matcher.Built).TotalMinutes < 10) return c;
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_Api_PhBill_Catalog", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        var items = (await m.ReadAsync<ItemRow>()).ToList();
        var sups = (await m.ReadAsync<SupplierRow>()).ToList();
        var aliases = (await m.ReadAsync<AliasRow>()).ToList();
        var matcher = new BillItemMatcher(items.Select(i => (i.ItemId, i.ItemCode, i.ItemName, i.Strength, i.PackSize, i.GenericName, i.Barcode)),
                                          aliases.OrderBy(a => a.Hits).Select(a => (a.SupplierId, a.BillText, a.ItemId)));
        c = new Catalog(matcher, items.ToDictionary(i => i.ItemId), sups);
        Cache[companyId] = c;
        return c;
    }

    public async Task<BillReadResult> ReadAsync(int companyId, int branchId, byte[] file, string fileName, CancellationToken ct)
    {
        var started = DateTime.UtcNow;
        var text = await source.ReadAsync(file, fileName, ct);
        var res = BillParser.Parse(text);
        var cat = await CatalogAsync(companyId);

        // supplier: GSTIN first, then the name printed on top (character similarity)
        if (res.SupplierGstin != null && cat.Suppliers.FirstOrDefault(s => string.Equals(s.Gstin?.Trim(), res.SupplierGstin, StringComparison.OrdinalIgnoreCase)) is { } byGst)
        { res.SupplierId = BillField<int?>.Of(byGst.SupplierId, 0.98); res.SupplierName = byGst.SupplierName; }
        else if (res.SupplierName is { Length: > 2 } printed)
        {
            var best = cat.Suppliers.Select(s => (s, score: Similar(printed, s.SupplierName))).OrderByDescending(x => x.score).FirstOrDefault();
            if (best.s != null && best.score >= 0.55) { res.SupplierId = BillField<int?>.Of(best.s.SupplierId, Math.Min(0.8, best.score)); res.SupplierName = best.s.SupplierName; }
            else res.Notes.Add($"Supplier \"{printed}\" is not in the Supplier Master: pick the supplier.");
        }
        var sid = res.SupplierId.Value ?? 0;
        if (res.Source == "OCR") foreach (var l in res.Lines) if (l.BatchNo.Value != null) l.BatchNo.Confidence = Math.Min(l.BatchNo.Confidence, 0.6);   // O / 0, I / 1 in batch numbers

        foreach (var l in res.Lines)
        {
            if (l.BillText.Length == 0) { l.MatchedBy = "NONE"; continue; }
            var (id, name, score, by, alts) = cat.Matcher.Match(l.BillText, sid);
            l.ItemId = id; l.ItemName = name; l.MatchScore = Math.Round(score, 2); l.MatchedBy = by; l.Alternatives = alts.Select(a => new BillAlternative(a.Item1, a.Item2, a.Item3)).ToList();
            if (id is int iid && cat.Items.TryGetValue(iid, out var it) && l.GstPercent.Value == null)
                l.GstPercent = BillField<decimal?>.Of(it.GstPercent, 0.75);   // from the Item Master's HSN
        }

        var ids = res.Lines.Where(l => l.ItemId != null).Select(l => l.ItemId!.Value).Distinct().ToList();
        if (ids.Count > 0)
        {
            using var con = db.CreateConnection();
            res.Items = (await con.QueryAsync("dbo.usp_Api_PhBill_ItemInfo", new { CompanyId = companyId, BranchId = branchId, Ids = string.Join(',', ids) }, commandType: CommandType.StoredProcedure))
                        .Select(r => (IDictionary<string, object?>)(IDictionary<string, object>)r).ToList();
        }
        logger.LogInformation("Bill read ({Source}, {Pages} page(s)): {Lines} lines, {Matched} matched, in {Ms} ms",
            res.Source, res.Pages, res.Lines.Count, res.Lines.Count(l => l.ItemId != null), (int)(DateTime.UtcNow - started).TotalMilliseconds);
        return res;
    }

    public async Task<int> LearnAsync(int companyId, int? supplierId, string pairsJson)
    {
        using var con = db.CreateConnection();
        var n = await con.ExecuteScalarAsync<int>("dbo.usp_Api_PhBill_Learn", new { CompanyId = companyId, SupplierId = supplierId, Pairs = pairsJson }, commandType: CommandType.StoredProcedure);
        Cache.TryRemove(companyId, out _);   // the next bill uses what was just learnt
        return n;
    }

    /// <summary>Dice similarity of character bigrams (ignoring "PVT LTD", "PHARMA" ...).</summary>
    private static double Similar(string a, string b)
    {
        static HashSet<string> G(string s)
        {
            s = System.Text.RegularExpressions.Regex.Replace(s.ToUpperInvariant(), @"\b(PVT|LTD|LIMITED|PRIVATE|PHARMA|PHARMACEUTICALS?|DISTRIBUTORS?|AGENCIES|AGENCY|M/S|AND|&)\b|[^A-Z0-9]", "");
            var g = new HashSet<string>();
            for (var i = 0; i < s.Length - 1; i++) g.Add(s.Substring(i, 2));
            return g;
        }
        var x = G(a); var y = G(b);
        return x.Count + y.Count == 0 ? 0 : 2.0 * x.Intersect(y).Count() / (x.Count + y.Count);
    }
}
