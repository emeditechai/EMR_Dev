using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;
using Microsoft.Data.SqlClient;

namespace EMR.Web.Services;

/// <summary>
/// Utility > Accounts (SQLScripts/2244 - 2246): petty cash, manual vouchers, ledgers and the ledger reports. Every
/// write goes through a stored procedure that checks the rules and posts the ledger; the reads are plain queries.
/// A rule broken in a procedure comes back as a SqlException numbered 53000+: <see cref="UserMessage"/> turns it
/// into the text to show.
/// </summary>
public interface IAccountsService
{
    // lookups
    Task<List<AccOption>> GetBranchesAsync(int companyId);
    Task<List<AccOption>> GetUsersAsync(int companyId);
    Task<List<AccOption>> GetVoucherTypesAsync(bool manualOnly);
    Task<List<string>> GetPaymentModesAsync(int companyId);
    Task<AccSettingsDto> GetSettingsAsync(int companyId);
    Task SaveSettingsAsync(AccSettingsDto s, int userId);
    Task<List<AccBranchLockDto>> GetBranchLocksAsync(int companyId, int? branchId);
    Task SaveBranchLockAsync(int companyId, int branchId, DateTime? lockedUpTo, int userId);

    // masters
    Task<List<AccLedgerGroupDto>> GetLedgerGroupsAsync();
    Task<List<AccLedgerDto>> GetLedgersAsync(string? search = null, int? groupId = null, string? ledgerType = null, bool activeOnly = false);
    Task<int> SaveLedgerGroupAsync(AccLedgerGroupForm f, int userId);
    Task<int> SaveLedgerAsync(AccLedgerForm f, int userId);
    Task<List<AccExpenseHeadDto>> GetExpenseHeadsAsync(int companyId, bool activeOnly = false);
    Task<int> SaveExpenseHeadAsync(AccExpenseHeadForm f, int companyId, int userId);
    Task<List<AccPayeeDto>> GetPayeesAsync(int companyId, bool activeOnly = false, string? search = null);
    Task<int> SavePayeeAsync(AccPayeeDto f, int companyId, int userId);

    // attachments (bill scans) of a petty expense ("PETTY_EXP") or a manual voucher ("VOUCHER")
    Task<List<AccAttachmentDto>> GetAttachmentsAsync(int companyId, string refType, int refId);
    Task<AccAttachmentDto?> GetAttachmentAsync(int companyId, int attachmentId);
    Task<int> AddAttachmentAsync(int companyId, AccAttachmentDto a, int userId);
    Task DeleteAttachmentAsync(int companyId, int attachmentId, int userId);

    // petty cash
    Task<List<AccCounterDto>> GetCountersAsync(int companyId, int? branchId, bool activeOnly = false);
    Task<AccCounterDto?> GetCounterAsync(int companyId, int counterId);
    Task<int> SaveCounterAsync(AccCounterForm f, int companyId, int userId);
    Task<string?> SaveFloatAsync(AccFloatForm f, int userId);
    Task<List<AccFloatDto>> GetFloatHistoryAsync(int counterId);
    Task<List<AccPettyExpenseDto>> GetPettyExpensesAsync(int companyId, int? branchId, DateTime from, DateTime to, int? counterId, string? status, string? search);
    Task<AccPettyExpenseDto?> GetPettyExpenseAsync(int companyId, int expenseId);
    Task<(int ExpenseId, string Status, string? VoucherNo)> SavePettyExpenseAsync(AccPettyExpenseForm f, int companyId, int userId);
    Task ApprovePettyExpenseAsync(int expenseId, int companyId, int userId);
    Task RejectPettyExpenseAsync(int expenseId, int companyId, string? reason, int userId);
    Task CancelPettyExpenseAsync(int expenseId, int companyId, string? reason, int userId);
    Task<List<AccClosingDto>> GetClosingsAsync(int companyId, int? branchId, int? counterId);
    Task<decimal> GetCounterBookBalanceAsync(int counterId, DateTime date);
    Task<(decimal BookBalance, decimal Difference)> SaveClosingAsync(AccClosingForm f, int userId);

    // manual vouchers
    Task<List<AccVoucherDto>> GetVouchersAsync(int companyId, int? branchId, DateTime from, DateTime to, string? typeCode, string? status, string? search);
    Task<AccVoucherDto?> GetVoucherAsync(int companyId, int voucherId);
    Task<(int VoucherId, string Status, string? VoucherNo)> SaveVoucherAsync(AccVoucherForm f, int companyId, int userId);
    Task VoucherActionAsync(int voucherId, int companyId, string action, string? reason, int userId);

