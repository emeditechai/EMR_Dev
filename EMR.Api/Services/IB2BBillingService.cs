using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public interface IB2BBillingService
    {
        Task<PartnerCreditStatusModel> GetPartnerCreditStatusAsync(string agentType, int agentId, int? branchId = null);
        Task<WalletTopUpResponse> TopUpWalletAsync(WalletTopUpRequest request, int userId);
        Task<IEnumerable<WalletTransactionModel>> GetWalletStatementAsync(int franchiseId, DateTime? fromDate = null, DateTime? toDate = null);
        Task<DeductWalletResponse> DeductWalletPaymentAsync(DeductWalletRequest request, int userId);
        Task<IEnumerable<UninvoicedOrderModel>> GetUninvoicedOrdersAsync(string agentType, int? agentId = null, string? agentIds = null, DateTime? fromDate = null, DateTime? toDate = null);
        Task<GenerateInvoiceResponse> GenerateInvoiceAsync(GenerateInvoiceRequest request, int userId);
        Task<IEnumerable<B2BInvoiceListModel>> GetInvoiceListAsync(string? agentType, int? agentId, string? status, DateTime? fromDate, DateTime? toDate, string? search, int pageNumber = 1, int pageSize = 10);
        Task<B2BInvoiceDetailModel?> GetInvoiceDetailAsync(int invoiceId);
        Task<IEnumerable<OutstandingSettlementBillModel>> GetOutstandingBillsForSettlementAsync(string agentType, int agentId);
        Task<B2BSettleBillsResponse> SettleBillsPaymentAsync(B2BSettleBillsRequest request, int userId);
        Task<B2BSettlementReceiptDto?> GetSettlementReceiptAsync(string receiptNo);
    }
}
