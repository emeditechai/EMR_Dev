using System.Data;
using Dapper;

namespace EMR.Web.Services;

/// <summary>A cancellation note of a LAB bill (BillCancellation).</summary>
public sealed class LabBillCancellationRow
{
    public string? CancellationNo { get; set; }
    public DateTime CancellationDate { get; set; }
    public decimal Amount { get; set; }
    public string? Reason { get; set; }
    public string? Type { get; set; }          // F = full, P = partial
}

/// <summary>A refund given on a LAB bill (BillRefund), with the cancellation it belongs to.</summary>
public sealed class LabBillRefundRow
{
    public decimal Amount { get; set; }
    public string? Mode { get; set; }
    public DateTime RefundDate { get; set; }
    public string? TransactionRef { get; set; }
    public string? CancellationNo { get; set; }
}

/// <summary>What changed a LAB bill after it was saved: cancelled tests and refunds (shown on the order list, the order
/// details and the bill print so the totals add up).</summary>
public sealed class LabBillAdjustment
{
    public int LabOrderId { get; set; }
    public int CancelledTests { get; set; }
    public decimal CancelledAmount { get; set; }   // MRP of the cancelled tests
    public int ActiveTests { get; set; }
    public decimal ActiveAmount { get; set; }      // MRP of the tests still on the bill
    public decimal RefundedAmount { get; set; }
    // membership points of a B2C bill (SQLScripts/2236): points used as payment (net of points given back) and points earned
    public string? MembershipCardNo { get; set; }
    public decimal PointsRedeemed { get; set; }
    public decimal PointsRedeemedAmount { get; set; }
    public decimal PointsEarned { get; set; }
    public bool HasPoints => PointsRedeemed > 0 || PointsEarned > 0;
    // misc charges of the bill (SQLScripts/2240), cancelled ones included
    public List<LabOrderMiscLine> MiscLines { get; set; } = [];
    public decimal MiscAmount => MiscLines.Where(m => m.IsActive).Sum(m => m.Amount);            // taxable, active
    public decimal MiscGstAmount => MiscLines.Where(m => m.IsActive).Sum(m => m.GstAmount);
    public decimal MiscCgstAmount => MiscLines.Where(m => m.IsActive).Sum(m => m.CgstAmount);
    public decimal MiscSgstAmount => MiscLines.Where(m => m.IsActive).Sum(m => m.SgstAmount);
    public decimal MiscTotal => MiscLines.Where(m => m.IsActive).Sum(m => m.NetAmount);           // after discount, with GST
    public List<LabBillCancellationRow> Cancellations { get; set; } = [];
    public List<LabBillRefundRow> Refunds { get; set; } = [];
}