    // reports
    Task<(AccStatementHeader? Header, List<AccStatementRow> Rows)> GetLedgerStatementAsync(int ledgerId, DateTime from, DateTime to, int? branchId);
    Task<List<AccDayBookRow>> GetDayBookAsync(DateTime from, DateTime to, int? branchId, int? voucherTypeId, bool manualOnly);
    Task<(List<AccTrialRow> Rows, int Unbalanced)> GetTrialBalanceAsync(DateTime from, DateTime to, int? branchId);
    Task<List<AccExpenseSummaryRow>> GetExpenseSummaryAsync(int companyId, DateTime from, DateTime to, int? branchId, int? counterId);
    Task<List<AccDayBookRow>> GetTransactionAsync(long transactionId);
    Task<(List<AccAuditIssueRow> Issues, List<AccAuditSummaryRow> Summary)> GetPostingAuditAsync(int companyId, DateTime from, DateTime to, int? branchId);
}

public class AccountsService(IDbConnectionFactory db) : IAccountsService
{
    private const CommandType Sp = CommandType.StoredProcedure;
    private const string UserName = "ISNULL(NULLIF(LTRIM(RTRIM({0}.FullName)), ''), {0}.Username)";
    private static string U(string alias) => string.Format(UserName, alias);

    /// <summary>The text of a rule broken in a procedure (THROW 53000+), or a neutral message for anything else.</summary>
    public static string UserMessage(Exception ex, string fallback = "The request could not be completed. Please try again.")
        => ex is SqlException { Number: >= 50000 } sql ? sql.Message : fallback;

