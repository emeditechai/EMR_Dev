using System.Data;
using Dapper;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

/// <summary>One billed LAB line as the department-wise discount sees it: its discount head (a department, or
/// "Packages" for a package - a package is not billed under a department) and whether the B2C rate card allows a
/// discount on it.</summary>
public sealed class LabDiscountLine
{
    public int Index { get; set; }                 // position in the request (booking preview) - 0 for a saved bill
    public int LabOrderItemId { get; set; }        // 0 before the bill exists
    public int InvestigationId { get; set; }
    public bool IsPackage { get; set; }
    public decimal Price { get; set; }
    public bool Eligible { get; set; }             // B2C rate card "Discount Allowed"
    public int? DeptId { get; set; }
    public string? DeptName { get; set; }

    public string GroupKey => IsPackage ? LabDepartmentDiscount.PackagesKey : $"D{DeptId ?? 0}";
    public string GroupName => IsPackage ? "Packages" : (string.IsNullOrWhiteSpace(DeptName) ? "Other" : DeptName!);
}

/// <summary>The discount one line gets from a department-wise discount.</summary>
public sealed record LabLineDiscount(string Type, decimal Value, decimal Amount);

/// <summary>
/// Department-wise discount on a B2C LAB bill (HeaderDiscountType "D"): each discount head - one per department on the
/// bill plus "Packages" - takes its own % or ₹. A % head discounts each eligible line by round(price × % / 100, 2); a ₹
/// head (capped at the head's eligible total) is spread over its eligible lines in proportion to price, the last line
/// taking the rounding remainder (the method the overall discount uses). Lines the rate card does not allow get none.
/// </summary>
public static class LabDepartmentDiscount
{
    public const string HeaderType = "D";
    public const string PackagesKey = "PKG";

