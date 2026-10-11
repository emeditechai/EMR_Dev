using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Web.Models.DTOs;

namespace EMR.Web.Services;

/// <summary>A misc line of a saved LAB bill (dbo.LabOrderMiscCharge, SQLScripts/2240).</summary>
public sealed class LabOrderMiscLine
{
    public int LabOrderMiscChargeId { get; set; }
    public int LabOrderId { get; set; }
    public int MiscChargeId { get; set; }
    public string ChargeName { get; set; } = "";
    public string ChargeType { get; set; } = "";
    public int Quantity { get; set; }
    public decimal UnitAmount { get; set; }
    public decimal Amount { get; set; }
    public bool IsDiscountable { get; set; }
    public bool IsGstRequired { get; set; }
    public decimal? GstPercentage { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal CgstAmount { get; set; }
    public decimal SgstAmount { get; set; }
    public decimal GstAmount { get; set; }
    public decimal NetAmount { get; set; }
    public bool IsActive { get; set; }
    public decimal MembershipDiscountAmount { get; set; }   // Free Home Collection (SQLScripts/2241), part of DiscountAmount

    /// <summary>The ModuleLineRefId of its payment line: negative, so it never matches a LabOrderItemId / InvestigationId.</summary>
    public int LineRefId => -LabOrderMiscChargeId;
    public string DisplayName => Quantity > 1 ? $"{ChargeName} x {Quantity}" : ChargeName;
}

/// <summary>A misc charge priced from the master before the order exists (the booking screen's checks).</summary>
public sealed record LabMiscChargePrice(int MiscChargeId, string ChargeName, string ChargeType, int Quantity, decimal Amount,
                                         bool IsDiscountable, bool IsGstRequired, decimal? GstPercentage, decimal GstAmount)
{
    public decimal Total => Amount + GstAmount;
}

/// <summary>Misc charges on LAB bills (Misc Charges Master, SQLScripts/2239 / 2240). GST is added on top of the amount:
/// CGST = SGST = ROUND((amount - discount) x GST% / 200, 2) - the database, this class and the payment screen all use it.</summary>
public static class LabMiscCharges
{
    public const string ServiceType = "Misc";
    public const int MaxLines = 20;

    /// <summary>Half of the GST on a taxable amount (CGST = SGST = this).</summary>
    public static decimal HalfGst(decimal taxable, decimal? gstPercent) =>
        gstPercent is > 0 && taxable > 0 ? Math.Round(taxable * gstPercent.Value / 200m, 2, MidpointRounding.AwayFromZero) : 0m;

    /// <summary>The screen's [{ miscChargeId, quantity }]: same charge merged, quantity 1-99, at most 20 charges.</summary>
    public static (List<LabOrderMiscChargeRequestDto> Lines, string? Error) Parse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return ([], null);
        List<LabOrderMiscChargeRequestDto>? raw;
        try { raw = JsonSerializer.Deserialize<List<LabOrderMiscChargeRequestDto>>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
        catch { return ([], "The misc charges could not be read. Refresh the page and add them again."); }
        var lines = (raw ?? []).Where(x => x.MiscChargeId > 0)
            .GroupBy(x => x.MiscChargeId)
            .Select(g => new LabOrderMiscChargeRequestDto { MiscChargeId = g.Key, Quantity = g.Sum(x => x.Quantity) })
            .ToList();
        if (lines.Any(x => x.Quantity is < 1 or > 99)) return ([], "Misc charge quantity must be between 1 and 99.");
        if (lines.Count > MaxLines) return ([], $"A bill can carry at most {MaxLines} misc charges.");
        return (lines, null);
    }

    /// <summary>Prices the lines from the active master of the branch's company (the procedure prices them again).</summary>
    public static async Task<(List<LabMiscChargePrice> Prices, string? Error)> PriceAsync(IDbConnection con, int branchId, IReadOnlyList<LabOrderMiscChargeRequestDto> lines)
    {
        if (lines.Count == 0) return ([], null);
        var rows = (await con.QueryAsync<(int Id, string Name, string Type, decimal Amount, bool Disc, bool Gst, decimal? Pct)>(@"
            SELECT m.Misc_Charge_ID, m.Charge_Name, m.Charge_Type, m.Amount, m.Is_Discountable, m.Is_GST_Required, m.GST_Percentage
            FROM dbo.LabMiscChargeMaster m
            WHERE m.Misc_Charge_ID IN @Ids AND m.IsDeleted = 0 AND m.Status = 1
              AND m.CompanyId = ISNULL((SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId), m.CompanyId)",
            new { Ids = lines.Select(l => l.MiscChargeId).ToList(), BranchId = branchId })).ToDictionary(r => r.Id);

        var prices = new List<LabMiscChargePrice>();
        foreach (var l in lines)
        {
            if (!rows.TryGetValue(l.MiscChargeId, out var r))
                return ([], "A selected misc charge is no longer active. Refresh the page and add it again.");
            var amount = r.Amount * l.Quantity;
            var half = r.Gst ? HalfGst(amount, r.Pct) : 0m;
            prices.Add(new LabMiscChargePrice(r.Id, r.Name, r.Type, l.Quantity, amount, r.Disc, r.Gst, r.Gst ? r.Pct : null, half * 2));
        }
        return (prices, null);
    }

    /// <summary>The bill's misc lines (active only unless asked otherwise).</summary>
    public static async Task<List<LabOrderMiscLine>> LoadAsync(IDbConnection con, int labOrderId, IDbTransaction? tx = null, bool activeOnly = true) =>
        (await con.QueryAsync<LabOrderMiscLine>(@"
            SELECT LabOrderMiscChargeId, LabOrderId, MiscChargeId, ChargeName, ChargeType, Quantity, UnitAmount, Amount, IsDiscountable,
                   IsGstRequired, GstPercentage, DiscountAmount, CgstAmount, SgstAmount, GstAmount, NetAmount, IsActive, MembershipDiscountAmount
            FROM dbo.LabOrderMiscCharge
            WHERE LabOrderId = @LabOrderId AND (@ActiveOnly = 0 OR IsActive = 1)
            ORDER BY LabOrderMiscChargeId",
            new { LabOrderId = labOrderId, ActiveOnly = activeOnly }, tx)).ToList();
}