    // ── Lookups ───────────────────────────────────────────────────────────────
    public async Task<List<AccOption>> GetBranchesAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccOption>(
            "SELECT BranchID AS Id, BranchName AS Name, BranchCode AS Extra FROM dbo.Branchmaster WHERE IsActive = 1 AND ISNULL(CompanyId, 1) = @companyId ORDER BY BranchName",
            new { companyId })).ToList();
    }

    public async Task<List<AccOption>> GetUsersAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccOption>(
            $"SELECT u.Id, {U("u")} AS Name FROM dbo.Users u WHERE u.IsActive = 1 AND ISNULL(u.CompanyId, 1) = @companyId ORDER BY 2", new { companyId })).ToList();
    }

    public async Task<List<AccOption>> GetVoucherTypesAsync(bool manualOnly)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccOption>(
            "SELECT VoucherTypeId AS Id, VoucherTypeName AS Name, VoucherTypeCode AS Extra FROM dbo.Acc_VoucherType WHERE IsActive = 1 AND (@manualOnly = 0 OR IsManual = 1) ORDER BY VoucherTypeName",
            new { manualOnly })).ToList();
    }

    public async Task<List<string>> GetPaymentModesAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<string>(
            "SELECT MethodName FROM dbo.PaymentMethodMaster WHERE IsActive = 1 AND ISNULL(CompanyId, 1) = @companyId ORDER BY DisplayOrder", new { companyId })).ToList();
    }

    public async Task<AccSettingsDto> GetSettingsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<AccSettingsDto>("SELECT * FROM dbo.Acc_Settings WHERE CompanyId = @companyId", new { companyId })
               ?? new AccSettingsDto { CompanyId = companyId };
    }

    public async Task SaveSettingsAsync(AccSettingsDto s, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Acc_Settings_Save", new
        {
            s.CompanyId, s.PettyApprovalRequired, s.PettyAutoApproveLimit, s.PettyMaxPerVoucher, s.AllowPettyOverdraw, s.AllowSelfApproval,
            s.VoucherApprovalRequired, s.BackDateDays, s.FinancialYearStartMonth, s.PettyGstInputCredit, UserId = userId
        }, commandType: Sp);
    }

    public async Task<List<AccBranchLockDto>> GetBranchLocksAsync(int companyId, int? branchId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccBranchLockDto>($@"
            SELECT b.BranchID AS BranchId, b.BranchName, k.LockedUpTo, {U("u")} AS ModifiedByName, k.ModifiedDate
            FROM dbo.Branchmaster b
            LEFT JOIN dbo.Acc_BranchLock k ON k.BranchId = b.BranchID AND k.CompanyId = @companyId
            LEFT JOIN dbo.Users u ON u.Id = k.ModifiedBy
            WHERE b.IsActive = 1 AND ISNULL(b.CompanyId, 1) = @companyId AND (@branchId IS NULL OR b.BranchID = @branchId)
            ORDER BY b.BranchName", new { companyId, branchId })).ToList();
    }

    public async Task SaveBranchLockAsync(int companyId, int branchId, DateTime? lockedUpTo, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Acc_BranchLock_Save", new { CompanyId = companyId, BranchId = branchId, LockedUpTo = lockedUpTo?.Date, UserId = userId }, commandType: Sp);
    }

    // ── Masters ───────────────────────────────────────────────────────────────
    public async Task<List<AccLedgerGroupDto>> GetLedgerGroupsAsync()
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccLedgerGroupDto>(@"
            SELECT g.LedgerGroupId, g.GroupName, g.ParentGroupId, p.GroupName AS ParentGroupName, g.GroupType, g.IsActive, g.IsSystem,
                   (SELECT COUNT(*) FROM dbo.Acc_LedgerMaster l WHERE l.LedgerGroupId = g.LedgerGroupId) AS LedgerCount
            FROM dbo.Acc_LedgerGroup g LEFT JOIN dbo.Acc_LedgerGroup p ON p.LedgerGroupId = g.ParentGroupId
            ORDER BY CASE g.GroupType WHEN 'Asset' THEN 1 WHEN 'Liability' THEN 2 WHEN 'Income' THEN 3 ELSE 4 END, g.GroupName")).ToList();
    }

    public async Task<List<AccLedgerDto>> GetLedgersAsync(string? search = null, int? groupId = null, string? ledgerType = null, bool activeOnly = false)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccLedgerDto>(@"
            SELECT l.LedgerId, l.LedgerCode, l.LedgerName, l.LedgerGroupId, g.GroupName, g.GroupType, l.LedgerType, l.OpeningBalance, l.OpeningBalanceType,
                   l.IsActive, l.IsSystem, l.Remarks, dbo.fn_Acc_LedgerBalance(l.LedgerId, NULL) AS Balance
            FROM dbo.Acc_LedgerMaster l JOIN dbo.Acc_LedgerGroup g ON g.LedgerGroupId = l.LedgerGroupId
            WHERE (@activeOnly = 0 OR l.IsActive = 1) AND (@groupId IS NULL OR l.LedgerGroupId = @groupId) AND (@ledgerType IS NULL OR l.LedgerType = @ledgerType)
              AND (@search IS NULL OR l.LedgerName LIKE '%' + @search + '%' OR l.LedgerCode LIKE '%' + @search + '%')
            ORDER BY l.LedgerName",
            new { search = Blank(search), groupId, ledgerType = Blank(ledgerType), activeOnly })).ToList();
    }

    public async Task<int> SaveLedgerGroupAsync(AccLedgerGroupForm f, int userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>("dbo.usp_Acc_LedgerGroup_Save",
            new { f.LedgerGroupId, f.GroupName, f.GroupType, f.ParentGroupId, f.IsActive, UserId = userId }, commandType: Sp);
    }

    public async Task<int> SaveLedgerAsync(AccLedgerForm f, int userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>("dbo.usp_Acc_Ledger_Save",
            new { f.LedgerId, f.LedgerName, f.LedgerGroupId, f.LedgerType, f.OpeningBalance, f.OpeningBalanceType, f.Remarks, f.IsActive, UserId = userId }, commandType: Sp);
    }

    public async Task<List<AccExpenseHeadDto>> GetExpenseHeadsAsync(int companyId, bool activeOnly = false)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccExpenseHeadDto>(@"
            SELECT h.ExpenseHeadId, h.HeadName, h.LedgerId, l.LedgerName, h.MaxPerVoucher, h.BillRequiredAbove, h.IsActive
            FROM dbo.Acc_ExpenseHead h JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = h.LedgerId
            WHERE h.CompanyId = @companyId AND (@activeOnly = 0 OR h.IsActive = 1) ORDER BY h.HeadName", new { companyId, activeOnly })).ToList();
    }

    public async Task<int> SaveExpenseHeadAsync(AccExpenseHeadForm f, int companyId, int userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>("dbo.usp_Acc_ExpenseHead_Save",
            new { f.ExpenseHeadId, CompanyId = companyId, f.HeadName, f.LedgerId, f.MaxPerVoucher, f.BillRequiredAbove, f.IsActive, UserId = userId }, commandType: Sp);
    }

    public async Task<List<AccPayeeDto>> GetPayeesAsync(int companyId, bool activeOnly = false, string? search = null)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccPayeeDto>(@"
            SELECT p.PayeeId, p.PayeeName, p.Phone, p.GSTIN, p.PAN, p.DefaultExpenseHeadId, h.HeadName AS DefaultHeadName, p.Remarks, p.IsActive
            FROM dbo.Acc_Payee p LEFT JOIN dbo.Acc_ExpenseHead h ON h.ExpenseHeadId = p.DefaultExpenseHeadId
            WHERE p.CompanyId = @companyId AND (@activeOnly = 0 OR p.IsActive = 1)
              AND (@search IS NULL OR p.PayeeName LIKE '%' + @search + '%' OR p.Phone LIKE '%' + @search + '%' OR p.GSTIN LIKE '%' + @search + '%')
            ORDER BY p.PayeeName", new { companyId, activeOnly, search = Blank(search) })).ToList();
    }

    public async Task<int> SavePayeeAsync(AccPayeeDto f, int companyId, int userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>("dbo.usp_Acc_Payee_Save", new
        {
            f.PayeeId, CompanyId = companyId, f.PayeeName, f.Phone, f.GSTIN, f.PAN, f.DefaultExpenseHeadId, f.Remarks, f.IsActive, UserId = userId
        }, commandType: Sp);
    }

    // ── Attachments ───────────────────────────────────────────────────────────
    private static readonly string AttachmentSql = $@"
        SELECT a.AttachmentId, a.RefType, a.RefId, a.FileName, a.StoredName, a.ContentType, a.SizeBytes, {U("u")} AS CreatedByName, a.CreatedDate
        FROM dbo.Acc_Attachment a LEFT JOIN dbo.Users u ON u.Id = a.CreatedBy
        WHERE a.CompanyId = @companyId AND a.IsDeleted = 0";

    public async Task<List<AccAttachmentDto>> GetAttachmentsAsync(int companyId, string refType, int refId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccAttachmentDto>(AttachmentSql + " AND a.RefType = @refType AND a.RefId = @refId ORDER BY a.AttachmentId", new { companyId, refType, refId })).ToList();
    }

    public async Task<AccAttachmentDto?> GetAttachmentAsync(int companyId, int attachmentId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<AccAttachmentDto>(AttachmentSql + " AND a.AttachmentId = @attachmentId", new { companyId, attachmentId });
    }

    public async Task<int> AddAttachmentAsync(int companyId, AccAttachmentDto a, int userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO dbo.Acc_Attachment (CompanyId, RefType, RefId, FileName, StoredName, ContentType, SizeBytes, CreatedBy)
            VALUES (@companyId, @RefType, @RefId, @FileName, @StoredName, @ContentType, @SizeBytes, @userId);
            SELECT CAST(SCOPE_IDENTITY() AS INT);", new { companyId, a.RefType, a.RefId, a.FileName, a.StoredName, a.ContentType, a.SizeBytes, userId });
    }

    /// <summary>Soft delete: the row and the file stay, so the audit trail of a bill is never lost.</summary>
    public async Task DeleteAttachmentAsync(int companyId, int attachmentId, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("UPDATE dbo.Acc_Attachment SET IsDeleted = 1, DeletedBy = @userId, DeletedDate = GETDATE() WHERE AttachmentId = @attachmentId AND CompanyId = @companyId",
            new { companyId, attachmentId, userId });
    }

    // ── Petty cash ────────────────────────────────────────────────────────────
    private static readonly string CounterSql = $@"
        SELECT c.CounterId, c.BranchId, b.BranchName, c.CounterName, c.CustodianUserId, {U("u")} AS CustodianName, c.FloatAmount, c.LedgerId, l.LedgerName,
               c.FundingLedgerId, fl.LedgerName AS FundingLedgerName, c.LowBalanceAlert, c.IsActive,
               dbo.fn_Acc_LedgerBalance(c.LedgerId, NULL) AS Balance,
               ISNULL((SELECT SUM(e.TotalAmount) FROM dbo.Acc_PettyExpense e WHERE e.CounterId = c.CounterId AND e.Status = 'S'), 0) AS PendingAmount,
               (SELECT MAX(x.ClosingDate) FROM dbo.Acc_PettyCashClosing x WHERE x.CounterId = c.CounterId) AS LastClosingDate
        FROM dbo.Acc_PettyCashCounter c
        JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
        JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = c.LedgerId
        LEFT JOIN dbo.Acc_LedgerMaster fl ON fl.LedgerId = c.FundingLedgerId
        LEFT JOIN dbo.Users u ON u.Id = c.CustodianUserId
        WHERE c.CompanyId = @companyId";

    public async Task<List<AccCounterDto>> GetCountersAsync(int companyId, int? branchId, bool activeOnly = false)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccCounterDto>(CounterSql + " AND (@branchId IS NULL OR c.BranchId = @branchId) AND (@activeOnly = 0 OR c.IsActive = 1) ORDER BY b.BranchName, c.CounterName",
            new { companyId, branchId, activeOnly })).ToList();
    }

    public async Task<AccCounterDto?> GetCounterAsync(int companyId, int counterId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<AccCounterDto>(CounterSql + " AND c.CounterId = @counterId", new { companyId, counterId });
    }

    public async Task<int> SaveCounterAsync(AccCounterForm f, int companyId, int userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>("dbo.usp_Acc_PettyCounter_Save", new
        {
            f.CounterId, CompanyId = companyId, f.BranchId, f.CounterName, f.CustodianUserId, f.FloatAmount, f.FundingLedgerId, f.LowBalanceAlert, f.IsActive, UserId = userId
        }, commandType: Sp);
    }

    public async Task<string?> SaveFloatAsync(AccFloatForm f, int userId)
    {
        using var con = db.CreateConnection();
        var row = await con.QuerySingleOrDefaultAsync<(int FloatId, string? VoucherNo)>("dbo.usp_Acc_PettyCash_Float", new
        {
            f.CounterId, f.Kind, TxnDate = f.TxnDate.Date, f.Amount, f.SourceLedgerId, f.ReferenceNo, f.Remarks, UserId = userId
        }, commandType: Sp);
        return row.VoucherNo;
    }

    public async Task<List<AccFloatDto>> GetFloatHistoryAsync(int counterId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccFloatDto>($@"
            SELECT TOP 100 f.FloatId, f.Kind, f.TxnDate, f.Amount, l.LedgerName AS SourceLedgerName, f.ReferenceNo, f.Remarks, f.VoucherNo, {U("u")} AS CreatedByName, f.CreatedDate
            FROM dbo.Acc_PettyCashFloat f JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = f.SourceLedgerId LEFT JOIN dbo.Users u ON u.Id = f.CreatedBy
            WHERE f.CounterId = @counterId ORDER BY f.FloatId DESC", new { counterId })).ToList();
    }

    private static readonly string ExpenseSql = $@"
        SELECT e.ExpenseId, e.BranchId, b.BranchName, e.CounterId, c.CounterName, e.ExpenseDate, e.PayeeName, e.BillNo, e.BillDate, e.TotalAmount, e.Narration,
               e.Status, e.TransactionId, e.VoucherNo, e.CreatedBy, {U("cu")} AS CreatedByName, e.CreatedDate, {U("au")} AS ApprovedByName, e.ApprovedDate,
               e.IsAutoApproved, {U("ru")} AS RejectedByName, e.RejectedDate, e.RejectReason, {U("xu")} AS CancelledByName, e.CancelledDate, e.CancelReason,
               (SELECT STRING_AGG(h.HeadName, ', ') FROM dbo.Acc_PettyExpenseLine l JOIN dbo.Acc_ExpenseHead h ON h.ExpenseHeadId = l.ExpenseHeadId WHERE l.ExpenseId = e.ExpenseId) AS Heads,
               (SELECT COUNT(*) FROM dbo.Acc_Attachment a WHERE a.RefType = 'PETTY_EXP' AND a.RefId = e.ExpenseId AND a.IsDeleted = 0) AS AttachmentCount
        FROM dbo.Acc_PettyExpense e
        JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = e.CounterId
        JOIN dbo.Branchmaster b ON b.BranchID = e.BranchId
        LEFT JOIN dbo.Users cu ON cu.Id = e.CreatedBy
        LEFT JOIN dbo.Users au ON au.Id = e.ApprovedBy
        LEFT JOIN dbo.Users ru ON ru.Id = e.RejectedBy
        LEFT JOIN dbo.Users xu ON xu.Id = e.CancelledBy
        WHERE e.CompanyId = @companyId";

    public async Task<List<AccPettyExpenseDto>> GetPettyExpensesAsync(int companyId, int? branchId, DateTime from, DateTime to, int? counterId, string? status, string? search)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccPettyExpenseDto>(ExpenseSql + @"
              AND e.ExpenseDate BETWEEN @from AND @to AND (@branchId IS NULL OR e.BranchId = @branchId) AND (@counterId IS NULL OR e.CounterId = @counterId)
              AND (@status IS NULL OR e.Status = @status)
              AND (@search IS NULL OR e.PayeeName LIKE '%' + @search + '%' OR e.VoucherNo LIKE '%' + @search + '%' OR e.BillNo LIKE '%' + @search + '%' OR e.Narration LIKE '%' + @search + '%')
            ORDER BY e.ExpenseDate DESC, e.ExpenseId DESC",
            new { companyId, branchId, from = from.Date, to = to.Date, counterId, status = Blank(status), search = Blank(search) })).ToList();
    }

    public async Task<AccPettyExpenseDto?> GetPettyExpenseAsync(int companyId, int expenseId)
    {
        using var con = db.CreateConnection();
        var e = await con.QuerySingleOrDefaultAsync<AccPettyExpenseDto>(ExpenseSql + " AND e.ExpenseId = @expenseId", new { companyId, expenseId });
        if (e is null) return null;
        e.Lines = (await con.QueryAsync<AccPettyExpenseLineDto>(@"
            SELECT l.ExpenseHeadId, h.HeadName, l.Amount, l.GstAmount, l.Remarks FROM dbo.Acc_PettyExpenseLine l JOIN dbo.Acc_ExpenseHead h ON h.ExpenseHeadId = l.ExpenseHeadId
            WHERE l.ExpenseId = @expenseId ORDER BY l.LineId", new { expenseId })).ToList();
        e.Attachments = await GetAttachmentsAsync(companyId, "PETTY_EXP", expenseId);
        return e;
    }

    public async Task<(int ExpenseId, string Status, string? VoucherNo)> SavePettyExpenseAsync(AccPettyExpenseForm f, int companyId, int userId)
    {
        using var con = db.CreateConnection();
        var lines = JsonSerializer.Serialize(f.Lines.Select(l => new { l.ExpenseHeadId, l.Amount, l.GstAmount, l.Remarks }));
        return await con.QuerySingleAsync<(int, string, string?)>("dbo.usp_Acc_PettyExpense_Save", new
        {
            f.ExpenseId, CompanyId = companyId, f.CounterId, ExpenseDate = f.ExpenseDate.Date, f.PayeeName, f.BillNo, BillDate = f.BillDate?.Date, f.Narration,
            LinesJson = lines, UserId = userId
        }, commandType: Sp);
    }

    public async Task ApprovePettyExpenseAsync(int expenseId, int companyId, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Acc_PettyExpense_Approve", new { ExpenseId = expenseId, CompanyId = companyId, UserId = userId }, commandType: Sp);
    }

    public async Task RejectPettyExpenseAsync(int expenseId, int companyId, string? reason, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Acc_PettyExpense_Reject", new { ExpenseId = expenseId, CompanyId = companyId, Reason = reason, UserId = userId }, commandType: Sp);
    }

    public async Task CancelPettyExpenseAsync(int expenseId, int companyId, string? reason, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Acc_PettyExpense_Cancel", new { ExpenseId = expenseId, CompanyId = companyId, Reason = reason, UserId = userId }, commandType: Sp);
    }

    public async Task<List<AccClosingDto>> GetClosingsAsync(int companyId, int? branchId, int? counterId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccClosingDto>($@"
            SELECT TOP 200 x.ClosingId, x.CounterId, c.CounterName, b.BranchName, x.ClosingDate, x.BookBalance, x.CountedCash, x.Difference, x.Remarks, t.VoucherNo,
                   {U("u")} AS CreatedByName, x.CreatedDate
            FROM dbo.Acc_PettyCashClosing x
            JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = x.CounterId
            JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
            LEFT JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = x.TransactionId
            LEFT JOIN dbo.Users u ON u.Id = x.CreatedBy
            WHERE c.CompanyId = @companyId AND (@branchId IS NULL OR c.BranchId = @branchId) AND (@counterId IS NULL OR x.CounterId = @counterId)
            ORDER BY x.ClosingDate DESC, x.ClosingId DESC", new { companyId, branchId, counterId })).ToList();
    }

    public async Task<decimal> GetCounterBookBalanceAsync(int counterId, DateTime date)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<decimal>(
            "SELECT dbo.fn_Acc_LedgerBalance(LedgerId, @date) FROM dbo.Acc_PettyCashCounter WHERE CounterId = @counterId", new { counterId, date = date.Date });
    }

    public async Task<(decimal BookBalance, decimal Difference)> SaveClosingAsync(AccClosingForm f, int userId)
    {
        using var con = db.CreateConnection();
        var row = await con.QuerySingleAsync<(int ClosingId, decimal BookBalance, decimal Difference)>("dbo.usp_Acc_PettyCash_Close", new
        {
            f.CounterId, ClosingDate = f.ClosingDate.Date, f.CountedCash, f.DenominationJson, f.Remarks, UserId = userId
        }, commandType: Sp);
        return (row.BookBalance, row.Difference);
    }

    // ── Manual vouchers ───────────────────────────────────────────────────────
    private static readonly string VoucherSql = $@"
        SELECT v.VoucherId, v.BranchId, b.BranchName, t.VoucherTypeCode, t.VoucherTypeName, v.VoucherDate, v.PayeeName, v.PaymentMode, v.InstrumentNo, v.InstrumentDate,
               v.Narration, v.TotalAmount, v.Status, v.TransactionId, v.VoucherNo, v.CreatedBy, {U("cu")} AS CreatedByName, v.CreatedDate,
               {U("au")} AS ApprovedByName, v.ApprovedDate, v.RejectReason, {U("xu")} AS CancelledByName, v.CancelledDate, v.CancelReason
        FROM dbo.Acc_Voucher v
        JOIN dbo.Acc_VoucherType t ON t.VoucherTypeId = v.VoucherTypeId
        JOIN dbo.Branchmaster b ON b.BranchID = v.BranchId
        LEFT JOIN dbo.Users cu ON cu.Id = v.CreatedBy
        LEFT JOIN dbo.Users au ON au.Id = v.ApprovedBy
        LEFT JOIN dbo.Users xu ON xu.Id = v.CancelledBy
        WHERE v.CompanyId = @companyId";

    public async Task<List<AccVoucherDto>> GetVouchersAsync(int companyId, int? branchId, DateTime from, DateTime to, string? typeCode, string? status, string? search)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccVoucherDto>(VoucherSql + @"
              AND v.VoucherDate BETWEEN @from AND @to AND (@branchId IS NULL OR v.BranchId = @branchId) AND (@typeCode IS NULL OR t.VoucherTypeCode = @typeCode)
              AND (@status IS NULL OR v.Status = @status)
              AND (@search IS NULL OR v.PayeeName LIKE '%' + @search + '%' OR v.VoucherNo LIKE '%' + @search + '%' OR v.Narration LIKE '%' + @search + '%' OR v.InstrumentNo LIKE '%' + @search + '%')
            ORDER BY v.VoucherDate DESC, v.VoucherId DESC",
            new { companyId, branchId, from = from.Date, to = to.Date, typeCode = Blank(typeCode), status = Blank(status), search = Blank(search) })).ToList();
    }

    public async Task<AccVoucherDto?> GetVoucherAsync(int companyId, int voucherId)
    {
        using var con = db.CreateConnection();
        var v = await con.QuerySingleOrDefaultAsync<AccVoucherDto>(VoucherSql + " AND v.VoucherId = @voucherId", new { companyId, voucherId });
        if (v is null) return null;
        v.Lines = (await con.QueryAsync<AccVoucherLineDto>(@"
            SELECT l.LedgerId, m.LedgerName, l.DebitAmount, l.CreditAmount, l.Narration FROM dbo.Acc_VoucherLine l JOIN dbo.Acc_LedgerMaster m ON m.LedgerId = l.LedgerId
            WHERE l.VoucherId = @voucherId ORDER BY l.LineId", new { voucherId })).ToList();
        v.Attachments = await GetAttachmentsAsync(companyId, "VOUCHER", voucherId);
        return v;
    }

    public async Task<(int VoucherId, string Status, string? VoucherNo)> SaveVoucherAsync(AccVoucherForm f, int companyId, int userId)
    {
        using var con = db.CreateConnection();
        var lines = JsonSerializer.Serialize(f.Lines.Select(l => new { l.LedgerId, Dr = l.DebitAmount, Cr = l.CreditAmount, l.Narration }));
        return await con.QuerySingleAsync<(int, string, string?)>("dbo.usp_Acc_Voucher_Save", new
        {
            CompanyId = companyId, f.BranchId, f.VoucherTypeCode, VoucherDate = f.VoucherDate.Date, f.PayeeName, f.PaymentMode, f.InstrumentNo,
            InstrumentDate = f.InstrumentDate?.Date, f.Narration, LinesJson = lines, UserId = userId
        }, commandType: Sp);
    }

    public async Task VoucherActionAsync(int voucherId, int companyId, string action, string? reason, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Acc_Voucher_Action", new { VoucherId = voucherId, CompanyId = companyId, Action = action, Reason = reason, UserId = userId }, commandType: Sp);
    }

    // ── Reports ───────────────────────────────────────────────────────────────
    public async Task<(AccStatementHeader? Header, List<AccStatementRow> Rows)> GetLedgerStatementAsync(int ledgerId, DateTime from, DateTime to, int? branchId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("dbo.usp_AccRpt_LedgerStatement",
            new { LedgerId = ledgerId, FromDate = from.Date, ToDate = to.Date, BranchId = branchId }, commandType: Sp);
        var header = await multi.ReadSingleOrDefaultAsync<AccStatementHeader>();
        var rows = (await multi.ReadAsync<AccStatementRow>()).ToList();
        var running = header?.OpeningBalance ?? 0;
        foreach (var r in rows)
        {
            running += r.DebitAmount - r.CreditAmount;
            r.RunningBalance = running;
        }
        return (header, rows);
    }

    public async Task<List<AccDayBookRow>> GetDayBookAsync(DateTime from, DateTime to, int? branchId, int? voucherTypeId, bool manualOnly)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccDayBookRow>("dbo.usp_AccRpt_DayBook",
            new { FromDate = from.Date, ToDate = to.Date, BranchId = branchId, VoucherTypeId = voucherTypeId, ManualOnly = manualOnly }, commandType: Sp)).ToList();
    }

    public async Task<(List<AccTrialRow> Rows, int Unbalanced)> GetTrialBalanceAsync(DateTime from, DateTime to, int? branchId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("dbo.usp_AccRpt_TrialBalance", new { FromDate = from.Date, ToDate = to.Date, BranchId = branchId }, commandType: Sp);
        var rows = (await multi.ReadAsync<AccTrialRow>()).ToList();
        var unbalanced = await multi.ReadSingleAsync<int>();
        return (rows, unbalanced);
    }

    public async Task<List<AccExpenseSummaryRow>> GetExpenseSummaryAsync(int companyId, DateTime from, DateTime to, int? branchId, int? counterId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccExpenseSummaryRow>("dbo.usp_AccRpt_ExpenseSummary",
            new { CompanyId = companyId, FromDate = from.Date, ToDate = to.Date, BranchId = branchId, CounterId = counterId }, commandType: Sp)).ToList();
    }

    /// <summary>One ledger entry with its lines (any voucher, billing entries included) - the drill-down of the reports.</summary>
    public async Task<List<AccDayBookRow>> GetTransactionAsync(long transactionId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AccDayBookRow>($@"
            SELECT t.TransactionId, t.TransactionDate, t.VoucherNo, v.VoucherTypeName, v.VoucherTypeCode, b.BranchName, t.PayeeName, t.PaymentMode, t.InstrumentNo,
                   t.Narration AS VoucherNarration, t.TotalAmount, t.Status, CAST(CASE WHEN t.ReversalOfTransactionId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsReversal,
                   t.ReferenceType, t.ReferenceId, {U("u")} AS EnteredBy, l.LedgerName, d.DebitAmount, d.CreditAmount
            FROM dbo.Acc_LedgerTransaction t
            JOIN dbo.Acc_VoucherType v ON v.VoucherTypeId = t.VoucherTypeId
            JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId
            JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = d.LedgerId
            LEFT JOIN dbo.Branchmaster b ON b.BranchID = t.BranchId
            LEFT JOIN dbo.Users u ON u.Id = t.CreatedBy
            WHERE t.TransactionId = @transactionId
            ORDER BY CASE WHEN d.DebitAmount > 0 THEN 0 ELSE 1 END, d.TransactionDetailId", new { transactionId })).ToList();
    }

    public async Task<(List<AccAuditIssueRow> Issues, List<AccAuditSummaryRow> Summary)> GetPostingAuditAsync(int companyId, DateTime from, DateTime to, int? branchId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("dbo.usp_AccRpt_PostingAudit",
            new { CompanyId = companyId, FromDate = from.Date, ToDate = to.Date, BranchId = branchId }, commandType: Sp, commandTimeout: 120);
        return ((await multi.ReadAsync<AccAuditIssueRow>()).ToList(), (await multi.ReadAsync<AccAuditSummaryRow>()).ToList());
    }

    private static string? Blank(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
}
