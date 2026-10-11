using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class PaymentSummaryService(IDbConnectionFactory db) : IPaymentSummaryService
{
    public async Task<PaymentSummaryResult?> GetByBillAsync(string moduleCode, int moduleRefId)
    {
        using var con = db.CreateConnection();

        using var multi = await con.QueryMultipleAsync(
            "usp_Api_PaymentSummary_GetByBill",
            new { ModuleCode = moduleCode, ModuleRefId = moduleRefId },
            commandType: System.Data.CommandType.StoredProcedure);

        // RS1: header
        var summary = await multi.ReadSingleOrDefaultAsync<PaymentSummaryResult>();
        if (summary is null) return null;

        // RS2: line items
        summary.Items = (await multi.ReadAsync<PaymentLineItem>()).ToList();

        // RS3: existing payment header (0 or 1 row)
        var existing = await multi.ReadSingleOrDefaultAsync<dynamic>();

        if (existing != null)
        {
            summary.HasExistingPayment          = true;
            summary.ExistingPaymentHeaderId     = (int?)existing.PaymentHeaderId;
            summary.ExistingLineDiscountTotal   = (decimal)existing.LineDiscountTotal;
            summary.ExistingHeaderDiscountType  = string.IsNullOrEmpty((string?)existing.HeaderDiscountType)
                                                    ? (char?)null
                                                    : ((string)existing.HeaderDiscountType)[0];
            summary.ExistingHeaderDiscountValue  = (decimal?)existing.HeaderDiscountValue;
            summary.ExistingHeaderDiscountAmount = (decimal)existing.HeaderDiscountAmount;
            summary.ExistingDiscountReason = (string?)existing.DiscountReason;
            summary.ExistingDiscountApprovedBy = (int?)existing.DiscountApprovedBy;
            summary.ExistingDiscountApprovedByName = (string?)existing.DiscountApprovedByName;
            summary.NetAmount     = (decimal)existing.NetAmount;
            summary.TotalPaid     = (decimal)existing.TotalPaid;
            summary.BalanceDue    = (decimal)existing.BalanceDue;
            summary.PaymentStatus = (string)existing.PaymentStatus;
            var exDict = (IDictionary<string, object>)existing;
            summary.MembershipDiscountAmount = exDict.TryGetValue("MembershipDiscountAmount", out var md) && md != null ? Convert.ToDecimal(md) : 0m;
            summary.MembershipTestDiscount = exDict.TryGetValue("MembershipTestDiscount", out var mt) && mt != null ? Convert.ToDecimal(mt) : 0m;

            // what the bill's receipts add up to - the payment is checked against this (double-payment guard)
            using var con2 = db.CreateConnection();
            // received = receipts less the refunds made on the bill (a cancelled line refunded)
            summary.PaidFromReceipts = await con2.ExecuteScalarAsync<decimal>(@"
                SELECT ISNULL((SELECT SUM(PaidAmount) FROM dbo.PaymentDetail WHERE PaymentHeaderId = @Id AND IsActive = 1), 0)
                     - ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.PaymentHeader h
                               INNER JOIN dbo.BillRefund r ON r.ModuleCode = h.ModuleCode AND r.ModuleRefId = h.ModuleRefId AND r.IsActive = 1
                               WHERE h.PaymentHeaderId = @Id), 0)",
                new { Id = (int)existing.PaymentHeaderId });
        }
        else
        {
            summary.NetAmount     = summary.SubTotal;
            summary.BalanceDue    = summary.SubTotal;
            summary.PaymentStatus = "U";
        }

        return summary;
    }
}
