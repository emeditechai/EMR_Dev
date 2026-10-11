using System.Data;
using System.Text.Json;
using Dapper;

namespace EMR.Web.Services;

/// <summary>A bill line the membership benefits are worked out for. Kind: T = test / profile, P = package, M = misc charge.</summary>
public sealed record LabBenefitLineInput(string Key, string Kind, int ItemId, decimal Price);

/// <summary>The membership benefits of a B2C LAB bill (usp_Membership_LabBenefits, SQLScripts/2241).</summary>
public sealed class LabMemberBenefit
{
    public int CardId { get; set; }
    public string? CardNo { get; set; }
    public string? PlanName { get; set; }
    public bool FreeHomeCollection { get; set; }
    public bool HasTestRules { get; set; }
    /// <summary>Discount and the rule that gave it, by line key (only lines with a discount).</summary>
    public Dictionary<string, (decimal Discount, string? Rule)> Lines { get; set; } = [];
    public decimal TestDiscount { get; set; }       // benefit rules on tests (blocks a manual discount)
    public decimal MiscDiscount { get; set; }       // Free Home Collection
    public decimal Total => TestDiscount + MiscDiscount;
    public string Reason => $"Membership card {CardNo} ({PlanName})";
}

/// <summary>Plan benefits on a member's B2C LAB bill: benefit rules on tests (category, else department, else "All tests";
/// only tests the rate card allows to be discounted; no packages) and Free Home Collection on Home Collection misc charges.
/// Worked out by the database for the booking preview and again when the bill is saved.</summary>
public static class LabMembershipBenefits
{
    public static async Task<LabMemberBenefit?> ComputeAsync(IDbConnection con, int patientId, int branchId,
        IEnumerable<LabBenefitLineInput> lines, IDbTransaction? tx = null)
    {
        if (patientId <= 0) return null;
        var json = JsonSerializer.Serialize(lines.Select(l => new { key = l.Key, kind = l.Kind, itemId = l.ItemId, price = l.Price }));
        using var multi = await con.QueryMultipleAsync("dbo.usp_Membership_LabBenefits",
            new { PatientId = patientId, BranchId = branchId, LinesJson = json }, tx, commandType: CommandType.StoredProcedure);
        var card = await multi.ReadFirstOrDefaultAsync<LabMemberBenefit>();
        var rows = (await multi.ReadAsync<(string LineKey, string Kind, int ItemId, decimal Price, decimal Discount, string? RuleText)>()).ToList();
        if (card == null) return null;
        foreach (var r in rows.Where(r => r.Discount > 0))
        {
            card.Lines[r.LineKey] = (r.Discount, r.RuleText);
            if (r.Kind == "M") card.MiscDiscount += r.Discount; else card.TestDiscount += r.Discount;
        }
        return card;
    }

    /// <summary>The benefits of a saved bill: its active tests ("I" + LabOrderItemId) and misc lines ("M" + misc line id).</summary>
    public static async Task<LabMemberBenefit?> ForOrderAsync(IDbConnection con, int labOrderId, IDbTransaction? tx = null)
    {
        var order = await con.QueryFirstOrDefaultAsync<(int PatientId, int BranchId, bool IsB2B)>(
            "SELECT PatientId, BranchId, CAST(ISNULL(IsB2B, 0) AS BIT) FROM dbo.LabOrder WHERE LabOrderId = @Id", new { Id = labOrderId }, tx);
        if (order.PatientId <= 0 || order.IsB2B) return null;
        var tests = await con.QueryAsync<(int Id, int InvestigationId, string? Type, decimal Price)>(
            "SELECT LabOrderItemId, InvestigationId, Type, ISNULL(Price, 0) FROM dbo.LabOrderItem WHERE LabOrderId = @Id AND IsActive = 1",
            new { Id = labOrderId }, tx);
        var misc = await con.QueryAsync<(int Id, int MiscChargeId, decimal Amount)>(
            "SELECT LabOrderMiscChargeId, MiscChargeId, Amount FROM dbo.LabOrderMiscCharge WHERE LabOrderId = @Id AND IsActive = 1",
            new { Id = labOrderId }, tx);
        var lines = tests.Select(t => new LabBenefitLineInput("I" + t.Id, string.Equals(t.Type, "P", StringComparison.OrdinalIgnoreCase) ? "P" : "T", t.InvestigationId, t.Price))
            .Concat(misc.Select(m => new LabBenefitLineInput("M" + m.Id, "M", m.MiscChargeId, m.Amount)));
        return await ComputeAsync(con, order.PatientId, order.BranchId, lines, tx);
    }

    public const string ManualDiscountBlockedMessage =
        "This patient's membership benefit already discounts the tests on this bill, so a manual discount cannot be added.";
}