    // B2C rate card "Discount Allowed" of the branch for one item (the newest active card when there are several)
    private const string EligibilityApply = @"
        OUTER APPLY (
            SELECT TOP 1 CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) AS Allowed
            FROM dbo.LabRateCardMaster m
            INNER JOIN dbo.LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID AND d.IsDeleted = 0
            WHERE m.Branch_ID = @BranchId AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0
              AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
              AND d.Item_ID = {0}
              AND d.Item_Type = CASE WHEN {1} = 1 THEN 'Package' WHEN lim.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END
            ORDER BY m.Effective_From DESC, m.RateCard_ID DESC) e";

    /// <summary>The active lines of a saved bill, with their head and eligibility (B2B bills return IsB2B = true).</summary>
    public static async Task<(List<LabDiscountLine> Lines, bool IsB2B, int BranchId)> LoadForOrderAsync(IDbConnection con, int labOrderId, IDbTransaction? tx = null)
    {
        var order = await con.QuerySingleOrDefaultAsync<(int BranchId, bool IsB2B)>(
            "SELECT ISNULL(BranchId, 0), CAST(ISNULL(IsB2B, 0) AS BIT) FROM dbo.LabOrder WHERE LabOrderId = @Id",
            new { Id = labOrderId }, tx);
        var lines = (await con.QueryAsync<LabDiscountLine>(@"
            SELECT loi.LabOrderItemId, loi.InvestigationId,
                   CAST(CASE WHEN loi.Type = 'P' THEN 1 ELSE 0 END AS BIT) AS IsPackage,
                   ISNULL(loi.Price, 0) AS Price,
                   CAST(ISNULL(e.Allowed, 0) AS BIT) AS Eligible,
                   CASE WHEN loi.Type = 'P' THEN NULL ELSE lim.Department_ID END AS DeptId,
                   CASE WHEN loi.Type = 'P' THEN NULL ELSE dm.DeptName END AS DeptName
            FROM dbo.LabOrderItem loi
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
            LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID" + string.Format(EligibilityApply, "loi.InvestigationId", "CASE WHEN loi.Type = 'P' THEN 1 ELSE 0 END") + @"
            WHERE loi.LabOrderId = @Id AND loi.IsActive = 1
            ORDER BY loi.LabOrderItemId",
            new { Id = labOrderId, order.BranchId }, tx)).ToList();
        return (lines, order.IsB2B, order.BranchId);
    }

    /// <summary>Lines of a bill still being booked (no order yet): investigation id, package flag and price per line.</summary>
    public static async Task<List<LabDiscountLine>> LoadForItemsAsync(IDbConnection con, int branchId, IReadOnlyList<(int InvestigationId, bool IsPackage, decimal Price)> items)
    {
        if (items.Count == 0) return [];
        var json = System.Text.Json.JsonSerializer.Serialize(items.Select((x, i) => new { idx = i, id = x.InvestigationId, pkg = x.IsPackage ? 1 : 0, price = x.Price }));
        return (await con.QueryAsync<LabDiscountLine>(@"
            SELECT j.Idx AS [Index], 0 AS LabOrderItemId, j.InvestigationId, CAST(j.IsPackage AS BIT) AS IsPackage, j.Price,
                   CAST(ISNULL(e.Allowed, 0) AS BIT) AS Eligible,
                   CASE WHEN j.IsPackage = 1 THEN NULL ELSE lim.Department_ID END AS DeptId,
                   CASE WHEN j.IsPackage = 1 THEN NULL ELSE dm.DeptName END AS DeptName
            FROM OPENJSON(@Items) WITH (Idx INT '$.idx', InvestigationId INT '$.id', IsPackage INT '$.pkg', Price DECIMAL(18, 2) '$.price') j
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = j.InvestigationId AND j.IsPackage = 0
            LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID" + string.Format(EligibilityApply, "j.InvestigationId", "j.IsPackage") + @"
            ORDER BY j.Idx",
            new { Items = json, BranchId = branchId })).ToList();
    }

    /// <summary>The discount of every line (same order as <paramref name="lines"/>) and the bill total, or an error.</summary>
    public static (List<LabLineDiscount> PerLine, decimal Total, string? Error) Compute(IReadOnlyList<LabDiscountLine> lines, IReadOnlyList<DepartmentDiscountRow>? rows)
    {
        var perLine = lines.Select(_ => new LabLineDiscount(string.Empty, 0m, 0m)).ToList();
        if (rows is null || rows.Count == 0) return (perLine, 0m, "Enter a discount for at least one department.");

        var heads = lines.Select(l => l.GroupKey).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in rows)
        {
            var key = (r.GroupKey ?? string.Empty).Trim();
            var type = (r.Type ?? "P").Trim().ToUpperInvariant();
            if (!heads.Contains(key)) return (perLine, 0m, "The department discount does not match the tests on this bill. Reopen the discount and try again.");
            if (!seen.Add(key)) return (perLine, 0m, "A department appears twice in the discount.");
            if (type is not ("P" or "F")) return (perLine, 0m, "A department discount must be a % or a ₹ amount.");
            if (r.Value < 0 || (type == "P" && r.Value > 100)) return (perLine, 0m, "A department discount must be between 0 and 100%, or a ₹ amount of 0 or more.");
        }

        foreach (var r in rows.Where(r => r.Value > 0))
        {
            var key = r.GroupKey.Trim();
            var type = r.Type.Trim().ToUpperInvariant();
            var idx = Enumerable.Range(0, lines.Count)
                .Where(i => lines[i].Eligible && lines[i].Price > 0 && string.Equals(lines[i].GroupKey, key, StringComparison.OrdinalIgnoreCase))
                .ToList();
            if (idx.Count == 0) continue;

            if (type == "P")
            {
                foreach (var i in idx)
                    perLine[i] = new LabLineDiscount("P", r.Value, Math.Round(lines[i].Price * r.Value / 100m, 2, MidpointRounding.AwayFromZero));
            }
            else
            {
                var eligibleTotal = idx.Sum(i => lines[i].Price);
                var amount = Math.Min(r.Value, eligibleTotal);
                decimal allocated = 0m;
                for (int k = 0; k < idx.Count; k++)
                {
                    var i = idx[k];
                    var share = k == idx.Count - 1
                        ? Math.Max(0, amount - allocated)
                        : Math.Round(amount * (lines[i].Price / eligibleTotal), 2, MidpointRounding.AwayFromZero);
                    allocated += share;
                    perLine[i] = new LabLineDiscount("F", r.Value, Math.Min(share, lines[i].Price));
                }
            }
        }

        var total = perLine.Sum(p => p.Amount);
        return total > 0 ? (perLine, total, null) : (perLine, 0m, "Enter a discount for at least one department.");
    }
}
