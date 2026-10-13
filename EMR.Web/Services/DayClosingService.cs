using System.Data;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>
/// Cashier Day Closing (SQLScripts/2275): one cash closing per user, module (OPD / LAB), branch and day - the module's
/// receipts and refunds paid, plus the petty cash floats (common to both modules: each float goes into the first closing
/// that takes it). The procedures compute the figures; the page only shows them.
/// </summary>
public interface IDayClosingService
{
    Task<DayClosingSummary> GetSummaryAsync(string module, int branchId, int userId, DateTime businessDate, int? cashClosingId, bool includePetty);
    /// <summary>Earlier days still to close. @module OPD / LAB: that module and the open petty cash (Module PETTY); null: all.</summary>
    Task<List<DayClosingPendingDay>> GetPendingAsync(int userId, int? branchId, string? module = null);
    Task<DayClosingSubmitResult> SubmitAsync(string module, DayClosingSubmitForm form, int branchId, int userId);
    /// <summary>Users holding VERIFY on the module's verification page at the branch (role or user permission; Super Admin).</summary>
    Task<List<DayClosingUser>> GetVerifiersAsync(int branchId, string module);
    Task<bool> CanVerifyAsync(int userId, int branchId, string module);
    Task<List<DayClosingUser>> GetReceiversAsync(int branchId, int userId, string module);
    Task<DayClosingVerifyResult> VerifyAsync(int cashClosingId, string action, string? remarks, int userId);
    Task<(List<DayClosingRow> Closings, List<DayClosingOpenUser> Open)> GetBoardAsync(string module, int branchId, DateTime businessDate);
    Task<(DayClosingRow? Closing, List<DayClosingLine> Lines)> GetAsync(int cashClosingId);
    Task<List<DayClosingRow>> GetMyListAsync(string module, int branchId, int userId);
    /// <summary>Hospital Settings of the branch: billing is refused while earlier days are not closed.</summary>
    Task<bool> BlocksBillingAsync(int branchId);
    /// <summary>Hospital Settings of the branch: a user may verify their own closing.</summary>
    Task<bool> AllowsSelfVerifyAsync(int branchId);
}

public sealed class DayClosingService(IDbConnectionFactory db) : IDayClosingService
{
    private const CommandType Sp = CommandType.StoredProcedure;

