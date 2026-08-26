using System;
using System.Data;
using System.Threading.Tasks;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.DTOs;

namespace EMR.Web.Services;

public class LedgerService(IDbConnectionFactory db) : ILedgerService
{
    public async Task<long> PostLedgerEntryAsync(LedgerEntryDto entry)
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

        return p.Get<long>("@NewTransactionId");
    }

    public async Task PostOpdBillLedgerAsync(int opdServiceId, decimal totalAmount, int? branchId, int? companyId, int? userId, string billNo)
    {
        if (totalAmount <= 0) return; // No entry needed for zero bills

        using var con = db.CreateConnection();

        // 1. Fetch required IDs for the ledgers and voucher
        int? voucherTypeId = await con.QueryFirstOrDefaultAsync<int?>("SELECT VoucherTypeId FROM Acc_VoucherType WHERE VoucherTypeName = 'Sales'");
        int? debitLedgerId = await con.QueryFirstOrDefaultAsync<int?>("SELECT LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'");
        int? creditLedgerId = await con.QueryFirstOrDefaultAsync<int?>("SELECT LedgerId FROM Acc_LedgerMaster WHERE LedgerName = 'OPD Revenue'");

        if (voucherTypeId == null || debitLedgerId == null || creditLedgerId == null)
        {
            // Note: In production, consider throwing or logging if account configuration is missing
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
}
