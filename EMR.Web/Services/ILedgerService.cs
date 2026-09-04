using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.Services;

public interface ILedgerService
{
    /// <summary>
    /// Posts a double-entry ledger transaction.
    /// </summary>
    Task<long> PostLedgerEntryAsync(LedgerEntryDto entry);

    /// <summary>
    /// Specific method to handle OPD Bill generation ledger posting.
    /// </summary>
    Task PostOpdBillLedgerAsync(int opdServiceId, decimal totalAmount, int? branchId, int? companyId, int? userId, string billNo);

    /// <summary>
    /// Specific method to handle Lab Bill generation ledger posting.
    /// </summary>
    Task PostLabBillLedgerAsync(int labOrderId, decimal totalAmount, int? branchId, int? companyId, int? userId, string billNo);

    /// <summary>
    /// Posts a reversal ledger entry for a bill cancellation (module-agnostic).
    /// </summary>
    Task PostCancellationReversalAsync(string moduleCode, int moduleRefId, decimal cancelledAmount, int? branchId, int? companyId, int? userId, string billNo, string cancellationNo);
}