    public async Task<DayClosingSummary> GetSummaryAsync(string module, int branchId, int userId, DateTime businessDate, int? cashClosingId, bool includePetty)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_CashClosing_Summary",
            new { BranchId = branchId, UserId = userId, Module = module, BusinessDate = businessDate.Date, CashClosingId = cashClosingId, IncludePetty = includePetty }, commandType: Sp);
        return new DayClosingSummary
        {
            Header = await m.ReadFirstOrDefaultAsync<DayClosingHeader>(),
            Lines = (await m.ReadAsync<DayClosingLine>()).ToList(),
            Transactions = (await m.ReadAsync<DayClosingTxn>()).ToList(),
            Closings = (await m.ReadAsync<DayClosingRow>()).ToList()
        };
    }

    public async Task<List<DayClosingPendingDay>> GetPendingAsync(int userId, int? branchId, string? module = null)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<DayClosingPendingDay>("dbo.usp_CashClosing_Pending", new { UserId = userId, BranchId = branchId, Module = module }, commandType: Sp)).ToList();
    }

    public async Task<DayClosingSubmitResult> SubmitAsync(string module, DayClosingSubmitForm f, int branchId, int userId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<DayClosingSubmitResult>("dbo.usp_CashClosing_Submit", new
        {
            BranchId = branchId, UserId = userId, Module = module, BusinessDate = f.BusinessDate.Date, f.CashClosingId, f.CountedCash, f.DenominationJson,
            f.HandoverMode, f.HandedToUserId, f.HandedAmount, f.RetainedFloat, f.BankReference, f.Remarks, f.IncludePetty
        }, commandType: Sp);
    }

    public async Task<List<DayClosingUser>> GetVerifiersAsync(int branchId, string module)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<DayClosingUser>("dbo.usp_CashClosing_Verifiers", new { BranchId = branchId, Module = module }, commandType: Sp)).ToList();
    }

    public async Task<bool> CanVerifyAsync(int userId, int branchId, string module)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters(new { UserId = userId, BranchId = branchId, Module = module });
        p.Add("Allowed", dbType: DbType.Boolean, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_CashClosing_CanVerify", p, commandType: Sp);
        return p.Get<bool?>("Allowed") ?? false;
    }

    /// <summary>Who the cash can be handed to: active users of the branch, the verifiers first.</summary>
    public async Task<List<DayClosingUser>> GetReceiversAsync(int branchId, int userId, string module)
    {
        using var con = db.CreateConnection();
        var users = (await con.QueryAsync<DayClosingUser>(@"
            SELECT u.Id AS UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName, u.Username AS LoginName
            FROM dbo.Users u
            WHERE u.IsActive = 1 AND u.Id <> @userId
              AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @branchId AND ISNULL(ub.IsActive, 1) = 1)",
            new { branchId, userId })).ToList();
        var verifiers = (await GetVerifiersAsync(branchId, module)).Select(v => v.UserId).ToHashSet();
        users.ForEach(u => u.IsVerifier = verifiers.Contains(u.UserId));
        return users.OrderByDescending(u => u.IsVerifier).ThenBy(u => u.UserName).ToList();
    }

    public async Task<DayClosingVerifyResult> VerifyAsync(int cashClosingId, string action, string? remarks, int userId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<DayClosingVerifyResult>("dbo.usp_CashClosing_Verify",
            new { CashClosingId = cashClosingId, Action = action, Remarks = remarks, UserId = userId }, commandType: Sp);
    }

    public async Task<(List<DayClosingRow> Closings, List<DayClosingOpenUser> Open)> GetBoardAsync(string module, int branchId, DateTime businessDate)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_CashClosing_Board", new { BranchId = branchId, Module = module, BusinessDate = businessDate.Date }, commandType: Sp);
        return ((await m.ReadAsync<DayClosingRow>()).ToList(), (await m.ReadAsync<DayClosingOpenUser>()).ToList());
    }

    public async Task<(DayClosingRow? Closing, List<DayClosingLine> Lines)> GetAsync(int cashClosingId)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_CashClosing_Get", new { CashClosingId = cashClosingId }, commandType: Sp);
        return (await m.ReadFirstOrDefaultAsync<DayClosingRow>(), (await m.ReadAsync<DayClosingLine>()).ToList());
    }

    public async Task<List<DayClosingRow>> GetMyListAsync(string module, int branchId, int userId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<DayClosingRow>("dbo.usp_CashClosing_MyList", new { BranchId = branchId, UserId = userId, Module = module }, commandType: Sp)).ToList();
    }

    public async Task<bool> AllowsSelfVerifyAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<bool?>(
            "SELECT TOP 1 DayClosingAllowSelfVerify FROM dbo.HospitalSettings WHERE BranchId = @branchId ORDER BY IsActive DESC, Id DESC", new { branchId }) ?? false;
    }

    public async Task<bool> BlocksBillingAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<bool?>(
            "SELECT TOP 1 DayClosingBlockBilling FROM dbo.HospitalSettings WHERE BranchId = @branchId ORDER BY IsActive DESC, Id DESC", new { branchId }) ?? false;
    }
}

public sealed class DayClosingSummary
{
    public DayClosingHeader? Header { get; set; }
    public List<DayClosingLine> Lines { get; set; } = [];
    public List<DayClosingTxn> Transactions { get; set; } = [];
    public List<DayClosingRow> Closings { get; set; } = [];
}

public sealed class DayClosingHeader
{
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public int UserId { get; set; }
    public string? Module { get; set; }
    public string? UserName { get; set; }
    public DateTime BusinessDate { get; set; }
    public int SeqNo { get; set; }
    public int? CashClosingId { get; set; }
    public string? Status { get; set; }
    public DateTime? WindowFrom { get; set; }
    public DateTime WindowTo { get; set; }
    public decimal OpeningFloat { get; set; }
    public decimal CashReceipts { get; set; }
    public decimal CashRefunds { get; set; }
    public decimal PettyOut { get; set; }
    public decimal PettyIn { get; set; }
    public decimal ExpectedCash { get; set; }
    public decimal NonCashTotal { get; set; }
    public int TxnCount { get; set; }
    public int CashTxnCount { get; set; }
    /// <summary>Petty floats of the day no closing has taken yet, and whether this closing takes them.</summary>
    public int PettyOpenCount { get; set; }
    public bool IncludePetty { get; set; }
    public bool BlockBilling { get; set; }
}

public sealed class DayClosingLine
{
    public string Kind { get; set; } = "";
    public string Module { get; set; } = "";
    public string ModeName { get; set; } = "";
    public bool IsCash { get; set; }
    public int Cnt { get; set; }
    public decimal Amount { get; set; }
}

public sealed class DayClosingTxn
{
    public string Kind { get; set; } = "";
    public string? Module { get; set; }
    public string? RefNo { get; set; }
    public string? BillNo { get; set; }
    public string? PartyName { get; set; }
    public string? ModeName { get; set; }
    public bool IsCash { get; set; }
    public decimal Amount { get; set; }
    public DateTime TxnAt { get; set; }
    public DateTime CreatedAt { get; set; }
}

