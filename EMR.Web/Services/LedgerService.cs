using System;
using System.Data;
using System.Threading.Tasks;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.DTOs;
using Microsoft.Extensions.Logging;

namespace EMR.Web.Services;

public class LedgerService(IDbConnectionFactory db, ILogger<LedgerService> logger) : ILedgerService
{
    public async Task<long> PostLedgerEntryAsync(LedgerEntryDto entry)
    {
        try
        {
            using var con = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@VoucherTypeId", entry.VoucherTypeId);
            p.Add("@TransactionDate", entry.TransactionDate);
            p.Add("@ReferenceType", entry.ReferenceType);
            p.Add("@ReferenceId", entry.ReferenceId);
            p.Add("@BranchId", entry.BranchId);
            p.Add("@CompanyId", entry.CompanyId);
            p.Add("@TotalAmount", entry.TotalAmount);
            p.Add("@Narration", entry.Narration);
            p.Add("@DebitLedgerId", entry.DebitLedgerId);
            p.Add("@CreditLedgerId", entry.CreditLedgerId);
            p.Add("@CreatedBy", entry.CreatedBy);
            
            p.Add("@NewTransactionId", dbType: DbType.Int64, direction: ParameterDirection.Output);

            await con.ExecuteAsync("dbo.usp_Ledger_PostEntry", p, commandType: CommandType.StoredProcedure);

            long txId = p.Get<long>("@NewTransactionId");
            logger.LogInformation("Posted ledger transaction {TxId} for {RefType} #{RefId} (Amount: {Amount:C})", txId, entry.ReferenceType, entry.ReferenceId, entry.TotalAmount);
            return txId;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error posting ledger entry for {RefType} #{RefId}", entry.ReferenceType, entry.ReferenceId);
            throw;
        }
    }

    public async Task PostOpdBillLedgerAsync(int opdServiceId, decimal totalAmount, int? branchId, int? companyId, int? userId, string billNo)
    {
        if (totalAmount <= 0) return; // No entry needed for zero bills

        try
        {
            using var con = db.CreateConnection();

            // 1. Fetch or resolve required IDs for the ledgers and voucher
            int? voucherTypeId = await GetOrCreateVoucherTypeIdAsync(con, "Sales", "SLS");
            int? debitLedgerId = await GetOrCreateLedgerIdAsync(con, "Patient Receivable", "Current Assets", "Asset", "Dr");
            int? creditLedgerId = await GetOrCreateLedgerIdAsync(con, "OPD Revenue", "Direct Income", "Income", "Cr");

            if (voucherTypeId == null || debitLedgerId == null || creditLedgerId == null)
            {
                logger.LogWarning("Missing accounting configuration for OPD bill ledger entry (OpdServiceId: {OpdServiceId})", opdServiceId);
                return;
            }

            // 2. Prepare the DTO
            var dto = new LedgerEntryDto
            {
                VoucherTypeId = voucherTypeId.Value,
                TransactionDate = DateTime.Now,
                ReferenceType = "OPD_BILL",
                ReferenceId = opdServiceId,
                BranchId = branchId,
                CompanyId = companyId,
                TotalAmount = totalAmount,
                Narration = $"Revenue recognized for OPD Bill {billNo}",
                DebitLedgerId = debitLedgerId.Value,
                CreditLedgerId = creditLedgerId.Value,
                CreatedBy = userId
            };

            // 3. Post Entry
            await PostLedgerEntryAsync(dto);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to post OPD bill ledger entry for OpdServiceId {OpdServiceId}", opdServiceId);
        }
    }

    public async Task PostLabBillLedgerAsync(int labOrderId, decimal totalAmount, int? branchId, int? companyId, int? userId, string billNo)
    {
        if (totalAmount <= 0) return;

        try
        {
            using var con = db.CreateConnection();

            int? voucherTypeId = await GetOrCreateVoucherTypeIdAsync(con, "Sales", "SLS");
            int? debitLedgerId = await GetOrCreateLedgerIdAsync(con, "Patient Receivable", "Current Assets", "Asset", "Dr");
            int? creditLedgerId = await GetOrCreateLedgerIdAsync(con, "LAB Revenue", "Direct Income", "Income", "Cr");

            if (voucherTypeId == null || debitLedgerId == null || creditLedgerId == null)
            {
                logger.LogWarning("Missing accounting configuration for LAB bill ledger entry (LabOrderId: {LabOrderId})", labOrderId);
                return;
            }

            var dto = new LedgerEntryDto
            {
                VoucherTypeId = voucherTypeId.Value,
                TransactionDate = DateTime.Now,
                ReferenceType = "LAB_BILL",
                ReferenceId = labOrderId,
                BranchId = branchId,
                CompanyId = companyId,
                TotalAmount = totalAmount,
                Narration = $"Revenue recognized for LAB Bill {billNo}",
                DebitLedgerId = debitLedgerId.Value,
                CreditLedgerId = creditLedgerId.Value,
                CreatedBy = userId
            };

            await PostLedgerEntryAsync(dto);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to post LAB bill ledger entry for LabOrderId {LabOrderId}", labOrderId);
        }
    }

