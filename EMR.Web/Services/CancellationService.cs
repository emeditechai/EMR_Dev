using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.DTOs;
using Microsoft.Extensions.Logging;

namespace EMR.Web.Services;

public class CancellationService(IDbConnectionFactory db, ILedgerService ledgerService, ILogger<CancellationService> logger) : ICancellationService
{
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };

    // ── Search ─────────────────────────────────────────────────────────────────
    public async Task<IEnumerable<BillSearchResultDto>> SearchBillsAsync(string moduleCode, int branchId, string searchTerm)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<BillSearchResultDto>(
            "dbo.usp_BillSearch",
            new { ModuleCode = moduleCode, BranchId = branchId, SearchTerm = searchTerm.Trim() },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 30
        );
    }

    // ── Get Detail ─────────────────────────────────────────────────────────────
    public async Task<BillDetailForCancellationDto?> GetBillDetailAsync(string moduleCode, int moduleRefId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync(
            "dbo.usp_Bill_GetDetailForCancellation",
            new { ModuleCode = moduleCode, ModuleRefId = moduleRefId },
            commandType: CommandType.StoredProcedure
        );

        var header = await multi.ReadFirstOrDefaultAsync<BillDetailForCancellationDto>();
        if (header == null) return null;

        header.Items    = (await multi.ReadAsync<BillLineItemForCancellationDto>()).ToList();
        header.Payments = (await multi.ReadAsync<BillPaymentSummaryDto>()).ToList();

        return header;
    }

    // ── Cancel Bill ────────────────────────────────────────────────────────────
    public async Task<BillCancellationResponseDto> CancelBillAsync(BillCancellationRequestDto request, int? userId, int? companyId)
    {
        if (request.Items == null || !request.Items.Any())
            return Fail("At least one line item must be selected for cancellation.");

        // Build JSON for SP
        var itemsJson = JsonSerializer.Serialize(
            request.Items.Select(x => new { lineRefId = x.LineRefId, amount = x.Amount }),
            JsonOpts
        );

        try
        {
            using var con = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@ModuleCode",       request.ModuleCode);
            p.Add("@ModuleRefId",      request.ModuleRefId);
            p.Add("@BranchId",         request.BranchId);
            p.Add("@LineItemsJson",    itemsJson);
            p.Add("@Reason",           request.Reason);
            p.Add("@DiscountAdjusted", request.DiscountAdjusted);
            p.Add("@UserId",           userId);
            p.Add("@CancellationId",   dbType: DbType.Int32, direction: ParameterDirection.Output);
            p.Add("@CancellationNo",   dbType: DbType.String, size: 50, direction: ParameterDirection.Output);

            await con.ExecuteAsync("dbo.usp_Bill_Cancel", p, commandType: CommandType.StoredProcedure, commandTimeout: 30);

            int    cancellationId  = p.Get<int>("@CancellationId");
            string cancellationNo  = p.Get<string>("@CancellationNo");
            decimal totalCancelled = request.Items.Sum(x => x.Amount);
            bool   isFull          = request.Items.Count == await GetTotalActiveItemsAsync(con, request.ModuleCode, request.ModuleRefId);

            // Fetch bill no for ledger narration
            string billNo = await GetBillNoAsync(con, request.ModuleCode, request.ModuleRefId);

            // Post reversal ledger entry
            await ledgerService.PostCancellationReversalAsync(
                request.ModuleCode, request.ModuleRefId,
                totalCancelled,
                request.BranchId, companyId, userId,
                billNo, cancellationNo
            );

            logger.LogInformation("Bill cancelled: {ModuleCode} #{ModuleRefId} → {CancellationNo} Amount={CancelledAmount}", request.ModuleCode, request.ModuleRefId, cancellationNo, totalCancelled);

            return new BillCancellationResponseDto
            {
                Success          = true,
                CancellationId   = cancellationId,
                CancellationNo   = cancellationNo,
                CancelledAmount  = totalCancelled,
                CancellationType = isFull ? "Full" : "Partial"
            };
        }
        catch (Exception ex) when (ex.Message.Contains("already cancelled"))
        {
            return Fail("One or more selected items are already cancelled.");
        }
        catch (Exception ex) when (ex.Message.Contains("No items selected"))
        {
            return Fail("No items selected for cancellation.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error cancelling {ModuleCode} #{ModuleRefId}", request.ModuleCode, request.ModuleRefId);
            return Fail($"Cancellation failed: {ex.Message}");
        }
    }

    // ── Process Refund ─────────────────────────────────────────────────────────
    public async Task<BillRefundResponseDto> ProcessRefundAsync(BillRefundRequestDto request, int? userId)
    {
        if (request.RefundAmount <= 0)
            return FailRefund("Refund amount must be greater than zero.");

        if (string.IsNullOrWhiteSpace(request.RefundMode))
            return FailRefund("Refund mode is required.");

        try
        {
            using var con = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@ModuleCode",     request.ModuleCode);
            p.Add("@ModuleRefId",    request.ModuleRefId);
            p.Add("@CancellationId", request.CancellationId);
            p.Add("@RefundAmount",   request.RefundAmount);
            p.Add("@RefundMode",     request.RefundMode);
            p.Add("@TransactionRef", request.TransactionRef);
            p.Add("@Notes",          request.Notes);
            p.Add("@UserId",         userId);
            p.Add("@RefundId",       dbType: DbType.Int32, direction: ParameterDirection.Output);

            await con.ExecuteAsync("dbo.usp_Bill_Refund", p, commandType: CommandType.StoredProcedure, commandTimeout: 30);

            int refundId = p.Get<int>("@RefundId");

            logger.LogInformation("Refund processed: {ModuleCode} #{ModuleRefId} RefundId={RefundId} Amount={Amount}", request.ModuleCode, request.ModuleRefId, refundId, request.RefundAmount);

            return new BillRefundResponseDto
            {
                Success      = true,
                RefundId     = refundId,
                RefundAmount = request.RefundAmount,
                RefundMode   = request.RefundMode
            };
        }
        catch (Exception ex) when (ex.Message.Contains("cancel the bill first"))
        {
            return FailRefund("No valid cancellation found. Please cancel the bill first.");
        }
        catch (Exception ex) when (ex.Message.Contains("exceeds total paid"))
        {
            return FailRefund("Refund amount exceeds the total paid amount.");
        }
        catch (Exception ex) when (ex.Message.Contains("exceeds cancelled"))
        {
            return FailRefund("Refund amount exceeds the total cancelled amount.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error processing refund for {ModuleCode} #{ModuleRefId}", request.ModuleCode, request.ModuleRefId);
            return FailRefund($"Refund failed: {ex.Message}");
        }
    }

    // ── Cancellation History ───────────────────────────────────────────────────
    public async Task<BillCancellationHistoryDto> GetCancellationHistoryAsync(string moduleCode, int moduleRefId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync(
            "dbo.usp_Bill_GetCancellationHistory",
            new { ModuleCode = moduleCode, ModuleRefId = moduleRefId },
            commandType: CommandType.StoredProcedure
        );

        var result = new BillCancellationHistoryDto
        {
            Cancellations     = (await multi.ReadAsync<CancellationHistoryItemDto>()).ToList(),
            CancellationItems = (await multi.ReadAsync<CancellationHistoryLineItemDto>()).ToList(),
            Refunds           = (await multi.ReadAsync<RefundHistoryItemDto>()).ToList()
        };

        return result;
    }

    public async Task<IEnumerable<BillSearchResultDto>> GetCancelledListAsync(string moduleCode, int branchId, DateTime fromDate, DateTime toDate)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<BillSearchResultDto>(
            "dbo.usp_BillCancellation_GetList",
            new { ModuleCode = moduleCode, BranchId = branchId, FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    private static async Task<int> GetTotalActiveItemsAsync(IDbConnection con, string moduleCode, int moduleRefId)
    {
        if (moduleCode == "LAB")
            return await con.QuerySingleOrDefaultAsync<int>(
                "SELECT COUNT(*) FROM dbo.LabOrderItem WHERE LabOrderId = @Id AND IsActive = 1",
                new { Id = moduleRefId });

        return await con.QuerySingleOrDefaultAsync<int>(
            "SELECT COUNT(*) FROM dbo.PatientOPDServiceItem WHERE OPDServiceId = @Id AND IsActive = 1",
            new { Id = moduleRefId });
    }

    private static async Task<string> GetBillNoAsync(IDbConnection con, string moduleCode, int moduleRefId)
    {
        if (moduleCode == "LAB")
            return await con.QuerySingleOrDefaultAsync<string>(
                "SELECT ISNULL(BillNo, '') FROM dbo.LabOrder WHERE LabOrderId = @Id", new { Id = moduleRefId }) ?? string.Empty;

        return await con.QuerySingleOrDefaultAsync<string>(
            "SELECT ISNULL(OPDBillNo, '') FROM dbo.PatientOPDService WHERE OPDServiceId = @Id", new { Id = moduleRefId }) ?? string.Empty;
    }

    private static BillCancellationResponseDto Fail(string error) => new() { Success = false, Error = error };
    private static BillRefundResponseDto FailRefund(string error) => new() { Success = false, Error = error };
}