/// <summary>A closing (board, history, detail, slip).</summary>
public sealed class DayClosingRow
{
    public int CashClosingId { get; set; }
    public string ClosingNo { get; set; } = "";
    public string? Module { get; set; }
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public int UserId { get; set; }
    public string? UserName { get; set; }
    public DateTime BusinessDate { get; set; }
    public int SeqNo { get; set; }
    public DateTime? WindowFrom { get; set; }
    public DateTime CutoffAt { get; set; }
    public decimal OpeningFloat { get; set; }
    public decimal CashReceipts { get; set; }
    public decimal CashRefunds { get; set; }
    public decimal PettyOut { get; set; }
    public decimal PettyIn { get; set; }
    public decimal ExpectedCash { get; set; }
    public decimal NonCashTotal { get; set; }
    public decimal CountedCash { get; set; }
    public decimal Difference { get; set; }
    public string? DenominationJson { get; set; }
    public string? HandoverMode { get; set; }
    public int? HandedToUserId { get; set; }
    public string? HandedToName { get; set; }
    public decimal HandedAmount { get; set; }
    public decimal RetainedFloat { get; set; }
    public string? BankReference { get; set; }
    public string? Remarks { get; set; }
    public string Status { get; set; } = "S";
    public DateTime? SubmittedOn { get; set; }
    public string? VerifiedByName { get; set; }
    public DateTime? VerifiedOn { get; set; }
    public string? VerifyRemarks { get; set; }
    public string? VoucherNo { get; set; }
}

public sealed class DayClosingOpenUser
{
    public int UserId { get; set; }
    public string? UserName { get; set; }
    public int OpenTxns { get; set; }
    public decimal OpenCash { get; set; }
    public DateTime? LastCutoff { get; set; }
}

public sealed class DayClosingPendingDay
{
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    /// <summary>OPD, LAB, or PETTY (petty floats no closing has taken - close them in OPD or LAB).</summary>
    public string Module { get; set; } = "";
    public DateTime BusinessDate { get; set; }
    /// <summary>NOT_CLOSED, LATE_CASH (cash taken after the closing), SENT_BACK or PETTY_OPEN.</summary>
    public string Reason { get; set; } = "";
    public int OpenTxns { get; set; }
    public decimal OpenCash { get; set; }
}

public sealed class DayClosingUser
{
    public int UserId { get; set; }
    public string? UserName { get; set; }
    public string? LoginName { get; set; }
    public bool IsVerifier { get; set; }
}

public sealed class DayClosingSubmitForm
{
    public DateTime BusinessDate { get; set; }
    public int? CashClosingId { get; set; }
    public decimal CountedCash { get; set; }
    public string? DenominationJson { get; set; }
    public string? HandoverMode { get; set; }
    public int? HandedToUserId { get; set; }
    public decimal HandedAmount { get; set; }
    public decimal RetainedFloat { get; set; }
    public string? BankReference { get; set; }
    public string? Remarks { get; set; }
    public bool IncludePetty { get; set; } = true;
}

public sealed class DayClosingSubmitResult
{
    public int CashClosingId { get; set; }
    public string ClosingNo { get; set; } = "";
    public decimal ExpectedCash { get; set; }
    public decimal CountedCash { get; set; }
    public decimal Difference { get; set; }
}

public sealed class DayClosingVerifyResult
{
    public int CashClosingId { get; set; }
    public int CashierId { get; set; }
    public string ClosingNo { get; set; } = "";
    public string? VoucherNo { get; set; }
}

/// <summary>
/// Hospital Settings "Block Billing Until Day Closed" (SQLScripts/2275), checked at the start of an OPD / LAB billing action
/// before anything is saved. Off (the default) or any failure of the check: billing goes on as before.
/// </summary>
public static class DayClosingGuard
{
    public static async Task<string?> BlockMessageAsync(HttpContext http, string? module, int? branchId, int userId)
    {
        if (module is not ("OPD" or "LAB") || branchId is not > 0 || userId <= 0) return null;
        try
        {
            var svc = http.RequestServices.GetRequiredService<IDayClosingService>();
            if (!await svc.BlocksBillingAsync(branchId.Value)) return null;
            var days = (await svc.GetPendingAsync(userId, branchId, module)).Where(p => p.BusinessDate < DateTime.Today)
                .Select(p => p.BusinessDate).Distinct().OrderBy(d => d).ToList();
            if (days.Count == 0) return null;
            return $"Close your {module} cash of {string.Join(", ", days.Take(3).Select(d => d.ToString("dd-MMM-yyyy")))}{(days.Count > 3 ? " and earlier days" : "")} " +
                   $"first ({module} > {module} Day Closing). Billing is blocked until the earlier days are closed.";
        }
        catch (Exception ex)
        {
            http.RequestServices.GetService<ILogger<DayClosingService>>()?.LogWarning(ex, "Day closing billing check failed; billing allowed");
            return null;
        }
    }
}