    public async Task PostCancellationReversalAsync(string moduleCode, int moduleRefId, decimal cancelledAmount, int? branchId, int? companyId, int? userId, string billNo, string cancellationNo)
    {
        if (cancelledAmount <= 0) return;

        try
        {
            using var con = db.CreateConnection();

            // Revenue ledger: LAB Revenue or OPD Revenue
            string revenueLedger = moduleCode == "LAB" ? "LAB Revenue" : "OPD Revenue";
            string referenceType  = moduleCode == "LAB" ? "LAB_CANCEL" : "OPD_CANCEL";

            int? voucherTypeId  = await GetOrCreateVoucherTypeIdAsync(con, "Credit Note", "CN");
            // Reversal: Dr Revenue, Cr Receivable (opposite of original bill entry)
            int? debitLedgerId  = await GetOrCreateLedgerIdAsync(con, revenueLedger, "Direct Income", "Income", "Cr");
            int? creditLedgerId = await GetOrCreateLedgerIdAsync(con, "Patient Receivable", "Current Assets", "Asset", "Dr");

            if (voucherTypeId == null || debitLedgerId == null || creditLedgerId == null)
            {
                logger.LogWarning("Missing accounting config for cancellation reversal ({ModuleCode} #{ModuleRefId})", moduleCode, moduleRefId);
                return;
            }

            var dto = new LedgerEntryDto
            {
                VoucherTypeId   = voucherTypeId.Value,
                TransactionDate = DateTime.Now,
                ReferenceType   = referenceType,
                ReferenceId     = moduleRefId,
                BranchId        = branchId,
                CompanyId       = companyId,
                TotalAmount     = cancelledAmount,
                Narration       = $"Cancellation reversal for {moduleCode} Bill {billNo} [{cancellationNo}]",
                DebitLedgerId   = debitLedgerId.Value,
                CreditLedgerId  = creditLedgerId.Value,
                CreatedBy       = userId
            };

            await PostLedgerEntryAsync(dto);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to post cancellation reversal ledger for {ModuleCode} #{ModuleRefId}", moduleCode, moduleRefId);
        }
    }

    private static async Task<int?> GetOrCreateVoucherTypeIdAsync(IDbConnection con, string typeName, string prefix)
    {
        int? id = await con.QueryFirstOrDefaultAsync<int?>("SELECT VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = @typeName", new { typeName });
        if (id.HasValue) return id;

        return await con.QuerySingleAsync<int>(@"
            INSERT INTO Acc_VoucherType (VoucherTypeName, Prefix, IsActive)
            VALUES (@typeName, @prefix, 1);
            SELECT SCOPE_IDENTITY();", new { typeName, prefix });
    }

    private static async Task<int?> GetOrCreateLedgerIdAsync(IDbConnection con, string ledgerName, string groupName, string groupType, string balType)
    {
        int? ledgerId = await con.QueryFirstOrDefaultAsync<int?>("SELECT LedgerId FROM Acc_LedgerMaster WHERE LedgerName = @ledgerName", new { ledgerName });
        if (ledgerId.HasValue) return ledgerId;

        int? groupId = await con.QueryFirstOrDefaultAsync<int?>("SELECT LedgerGroupId FROM Acc_LedgerGroup WHERE GroupName = @groupName OR GroupType = @groupType", new { groupName, groupType });
        if (!groupId.HasValue)
        {
            groupId = await con.QuerySingleAsync<int>(@"
                INSERT INTO Acc_LedgerGroup (GroupName, GroupType, IsActive, CreatedDate)
                VALUES (@groupName, @groupType, 1, GETDATE());
                SELECT SCOPE_IDENTITY();", new { groupName, groupType });
        }

        return await con.QuerySingleAsync<int>(@"
            INSERT INTO Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
            VALUES (@ledgerName, @groupId, 0, @balType, 1, GETDATE());
            SELECT SCOPE_IDENTITY();", new { ledgerName, groupId, balType });
    }
}
