using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients
{
    public interface IB2BBillingApiClient
    {
        Task<PartnerCreditStatusDto?> GetPartnerCreditStatusAsync(string agentType, int agentId, int? branchId = null);
        Task<WalletTopUpResultDto?> TopUpWalletAsync(WalletTopUpDto request);
        Task<IEnumerable<WalletTransactionDto>> GetWalletStatementAsync(int franchiseId, DateTime? fromDate = null, DateTime? toDate = null);
        Task<DeductWalletResultDto?> DeductWalletPaymentAsync(DeductWalletRequestDto request);
        Task<IEnumerable<UninvoicedOrderDto>> GetUninvoicedOrdersAsync(string agentType, int? agentId = null, string? agentIds = null, DateTime? fromDate = null, DateTime? toDate = null);
        Task<GenerateInvoiceResultDto?> GenerateInvoiceAsync(GenerateInvoiceRequestDto request);
        Task<IEnumerable<B2BInvoiceListDto>> GetInvoiceListAsync(string? agentType = null, int? agentId = null, string? status = null, DateTime? fromDate = null, DateTime? toDate = null, string? search = null, int pageNumber = 1, int pageSize = 10);
        Task<B2BInvoiceDetailDto?> GetInvoiceDetailAsync(int invoiceId);
        Task<IEnumerable<OutstandingSettlementBillDto>> GetOutstandingBillsForSettlementAsync(string agentType, int agentId);
        Task<B2BSettleBillsResultDto?> SettleBillsPaymentAsync(B2BSettleBillsRequestDto request);
        Task<B2BSettlementReceiptDto?> GetSettlementReceiptAsync(string receiptNo);
    }
}
