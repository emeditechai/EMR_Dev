using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Reports > Accounts (SQLScripts/2245; menu moved from Utility > Accounts by 2250), page REPORTS.ACCOUNTS: VIEW, EXPORT.
/// Read-only reports over the one ledger that holds billing entries and the petty cash / manual vouchers:
/// Ledger Statement (also Cash Book, Bank Book and Petty Cash Book - the same statement for a ledger of that type),
/// Day Book, Voucher Register, Trial Balance, Income and Expense, Petty Expense Summary, Ledger Posting Audit.
/// Every report exports to Excel and PDF with the filters on screen.
/// </summary>
public class AccReportsController(IAccountsService accounts) : AccountsControllerBase
{
    public const string PageCode = "REPORTS.ACCOUNTS";

    private static readonly Dictionary<string, (string Title, string? LedgerType)> Books = new(StringComparer.OrdinalIgnoreCase)
    {
        ["LedgerStatement"] = ("Ledger Statement", null), ["CashBook"] = ("Cash Book", "CASH"), ["BankBook"] = ("Bank Book", "BANK"), ["PettyCashBook"] = ("Petty Cash Book", "PETTY")
    };

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public IActionResult Index() => View();

    /// <summary>book = LedgerStatement (any ledger) | CashBook | BankBook | PettyCashBook (ledgers of that type only).</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> LedgerStatement(string? book, int? ledgerId, DateTime? fromDate, DateTime? toDate, int? branchId)
        => View(await StatementAsync(book, ledgerId, fromDate, toDate, branchId));

    /// <summary>manualOnly = true is the Voucher Register: petty cash, contra, journal, payment and manual receipts only.</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> DayBook(DateTime? fromDate, DateTime? toDate, int? branchId, int? voucherTypeId, bool manualOnly = false)
        => View(await DayBookAsync(fromDate, toDate, branchId, voucherTypeId, manualOnly));

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> TrialBalance(DateTime? fromDate, DateTime? toDate, int? branchId)
        => View(await TrialAsync("TrialBalance", "Trial Balance", fromDate, toDate, branchId));

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> IncomeExpense(DateTime? fromDate, DateTime? toDate, int? branchId)
        => View(await TrialAsync("IncomeExpense", "Income and Expense Statement", fromDate, toDate, branchId));

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> ExpenseSummary(DateTime? fromDate, DateTime? toDate, int? branchId)
        => View(await ExpenseSummaryAsync(fromDate, toDate, branchId));

    /// <summary>Any ledger entry with its lines - the drill-down from a statement or the day book.</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Voucher(long id)
    {
        var rows = await accounts.GetTransactionAsync(id);
        if (rows.Count == 0) return BackToList("Voucher not found.", error: true);
        return View(rows);
    }

    /// <summary>What should be in the ledger and is not - bills, receipts, refunds, petty cash and vouchers against their entries.</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> PostingAudit(DateTime? fromDate, DateTime? toDate, int? branchId)
        => View(await AuditAsync(fromDate, toDate, branchId));

