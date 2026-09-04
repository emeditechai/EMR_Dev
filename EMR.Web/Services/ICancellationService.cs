using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.Services;

public interface ICancellationService
{
    /// <summary>
    /// Searches bills by Bill No, Patient ID, Mobile, or Patient Name.
    /// </summary>
    Task<IEnumerable<BillSearchResultDto>> SearchBillsAsync(string moduleCode, int branchId, string searchTerm);

    /// <summary>
    /// Returns full bill detail including line items and payment info for the cancellation page.
    /// </summary>
    Task<BillDetailForCancellationDto?> GetBillDetailAsync(string moduleCode, int moduleRefId);

    /// <summary>
    /// Cancels selected line items (full or partial) and posts a reversal ledger entry.
    /// </summary>
    Task<BillCancellationResponseDto> CancelBillAsync(BillCancellationRequestDto request, int? userId, int? companyId);

    /// <summary>
    /// Processes a refund against a prior cancellation.
    /// </summary>
    Task<BillRefundResponseDto> ProcessRefundAsync(BillRefundRequestDto request, int? userId);

    /// <summary>
    /// Returns full cancellation and refund history for a bill.
    /// </summary>
    Task<BillCancellationHistoryDto> GetCancellationHistoryAsync(string moduleCode, int moduleRefId);

    /// <summary>
    /// Returns cancelled or refunded bills within a date range.
    /// </summary>
    Task<IEnumerable<BillSearchResultDto>> GetCancelledListAsync(string moduleCode, int branchId, DateTime fromDate, DateTime toDate);
}
