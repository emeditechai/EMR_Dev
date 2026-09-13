using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients
{
    public class B2BBillingApiClient : IB2BBillingApiClient
    {
        private readonly HttpClient httpClient;

        public B2BBillingApiClient(IHttpClientFactory factory)
        {
            httpClient = factory.CreateClient("EmrApi");
        }

        public async Task<PartnerCreditStatusDto?> GetPartnerCreditStatusAsync(string agentType, int agentId, int? branchId = null)
        {
            var query = $"?agentType={Uri.EscapeDataString(agentType)}&agentId={agentId}";
            if (branchId.HasValue) query += $"&branchId={branchId.Value}";

            var response = await httpClient.GetAsync($"api/B2BBilling/partner-credit-status{query}");
            if (!response.IsSuccessStatusCode) return null;

            return await response.Content.ReadFromJsonAsync<PartnerCreditStatusDto>();
        }

        public async Task<WalletTopUpResultDto?> TopUpWalletAsync(WalletTopUpDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/B2BBilling/wallet-topup", request);
            if (!response.IsSuccessStatusCode)
            {
                var err = await response.Content.ReadAsStringAsync();
                throw new HttpRequestException($"Top-up failed: {err}");
            }

            return await response.Content.ReadFromJsonAsync<WalletTopUpResultDto>();
        }

        public async Task<IEnumerable<WalletTransactionDto>> GetWalletStatementAsync(int franchiseId, DateTime? fromDate = null, DateTime? toDate = null)
        {
            var query = "";
            if (fromDate.HasValue) query += $"?fromDate={fromDate.Value:yyyy-MM-dd}";
            if (toDate.HasValue) query += (string.IsNullOrEmpty(query) ? "?" : "&") + $"toDate={toDate.Value:yyyy-MM-dd}";

            var response = await httpClient.GetAsync($"api/B2BBilling/wallet-statement/{franchiseId}{query}");
            if (!response.IsSuccessStatusCode) return Array.Empty<WalletTransactionDto>();

            return await response.Content.ReadFromJsonAsync<IEnumerable<WalletTransactionDto>>() ?? Array.Empty<WalletTransactionDto>();
        }

        public async Task<DeductWalletResultDto?> DeductWalletPaymentAsync(DeductWalletRequestDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/B2BBilling/deduct-wallet", request);
            if (!response.IsSuccessStatusCode)
            {
                var err = await response.Content.ReadAsStringAsync();
                throw new HttpRequestException($"Wallet deduction failed: {err}");
            }

            return await response.Content.ReadFromJsonAsync<DeductWalletResultDto>();
        }

        public async Task<IEnumerable<UninvoicedOrderDto>> GetUninvoicedOrdersAsync(string agentType, int? agentId = null, string? agentIds = null, DateTime? fromDate = null, DateTime? toDate = null)
        {
            var query = $"?agentType={Uri.EscapeDataString(agentType)}";
            if (agentId.HasValue && agentId.Value > 0) query += $"&agentId={agentId.Value}";
            if (!string.IsNullOrWhiteSpace(agentIds)) query += $"&agentIds={Uri.EscapeDataString(agentIds)}";
            if (fromDate.HasValue) query += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
            if (toDate.HasValue) query += $"&toDate={toDate.Value:yyyy-MM-dd}";

            var response = await httpClient.GetAsync($"api/B2BBilling/uninvoiced-orders{query}");
            if (!response.IsSuccessStatusCode) return Array.Empty<UninvoicedOrderDto>();

            return await response.Content.ReadFromJsonAsync<IEnumerable<UninvoicedOrderDto>>() ?? Array.Empty<UninvoicedOrderDto>();
        }

        public async Task<GenerateInvoiceResultDto?> GenerateInvoiceAsync(GenerateInvoiceRequestDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/B2BBilling/generate-invoice", request);
            if (!response.IsSuccessStatusCode)
            {
                var err = await response.Content.ReadAsStringAsync();
                throw new HttpRequestException($"Invoice generation failed: {err}");
            }

            return await response.Content.ReadFromJsonAsync<GenerateInvoiceResultDto>();
        }

        public async Task<IEnumerable<B2BInvoiceListDto>> GetInvoiceListAsync(string? agentType = null, int? agentId = null, string? status = null, DateTime? fromDate = null, DateTime? toDate = null, string? search = null, int pageNumber = 1, int pageSize = 10)
        {
            var query = $"?pageNumber={pageNumber}&pageSize={pageSize}";
            if (!string.IsNullOrEmpty(agentType)) query += $"&agentType={Uri.EscapeDataString(agentType)}";
            if (agentId.HasValue) query += $"&agentId={agentId.Value}";
            if (!string.IsNullOrEmpty(status)) query += $"&status={Uri.EscapeDataString(status)}";
            if (fromDate.HasValue) query += $"&fromDate={fromDate.Value:yyyy-MM-dd}";
            if (toDate.HasValue) query += $"&toDate={toDate.Value:yyyy-MM-dd}";
            if (!string.IsNullOrEmpty(search)) query += $"&search={Uri.EscapeDataString(search)}";

            var response = await httpClient.GetAsync($"api/B2BBilling/invoices{query}");
            if (!response.IsSuccessStatusCode) return Array.Empty<B2BInvoiceListDto>();

            return await response.Content.ReadFromJsonAsync<IEnumerable<B2BInvoiceListDto>>() ?? Array.Empty<B2BInvoiceListDto>();
        }

        public async Task<B2BInvoiceDetailDto?> GetInvoiceDetailAsync(int invoiceId)
        {
            var response = await httpClient.GetAsync($"api/B2BBilling/invoices/{invoiceId}");
            if (!response.IsSuccessStatusCode) return null;

            return await response.Content.ReadFromJsonAsync<B2BInvoiceDetailDto>();
        }

        public async Task<IEnumerable<OutstandingSettlementBillDto>> GetOutstandingBillsForSettlementAsync(string agentType, int agentId)
        {
            var query = $"?agentType={Uri.EscapeDataString(agentType)}&agentId={agentId}";
            var response = await httpClient.GetAsync($"api/B2BBilling/outstanding-settlement{query}");
            if (!response.IsSuccessStatusCode) return Array.Empty<OutstandingSettlementBillDto>();

            return await response.Content.ReadFromJsonAsync<IEnumerable<OutstandingSettlementBillDto>>() ?? Array.Empty<OutstandingSettlementBillDto>();
        }

        public async Task<B2BSettleBillsResultDto?> SettleBillsPaymentAsync(B2BSettleBillsRequestDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/B2BBilling/settle-bills", request);
            if (!response.IsSuccessStatusCode)
            {
                var err = await response.Content.ReadAsStringAsync();
                throw new HttpRequestException($"Bills settlement failed: {err}");
            }

            return await response.Content.ReadFromJsonAsync<B2BSettleBillsResultDto>();
        }

        public async Task<B2BSettlementReceiptDto?> GetSettlementReceiptAsync(string receiptNo)
        {
            var response = await httpClient.GetAsync($"api/B2BBilling/settlement-receipt/{Uri.EscapeDataString(receiptNo)}");
            if (!response.IsSuccessStatusCode) return null;

            return await response.Content.ReadFromJsonAsync<B2BSettlementReceiptDto>();
        }
    }
}