    /// <summary>The report on screen, with the same filters, as Excel (format = xlsx) or PDF (format = pdf).</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Export)]
    public async Task<IActionResult> Export(string report, string? format, string? book, int? ledgerId, DateTime? fromDate, DateTime? toDate, int? branchId, int? voucherTypeId, bool manualOnly = false)
    {
        AccReportViewModel m;
        var g = new AccReportGrid { Company = User.GetCompanyName() };

        switch (report)
        {
            case "LedgerStatement":
                m = await StatementAsync(book, ledgerId, fromDate, toDate, branchId);
                if (m.Statement is null) return BackToList("Select a ledger first.", error: true, action: nameof(LedgerStatement), route: new { book });
                g.Subject = m.Statement.LedgerName;
                g.Heads = ["Date", "Voucher No", "Type", "Particulars", "Narration", "Debit", "Credit", "Balance", "Dr/Cr"];
                g.Widths = [1.3f, 2.2f, 1.3f, 2.6f, 3.4f, 1.5f, 1.5f, 1.6f, 0.6f];
                var opening = m.Statement.OpeningBalance;
                g.Rows.Add([null, null, null, "Opening balance", null, null, null, Math.Abs(opening), DrCr(opening)]);
                g.GroupRows.Add(0);
                foreach (var x in m.StatementRows)
                    g.Rows.Add([x.TransactionDate, x.VoucherNo, x.VoucherTypeName + (x.IsReversal ? " (reversal)" : x.Status == "C" ? " (cancelled)" : ""), x.Particulars, x.Narration,
                        x.DebitAmount, x.CreditAmount, Math.Abs(x.RunningBalance), DrCr(x.RunningBalance)]);
                var closing = m.StatementRows.Count > 0 ? m.StatementRows[^1].RunningBalance : opening;
                g.Rows.Add([null, null, null, "Total / closing balance", null, m.StatementRows.Sum(x => x.DebitAmount), m.StatementRows.Sum(x => x.CreditAmount), Math.Abs(closing), DrCr(closing)]);
                break;

            case "DayBook":
                m = await DayBookAsync(fromDate, toDate, branchId, voucherTypeId, manualOnly);
                g.Heads = ["Date", "Voucher No", "Type", "Branch", "Ledger", "Debit", "Credit", "Narration", "Payee", "Status", "Entered By"];
                g.Widths = [1.3f, 2.2f, 1.2f, 1.4f, 2.6f, 1.4f, 1.4f, 3f, 1.6f, 1.1f, 1.5f];
                foreach (var x in m.DayBook)
                    g.Rows.Add([x.TransactionDate, x.VoucherNo, x.VoucherTypeName, x.BranchName, x.LedgerName, x.DebitAmount, x.CreditAmount, x.VoucherNarration, x.PayeeName,
                        x.IsReversal ? "Reversal" : x.Status == "C" ? "Cancelled" : "Posted", x.EnteredBy]);
                g.Rows.Add([null, null, null, null, "Total", m.DayBook.Sum(x => x.DebitAmount), m.DayBook.Sum(x => x.CreditAmount), null, null, null, null]);
                break;

            case "TrialBalance":
            case "IncomeExpense":
                m = await TrialAsync(report, report == "TrialBalance" ? "Trial Balance" : "Income and Expense Statement", fromDate, toDate, branchId);
                var rows = report == "TrialBalance" ? m.Trial : m.Trial.Where(t => t.GroupType is "Income" or "Expense").ToList();
                g.Heads = ["Nature", "Group", "Ledger", "Opening Dr", "Opening Cr", "Period Debit", "Period Credit", "Closing Dr", "Closing Cr"];
                g.Widths = [1.1f, 2f, 3f, 1.4f, 1.4f, 1.5f, 1.5f, 1.4f, 1.4f];
                foreach (var x in rows)
                    g.Rows.Add([x.GroupType, x.GroupName, x.LedgerName, Math.Max(x.OpeningBalance, 0), Math.Max(-x.OpeningBalance, 0), x.PeriodDebit, x.PeriodCredit,
                        Math.Max(x.ClosingBalance, 0), Math.Max(-x.ClosingBalance, 0)]);
                g.Rows.Add([null, null, "Total", rows.Sum(x => Math.Max(x.OpeningBalance, 0)), rows.Sum(x => Math.Max(-x.OpeningBalance, 0)), rows.Sum(x => x.PeriodDebit),
                    rows.Sum(x => x.PeriodCredit), rows.Sum(x => Math.Max(x.ClosingBalance, 0)), rows.Sum(x => Math.Max(-x.ClosingBalance, 0))]);
                if (report == "IncomeExpense")
                {
                    var surplus = rows.Where(x => x.GroupType == "Income").Sum(x => x.PeriodCredit - x.PeriodDebit) - rows.Where(x => x.GroupType == "Expense").Sum(x => x.PeriodDebit - x.PeriodCredit);
                    g.Rows.Insert(g.Rows.Count - 1, [null, null, surplus >= 0 ? "Surplus (income over expense)" : "Deficit (expense over income)", null, null,
                        null, null, surplus < 0 ? Math.Abs(surplus) : 0m, surplus >= 0 ? surplus : 0m]);
                    g.GroupRows.Add(g.Rows.Count - 2);
                }
                break;

            case "ExpenseSummary":
                m = await ExpenseSummaryAsync(fromDate, toDate, branchId);
                g.Heads = ["Expense Head", "Month", "Branch", "Vouchers", "Amount"];
                g.Widths = [3f, 1.2f, 2f, 1f, 1.6f];
                foreach (var x in m.ExpenseSummary) g.Rows.Add([x.HeadName, x.YearMonth, x.BranchName, x.Vouchers, x.Amount]);
                g.Rows.Add(["Total", null, null, null, m.ExpenseSummary.Sum(x => x.Amount)]);
                break;

            case "PostingAudit":
                m = await AuditAsync(fromDate, toDate, branchId);
                g.Heads = ["Source", "Document", "Date", "Branch", "Amount", "Problem"];
                g.Widths = [1.6f, 2f, 1.2f, 1.6f, 1.4f, 4f];
                foreach (var x in m.AuditIssues) g.Rows.Add([x.Source, x.DocNo, x.DocDate, x.BranchName, x.Amount, x.Issue]);
                g.Rows.Add([$"{m.AuditIssues.Count} problem(s)", null, null, null, m.AuditIssues.Sum(x => x.Amount), m.AuditIssues.Count == 0 ? "Every document checked is posted correctly." : null]);
                break;

            default:
                return BackToList("Unknown report.", error: true);
        }

        g.Title = m.Title;
        g.Period = $"{m.FromDate:dd-MMM-yyyy} to {m.ToDate:dd-MMM-yyyy}   |   {m.BranchName}";
        g.HasTotalRow = true;
        var stamp = $"_{m.FromDate:yyyyMMdd}_{m.ToDate:yyyyMMdd}";
        return string.Equals(format, "pdf", StringComparison.OrdinalIgnoreCase)
            ? File(g.ToPdf(), "application/pdf", g.FileName("pdf").Replace(".pdf", stamp + ".pdf"))
            : File(g.ToExcel(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", g.FileName("xlsx").Replace(".xlsx", stamp + ".xlsx"));
    }

    // ── data ──────────────────────────────────────────────────────────────────
    private async Task<AccReportViewModel> BaseAsync(string report, string title, DateTime? fromDate, DateTime? toDate, int? branchId)
    {
        var (from, to) = Period(fromDate, toDate);
        var branches = await accounts.GetBranchesAsync(CompanyId);
        var scope = ScopeBranch(branchId);
        return new AccReportViewModel
        {
            Report = report, Title = title, FromDate = from, ToDate = to, BranchId = scope, CanPickBranch = SeesAllBranches,
            Branches = SeesAllBranches ? branches : branches.Where(b => b.Id == OwnBranchId).ToList(),
            BranchName = scope is null ? "All branches" : branches.FirstOrDefault(b => b.Id == scope)?.Name
        };
    }

    private async Task<AccReportViewModel> StatementAsync(string? book, int? ledgerId, DateTime? fromDate, DateTime? toDate, int? branchId)
    {
        if (book is null || !Books.ContainsKey(book)) book = "LedgerStatement";
        var (title, ledgerType) = Books[book];
        var m = await BaseAsync(book, title, fromDate, toDate, branchId);

        var ledgers = await accounts.GetLedgersAsync(ledgerType: ledgerType);
        if (ledgerType == "PETTY" && !SeesAllBranches)
        {
            // a branch user sees only the petty cash ledgers of their own counters
            var own = (await accounts.GetCountersAsync(CompanyId, ScopeBranch())).Select(c => c.LedgerId).ToHashSet();
            ledgers = ledgers.Where(l => own.Contains(l.LedgerId)).ToList();
        }
        m.Ledgers = ledgers.Select(l => new AccOption { Id = l.LedgerId, Name = l.LedgerName, Extra = l.GroupName }).ToList();
        m.LedgerId = ledgerId is > 0 && m.Ledgers.Any(l => l.Id == ledgerId) ? ledgerId : ledgerType is not null && m.Ledgers.Count > 0 ? m.Ledgers[0].Id : null;
        if (m.LedgerId is > 0)
            (m.Statement, m.StatementRows) = await accounts.GetLedgerStatementAsync(m.LedgerId.Value, m.FromDate, m.ToDate, m.BranchId);
        return m;
    }

    private async Task<AccReportViewModel> DayBookAsync(DateTime? fromDate, DateTime? toDate, int? branchId, int? voucherTypeId, bool manualOnly)
    {
        var (from, to) = Period(fromDate, toDate, monthByDefault: false);
        var m = await BaseAsync(manualOnly ? "VoucherRegister" : "DayBook", manualOnly ? "Voucher Register" : "Day Book", from, to, branchId);
        m.VoucherTypes = await accounts.GetVoucherTypesAsync(manualOnly: false);
        m.VoucherTypeId = voucherTypeId is > 0 ? voucherTypeId : null;
        m.DayBook = await accounts.GetDayBookAsync(m.FromDate, m.ToDate, m.BranchId, m.VoucherTypeId, manualOnly);
        return m;
    }

    private async Task<AccReportViewModel> TrialAsync(string report, string title, DateTime? fromDate, DateTime? toDate, int? branchId)
    {
        var m = await BaseAsync(report, title, fromDate, toDate, branchId);
        (m.Trial, m.UnbalancedVouchers) = await accounts.GetTrialBalanceAsync(m.FromDate, m.ToDate, m.BranchId);
        return m;
    }

    private async Task<AccReportViewModel> ExpenseSummaryAsync(DateTime? fromDate, DateTime? toDate, int? branchId)
    {
        var m = await BaseAsync("ExpenseSummary", "Petty Expense Summary", fromDate, toDate, branchId);
        m.ExpenseSummary = await accounts.GetExpenseSummaryAsync(CompanyId, m.FromDate, m.ToDate, m.BranchId, null);
        return m;
    }

    private async Task<AccReportViewModel> AuditAsync(DateTime? fromDate, DateTime? toDate, int? branchId)
    {
        var m = await BaseAsync("PostingAudit", "Ledger Posting Audit", fromDate, toDate, branchId);
        (m.AuditIssues, m.AuditSummary) = await accounts.GetPostingAuditAsync(CompanyId, m.FromDate, m.ToDate, m.BranchId);
        return m;
    }

    private static string DrCr(decimal balance) => balance > 0 ? "Dr" : balance < 0 ? "Cr" : "";
}