public static class LabBillAdjustments
{
    /// <summary>Cancelled tests, cancellation notes and refunds of the given LAB orders, keyed by order id.</summary>
    public static async Task<Dictionary<int, LabBillAdjustment>> LoadAsync(IDbConnection con, IEnumerable<int> labOrderIds)
    {
        var ids = labOrderIds.Where(i => i > 0).Distinct().ToList();
        var map = new Dictionary<int, LabBillAdjustment>();
        if (ids.Count == 0) return map;

        var sums = await con.QueryAsync<LabBillAdjustment>(@"
            SELECT LabOrderId,
                   SUM(CASE WHEN ISNULL(IsActive, 0) = 0 THEN 1 ELSE 0 END)            AS CancelledTests,
                   SUM(CASE WHEN ISNULL(IsActive, 0) = 0 THEN ISNULL(Price, 0) ELSE 0 END) AS CancelledAmount,
                   SUM(CASE WHEN ISNULL(IsActive, 0) = 1 THEN 1 ELSE 0 END)            AS ActiveTests,
                   SUM(CASE WHEN ISNULL(IsActive, 0) = 1 THEN ISNULL(Price, 0) ELSE 0 END) AS ActiveAmount
            FROM dbo.LabOrderItem WHERE LabOrderId IN @Ids GROUP BY LabOrderId", new { Ids = ids });
        foreach (var s in sums) map[s.LabOrderId] = s;

        var cancels = await con.QueryAsync<(int ModuleRefId, string? CancellationNo, DateTime CancellationDate, decimal CancelledAmount, string? Reason, string? CancellationType)>(@"
            SELECT ModuleRefId, CancellationNo, CancellationDate, ISNULL(CancelledAmount, 0), Reason, CancellationType
            FROM dbo.BillCancellation WHERE ModuleCode = 'LAB' AND ModuleRefId IN @Ids AND IsActive = 1
            ORDER BY CancellationDate", new { Ids = ids });
        foreach (var c in cancels)
            if (map.TryGetValue(c.ModuleRefId, out var a))
                a.Cancellations.Add(new LabBillCancellationRow { CancellationNo = c.CancellationNo, CancellationDate = c.CancellationDate, Amount = c.CancelledAmount, Reason = c.Reason, Type = c.CancellationType });

        var refunds = await con.QueryAsync<(int ModuleRefId, decimal RefundAmount, string? RefundMode, DateTime RefundDate, string? TransactionRef, string? CancellationNo)>(@"
            SELECT r.ModuleRefId, r.RefundAmount, r.RefundMode, r.RefundDate, NULLIF(LTRIM(RTRIM(r.TransactionRef)), ''), c.CancellationNo
            FROM dbo.BillRefund r LEFT JOIN dbo.BillCancellation c ON c.CancellationId = r.CancellationId
            WHERE r.ModuleCode = 'LAB' AND r.ModuleRefId IN @Ids AND r.IsActive = 1
            ORDER BY r.RefundDate", new { Ids = ids });
        foreach (var r in refunds)
            if (map.TryGetValue(r.ModuleRefId, out var a))
            {
                a.Refunds.Add(new LabBillRefundRow { Amount = r.RefundAmount, Mode = r.RefundMode, RefundDate = r.RefundDate, TransactionRef = r.TransactionRef, CancellationNo = r.CancellationNo });
                a.RefundedAmount += r.RefundAmount;
            }

        var points = await con.QueryAsync<(int ModuleRefId, string? CardNo, decimal PointsRedeemed, decimal PointsRedeemedAmount, decimal PointsEarned)>(@"
            SELECT ph.ModuleRefId, c.CardNo, ISNULL(ph.PointsRedeemed, 0), ISNULL(ph.PointsRedeemedAmount, 0), ISNULL(ph.PointsEarned, 0)
            FROM dbo.PaymentHeader ph LEFT JOIN dbo.MembershipCard c ON c.CardId = ph.MembershipCardId
            WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId IN @Ids AND ph.MembershipCardId IS NOT NULL
            ORDER BY ph.IsActive, ph.PaymentHeaderId", new { Ids = ids });
        var misc = await con.QueryAsync<LabOrderMiscLine>(@"
            SELECT LabOrderMiscChargeId, LabOrderId, MiscChargeId, ChargeName, ChargeType, Quantity, UnitAmount, Amount, IsDiscountable,
                   IsGstRequired, GstPercentage, DiscountAmount, CgstAmount, SgstAmount, GstAmount, NetAmount, IsActive
            FROM dbo.LabOrderMiscCharge WHERE LabOrderId IN @Ids ORDER BY LabOrderMiscChargeId", new { Ids = ids });
        foreach (var m in misc)
            if (map.TryGetValue(m.LabOrderId, out var a)) a.MiscLines.Add(m);

        foreach (var pt in points)   // the active (latest) header wins
            if (map.TryGetValue(pt.ModuleRefId, out var a))
            {
                a.MembershipCardNo = pt.CardNo;
                a.PointsRedeemed = pt.PointsRedeemed;
                a.PointsRedeemedAmount = pt.PointsRedeemedAmount;
                a.PointsEarned = pt.PointsEarned;
            }
        return map;
    }
}
