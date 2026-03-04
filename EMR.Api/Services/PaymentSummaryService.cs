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
            summary.NetAmount     = (decimal)existing.NetAmount;
            summary.TotalPaid     = (decimal)existing.TotalPaid;
            summary.BalanceDue    = (decimal)existing.BalanceDue;
            summary.PaymentStatus = (string)existing.PaymentStatus;
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
