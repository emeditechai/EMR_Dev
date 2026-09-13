using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public class B2BBillingService(IDbConnectionFactory db) : IB2BBillingService
    {
        public async Task<PartnerCreditStatusModel> GetPartnerCreditStatusAsync(string agentType, int agentId, int? branchId = null)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@AgentType", agentType);
            p.Add("@AgentId", agentId);
            p.Add("@BranchId", branchId);

            var result = await conn.QuerySingleOrDefaultAsync<PartnerCreditStatusModel>(
                "dbo.usp_B2B_GetPartnerCreditStatus",
                p,
                commandType: CommandType.StoredProcedure);

            return result ?? new PartnerCreditStatusModel
            {
                Found = false,
                AgentType = agentType,
                AgentId = agentId,
                CanBook = false,
                BlockReason = "Partner details could not be retrieved."
            };
        }

        public async Task<WalletTopUpResponse> TopUpWalletAsync(WalletTopUpRequest request, int userId)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@FranchiseId", request.FranchiseId);
            p.Add("@Amount", request.Amount);
            p.Add("@PaymentMethodId", request.PaymentMethodId);
            p.Add("@TransactionRef", request.TransactionRef);
            p.Add("@BranchId", request.BranchId);
            p.Add("@UserId", userId);
            p.Add("@Narration", request.Narration);
            p.Add("@ReceiptNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);
            p.Add("@NewBalance", dbType: DbType.Decimal, direction: ParameterDirection.Output);

            await conn.ExecuteAsync("dbo.usp_B2B_FranchiseWallet_TopUp", p, commandType: CommandType.StoredProcedure);

            return new WalletTopUpResponse
            {
                Success = true,
                ReceiptNo = p.Get<string>("@ReceiptNo"),
                NewBalance = p.Get<decimal>("@NewBalance"),
                Message = "Wallet top-up successful."
            };
        }

        public async Task<IEnumerable<WalletTransactionModel>> GetWalletStatementAsync(int franchiseId, DateTime? fromDate = null, DateTime? toDate = null)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@FranchiseId", franchiseId);
            p.Add("@FromDate", fromDate);
            p.Add("@ToDate", toDate);

            return await conn.QueryAsync<WalletTransactionModel>(
                "dbo.usp_B2B_GetFranchiseWalletStatement",
                p,
                commandType: CommandType.StoredProcedure);
        }

        public async Task<DeductWalletResponse> DeductWalletPaymentAsync(DeductWalletRequest request, int userId)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@LabOrderId", request.LabOrderId);
            p.Add("@FranchiseId", request.FranchiseId);
            p.Add("@Amount", request.Amount);
            p.Add("@BranchId", request.BranchId);
            p.Add("@UserId", userId);
            p.Add("@BillNo", request.BillNo);
            p.Add("@ReceiptNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);
            p.Add("@TokenNo", dbType: DbType.String, size: 20, direction: ParameterDirection.Output);

            await conn.ExecuteAsync("dbo.usp_B2B_DeductWalletPayment", p, commandType: CommandType.StoredProcedure);

            return new DeductWalletResponse
            {
                Success = true,
                ReceiptNo = p.Get<string>("@ReceiptNo"),
                TokenNo = p.Get<string>("@TokenNo"),
                Message = "Wallet deduction successful."
            };
        }

        public async Task<IEnumerable<UninvoicedOrderModel>> GetUninvoicedOrdersAsync(string agentType, int? agentId = null, string? agentIds = null, DateTime? fromDate = null, DateTime? toDate = null)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@AgentType", agentType);
            p.Add("@AgentId", agentId ?? 0);
            p.Add("@AgentIds", agentIds);
            p.Add("@FromDate", fromDate);
            p.Add("@ToDate", toDate);

            return await conn.QueryAsync<UninvoicedOrderModel>(
                "dbo.usp_B2B_GetUninvoicedOrders",
                p,
                commandType: CommandType.StoredProcedure);
        }

        public async Task<GenerateInvoiceResponse> GenerateInvoiceAsync(GenerateInvoiceRequest request, int userId)
        {
            using var conn = db.CreateConnection();

            // Check if multi-partner batch invoice generation is requested
            if (request.PartnerGroups != null && request.PartnerGroups.Count > 0)
            {
                var response = new GenerateInvoiceResponse
                {
                    Success = true,
                    GeneratedInvoices = new List<GeneratedInvoiceSummary>()
                };

                foreach (var group in request.PartnerGroups)
                {
                    if (string.IsNullOrWhiteSpace(group.SelectedOrderIds) || group.AgentId <= 0) continue;

                    var p = new DynamicParameters();
                    p.Add("@AgentType", request.AgentType);
                    p.Add("@AgentId", group.AgentId);
                    p.Add("@BranchId", request.BranchId);
                    p.Add("@SelectedOrderIds", group.SelectedOrderIds);
                    p.Add("@BillingCycle", request.BillingCycle ?? "Monthly");
                    p.Add("@Notes", request.Notes);
                    p.Add("@UserId", userId);
                    p.Add("@InvoiceId", dbType: DbType.Int32, direction: ParameterDirection.Output);
                    p.Add("@InvoiceNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);

                    await conn.ExecuteAsync("dbo.usp_B2B_GenerateInvoice", p, commandType: CommandType.StoredProcedure);

                    int invId = p.Get<int>("@InvoiceId");
                    string invNo = p.Get<string>("@InvoiceNo");

                    var summary = await conn.QueryFirstOrDefaultAsync<GeneratedInvoiceSummary>(@"
                        SELECT 
                            bi.InvoiceId, 
                            bi.InvoiceNo, 
                            bi.PartnerId AS AgentId, 
                            CASE bi.PartnerType WHEN 'F' THEN f.Franchise_Name WHEN 'C' THEN c.Corporate_Name ELSE 'Partner' END AS PartnerName,
                            CASE bi.PartnerType WHEN 'F' THEN f.Franchise_Code WHEN 'C' THEN c.Corporate_Code ELSE '' END AS PartnerCode,
                            (SELECT COUNT(1) FROM dbo.B2BInvoiceItem WHERE InvoiceId = bi.InvoiceId) AS OrderCount,
                            bi.NetAmount AS TotalAmount
                        FROM dbo.B2BInvoice bi
                        LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = bi.PartnerId AND bi.PartnerType = 'F'
                        LEFT JOIN dbo.CorporateMaster c ON c.Corporate_ID = bi.PartnerId AND bi.PartnerType = 'C'
                        WHERE bi.InvoiceId = @InvoiceId;", new { InvoiceId = invId });

                    if (summary != null)
                    {
                        response.GeneratedInvoices.Add(summary);
                    }
                    else
                    {
                        response.GeneratedInvoices.Add(new GeneratedInvoiceSummary
                        {
                            InvoiceId = invId,
                            InvoiceNo = invNo,
                            AgentId = group.AgentId
                        });
                    }

                    if (response.InvoiceId == 0)
                    {
                        response.InvoiceId = invId;
                        response.InvoiceNo = invNo;
                    }
                }

                response.Message = $"{response.GeneratedInvoices.Count} B2B invoices generated successfully in one shot.";
                return response;
            }
            else
            {
                var p = new DynamicParameters();
                p.Add("@AgentType", request.AgentType);
                p.Add("@AgentId", request.AgentId);
                p.Add("@BranchId", request.BranchId);
                p.Add("@SelectedOrderIds", request.SelectedOrderIds);
                p.Add("@BillingCycle", request.BillingCycle ?? "Monthly");
                p.Add("@Notes", request.Notes);
                p.Add("@UserId", userId);
                p.Add("@InvoiceId", dbType: DbType.Int32, direction: ParameterDirection.Output);
                p.Add("@InvoiceNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);

                await conn.ExecuteAsync("dbo.usp_B2B_GenerateInvoice", p, commandType: CommandType.StoredProcedure);

                int invId = p.Get<int>("@InvoiceId");
                string invNo = p.Get<string>("@InvoiceNo");

                var summary = await conn.QueryFirstOrDefaultAsync<GeneratedInvoiceSummary>(@"
                    SELECT 
                        bi.InvoiceId, 
                        bi.InvoiceNo, 
                        bi.PartnerId AS AgentId, 
                        CASE bi.PartnerType WHEN 'F' THEN f.Franchise_Name WHEN 'C' THEN c.Corporate_Name ELSE 'Partner' END AS PartnerName,
                        CASE bi.PartnerType WHEN 'F' THEN f.Franchise_Code WHEN 'C' THEN c.Corporate_Code ELSE '' END AS PartnerCode,
                        (SELECT COUNT(1) FROM dbo.B2BInvoiceItem WHERE InvoiceId = bi.InvoiceId) AS OrderCount,
                        bi.NetAmount AS TotalAmount
                    FROM dbo.B2BInvoice bi
                    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = bi.PartnerId AND bi.PartnerType = 'F'
                    LEFT JOIN dbo.CorporateMaster c ON c.Corporate_ID = bi.PartnerId AND bi.PartnerType = 'C'
                    WHERE bi.InvoiceId = @InvoiceId;", new { InvoiceId = invId });

                var resp = new GenerateInvoiceResponse
                {
                    Success = true,
                    InvoiceId = invId,
                    InvoiceNo = invNo,
                    Message = "B2B Invoice generated successfully."
                };

                if (summary != null) resp.GeneratedInvoices.Add(summary);

                return resp;
            }
        }

        public async Task<IEnumerable<B2BInvoiceListModel>> GetInvoiceListAsync(string? agentType, int? agentId, string? status, DateTime? fromDate, DateTime? toDate, string? search, int pageNumber = 1, int pageSize = 10)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@AgentType", agentType);
            p.Add("@AgentId", agentId);
            p.Add("@Status", status);
            p.Add("@FromDate", fromDate);
            p.Add("@ToDate", toDate);
            p.Add("@Search", search);
            p.Add("@PageNumber", pageNumber);
            p.Add("@PageSize", pageSize);

            return await conn.QueryAsync<B2BInvoiceListModel>(
                "dbo.usp_B2B_GetInvoiceList",
                p,
                commandType: CommandType.StoredProcedure);
        }

        public async Task<B2BInvoiceDetailModel?> GetInvoiceDetailAsync(int invoiceId)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@InvoiceId", invoiceId);

            using var multi = await conn.QueryMultipleAsync(
                "dbo.usp_B2B_GetInvoiceDetail",
                p,
                commandType: CommandType.StoredProcedure);

            var header = await multi.ReadSingleOrDefaultAsync<B2BInvoiceDetailModel>();
            if (header != null)
            {
                var items = (await multi.ReadAsync<B2BInvoiceItemModel>()).ToList();
                var testLines = (await multi.ReadAsync<B2BInvoiceTestLineModel>()).ToList();

                var testGroup = testLines.GroupBy(t => t.LabOrderId).ToDictionary(g => g.Key, g => g.ToList());
                foreach (var item in items)
                {
                    if (testGroup.TryGetValue(item.LabOrderId, out var tests))
                    {
                        item.Tests = tests;
                    }
                }

                header.Items = items;
                header.TestLines = testLines;
            }

            return header;
        }

        public async Task<IEnumerable<OutstandingSettlementBillModel>> GetOutstandingBillsForSettlementAsync(string agentType, int agentId)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@AgentType", agentType);
            p.Add("@AgentId", agentId);

            return await conn.QueryAsync<OutstandingSettlementBillModel>(
                "dbo.usp_B2B_GetOutstandingBillsForSettlement",
                p,
                commandType: CommandType.StoredProcedure);
        }

        public async Task<B2BSettleBillsResponse> SettleBillsPaymentAsync(B2BSettleBillsRequest request, int userId)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@AgentType", request.AgentType);
            p.Add("@AgentId", request.AgentId);
            p.Add("@BranchId", request.BranchId);
            p.Add("@PaymentMethodId", request.PaymentMethodId);
            p.Add("@PaidAmount", request.PaidAmount);
            p.Add("@TransactionRef", request.TransactionRef);
            p.Add("@BankName", request.BankName);
            p.Add("@ChequeNo", request.ChequeNo);
            p.Add("@ChequeDate", request.ChequeDate);
            p.Add("@PaymentDate", request.PaymentDate);
            p.Add("@SelectedBillsJson", JsonSerializer.Serialize(request.SelectedBills));
            p.Add("@Notes", request.Notes);
            p.Add("@UserId", userId);
            p.Add("@BatchReceiptNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);
            p.Add("@SettledBillCount", dbType: DbType.Int32, direction: ParameterDirection.Output);

            await conn.ExecuteAsync("dbo.usp_B2B_SettleBillsPayment", p, commandType: CommandType.StoredProcedure);

            return new B2BSettleBillsResponse
            {
                Success = true,
                BatchReceiptNo = p.Get<string>("@BatchReceiptNo"),
                SettledBillCount = p.Get<int>("@SettledBillCount"),
                Message = "Bills settled successfully."
            };
        }

        public async Task<B2BSettlementReceiptDto?> GetSettlementReceiptAsync(string receiptNo)
        {
            using var conn = db.CreateConnection();
            using var multi = await conn.QueryMultipleAsync(
                "dbo.usp_B2B_GetSettlementReceipt",
                new { ReceiptNo = receiptNo },
                commandType: CommandType.StoredProcedure
            );

            var header = await multi.ReadFirstOrDefaultAsync<B2BSettlementReceiptDto>();
            if (header == null) return null;

            header.Bills = (await multi.ReadAsync<B2BSettledBillLineDto>()).ToList();
            return header;
        }
    }
}
